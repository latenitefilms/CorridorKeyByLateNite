//
//  MLXBridgeRungTests.swift
//  CorridorKeyToolboxInferenceTests
//
//  Exercises every production `.mlxfn` bridge that ships in the app
//  bundle. The crash reports from TestFlight all died in MLX eval, so
//  this suite validates both the direct MLX error path and the full
//  CorridorKey bridge load/eval/writeback path for every supported rung.
//

import Foundation
import MLX
import Testing
@testable import CorridorKeyToolboxLogic
@testable import CorridorKeyToolboxMetalStages

extension MLXInferenceTests {
@Suite("MLX bridge rungs", .serialized)
struct MLXBridgeRungTests {

    @Test("MLX scoped error handler converts runtime errors into Swift throws")
    func scopedErrorHandlerThrowsInsteadOfFatalError() throws {
        let left = MLXArray(0 ..< 10, [2, 5])
        let right = MLXArray(0 ..< 15, [3, 5])

        #expect(throws: (any Error).self) {
            try withError {
                let invalidBroadcast = left + right
                eval(invalidBroadcast)
            }
        }
    }

    @Test("every bundled MLX bridge loads, evaluates, and writes finite alpha")
    func everyBundledBridgeRunsOneInference() async throws {
        let entry: MetalDeviceCacheEntry
        do { entry = try InferenceTestHarness.makeEntry() }
        catch { throw XCTSkip(error) }

        // Both screen selections must dispatch successfully at every quality.
        // Missing production assets are failures, not skipped inference.
        for screenColor in ScreenColor.allCases {
            for rung in InferenceTestHarness.allBridgeRungs {
                try await runOneInference(rung: rung, screenColor: screenColor, entry: entry)
                MLX.Memory.clearCache()
            }
        }
    }

    private func runOneInference(
        rung: Int,
        screenColor: ScreenColor,
        entry: MetalDeviceCacheEntry
    ) async throws {
        let bridgeURL = try InferenceTestHarness.bridgeURL(forRung: rung, screenColor: screenColor)
        let engine = MLXKeyingEngine(cacheEntry: entry)
        try await engine.prepare(bridgeURL: bridgeURL, rung: rung, screenColor: screenColor)

        let request = try InferenceTestHarness.makeRequest(rung: rung, entry: entry)
        let output = try InferenceTestHarness.makeOutput(rung: rung, entry: entry)
        try engine.run(request: request, output: output)

        let alpha = InferenceTestHarness.readAlpha(output: output)
        var finiteCount = 0
        var minValue = Float.infinity
        var maxValue = -Float.infinity
        for value in alpha {
            guard value.isFinite else { continue }
            finiteCount += 1
            minValue = min(minValue, value)
            maxValue = max(maxValue, value)
        }

        let label = "\(screenColor.displayName) \(rung)px"
        #expect(finiteCount == alpha.count, Comment(rawValue: "\(label) bridge produced non-finite alpha values."))
        #expect(maxValue > minValue + 0.001, Comment(rawValue: "\(label) bridge produced a degenerate alpha range."))
        print("\(screenColor.displayName) \(rung)px MLX bridge alpha range: [\(minValue), \(maxValue)]")
    }
}

}
