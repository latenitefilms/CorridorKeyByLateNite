//
//  MLXParityTests.swift
//  CorridorKeyToolboxInferenceTests
//
//  Validates that the two `MLXKeyingEngine.InputStrategy` paths produce
//  equivalent output for the same input. The `.zeroCopy` path is the
//  reference (it's what shipped in v1.0.0 build 2 and produces visually
//  correct mattes); `.cpuStaging` is the alternate we landed when
//  `.zeroCopy` was suspected to be slow on a particular clip. If they
//  disagree, the alternate has a parity bug and we cannot trust its
//  output.
//
//  Also asserts the alpha matte returned for a non-trivial input has
//  *some* structure — not all zeros, not all ones, more than one
//  distinct value. A wedged graph that emits a constant tensor would
//  produce an "unusable" matte that this catches without ground truth.
//

import Foundation
import Metal
import MLX
import Testing
@testable import CorridorKeyToolboxLogic
@testable import CorridorKeyToolboxMetalStages

extension MLXInferenceTests {
@Suite("MLXParity")
struct MLXParityTests {

    @Test("Swift video session matches official recurrent, overlapping temporal predictions",
          .enabled(if: ProcessInfo.processInfo.environment["CK_V2_REFERENCE_FIXTURE"] != nil,
                   "Generate the independent oracle with Tools/CorridorKeyV2/validate_video.py --fixture"))
    func temporalReferenceParity() async throws {
        let folder = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["CK_V2_REFERENCE_FIXTURE"]))
        let entry = try InferenceTestHarness.makeEntry()
        let engine = MLXKeyingEngine(cacheEntry: entry, compilationEnabled: MLXKeyingEngine.defaultCompilationEnabled)
        try await engine.prepare(bridgeURL: InferenceTestHarness.bridgeURL512(), rung: 512, screenColor: .green)
        var firstPass: [[Float]] = []
        for lowMemory in [true, false] {
            var settings = VideoInferenceSettings()
            settings.timeAwareness = .two
            settings.inputIsLinear = true
            settings.lowGPUMemory = lowMemory
            let session = try VideoInferenceSession(engine: engine, settings: settings, hintMode: .automatic,
                geometry: InferenceGeometry(sourceWidth: 512, sourceHeight: 512, resolution: 512),
                frameCount: 3, device: entry.device, needsSourceReadback: true)
            let buffer = try #require(entry.device.makeBuffer(length: 512 * 512 * 16, options: .storageModeShared))
            for index in 0..<3 {
                let input = try Data(contentsOf: folder.appending(path: "input-\(index).f32"))
                #expect(input.count == buffer.length)
                input.copyBytes(to: buffer.contents().assumingMemoryBound(to: UInt8.self), count: input.count)
                try session.append(normalizedInput: buffer, frameIndex: index)
            }
            var emitted: [Int] = []
            try session.finish { frame in
                emitted.append(frame.index)
                let expectedAlpha = try Data(contentsOf: folder.appending(path: "alpha-\(frame.index).f32"))
                    .withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                let expectedForeground = try Data(contentsOf: folder.appending(path: "foreground-\(frame.index).f32"))
                    .withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                let actualForeground = frame.foregroundHalfRGBA.withUnsafeBytes { bytes in
                    bytes.bindMemory(to: Float16.self).enumerated().compactMap { offset, value -> Float? in
                        guard offset % 4 != 3 else { return nil }
                        let display = Float(value)
                        let magnitude = abs(display)
                        let linear = magnitude <= 0.04045 ? magnitude / 12.92 : pow((magnitude + 0.055) / 1.055, 2.4)
                        return display < 0 ? -linear : linear
                    }
                }
                #expect(frame.source?.count == 512 * 512 * 4)
                #expect(maximumDelta(expectedAlpha, frame.alpha) < 0.05)
                #expect(maximumDelta(expectedForeground, actualForeground) < 0.05)
                #expect(zip(expectedAlpha, frame.alpha).reduce(Float(0)) { $0 + abs($1.0 - $1.1) } / Float(frame.alpha.count) < 0.002)
                let meanForegroundError = zip(expectedForeground, actualForeground)
                    .reduce(Float(0)) { $0 + abs($1.0 - $1.1) } / Float(actualForeground.count)
                #expect(meanForegroundError < 0.002)
                if lowMemory { firstPass.append(frame.alpha) }
                else { #expect(maximumDelta(firstPass[frame.index], frame.alpha) == 0) }
            }
            #expect(emitted == [0, 1, 2])
            #expect(throws: VideoAnalysisError.self) { try session.finish { _ in } }
        }
        var referenceSettings = VideoInferenceSettings()
        referenceSettings.timeAwareness = .two
        referenceSettings.inputIsLinear = true
        referenceSettings.useAlphaHint = true
        referenceSettings.hintFrames = .singleFrame
        referenceSettings.referenceFrame = 1
        // The reader is independently tested with real image files. This unit
        // feeds the already normalized reference hint through the model boundary.
        referenceSettings.alphaHintAsset = try AlphaHintAsset(url: folder.appending(path: "input-1.f32"))
        let propagation = try VideoInferenceSession(engine: engine, settings: referenceSettings, hintMode: .none,
            geometry: InferenceGeometry(sourceWidth: 512, sourceHeight: 512, resolution: 512),
            frameCount: 3, device: entry.device, needsSourceReadback: false)
        let buffer = try #require(entry.device.makeBuffer(length: 512 * 512 * 16, options: .storageModeShared))
        for index in 0..<3 {
            let input = try Data(contentsOf: folder.appending(path: "input-\(index).f32"))
            input.copyBytes(to: buffer.contents().assumingMemoryBound(to: UInt8.self), count: input.count)
            try propagation.append(normalizedInput: buffer, frameIndex: index)
        }
        var indices: [Int] = []
        try propagation.finish { frame in
            indices.append(frame.index)
            #expect(frame.alpha.allSatisfy { $0.isFinite && (0...1).contains($0) })
            #expect(frame.foregroundHalfRGBA.count == 512 * 512 * 8)
        }
        #expect(indices == [1, 2, 0], "The reference must propagate both forward and backward, emitting each frame once")
    }

    @Test("Compiled v2 graphs preserve alpha and RGB at every quality and release safely",
          .enabled(if: MLXKeyingEngine.defaultCompilationEnabled,
                   "Requires optimized MLX: its Debug compiler-cache destructor can overflow the worker stack"))
    func compiledGraphParity() async throws {
        let entry = try InferenceTestHarness.makeEntry()
        let bridgeURL = try InferenceTestHarness.bridgeURL512()
        let reference = MLXKeyingEngine(cacheEntry: entry, compilationEnabled: false)
        let optimized = MLXKeyingEngine(cacheEntry: entry, compilationEnabled: true)
        try await reference.prepare(bridgeURL: bridgeURL, rung: 512, screenColor: .green)
        try await optimized.prepare(bridgeURL: bridgeURL, rung: 512, screenColor: .green)
        for rung in InferenceTestHarness.allBridgeRungs {
            let referenceOutput = try InferenceTestHarness.makeOutput(rung: rung, entry: entry)
            let optimizedOutput = try InferenceTestHarness.makeOutput(rung: rung, entry: entry)
            for screen in [ScreenColor.green, .blue] {
                let request = try InferenceTestHarness.makeRequest(rung: rung, entry: entry)
                if screen == .blue {
                    let values = request.normalisedInputBuffer.contents().assumingMemoryBound(to: Float.self)
                    for pixel in 0..<(rung * rung) where values[pixel * 4 + 3] == 0 {
                        values[pixel * 4 + 1] = (0.10 - 0.456) / 0.224
                        values[pixel * 4 + 2] = (0.85 - 0.406) / 0.225
                    }
                }
                try reference.run(request: request, output: referenceOutput)
                try optimized.run(request: request, output: optimizedOutput)
                var referenceMilliseconds: [Double] = []
                var compiledMilliseconds: [Double] = []
                // Alternate order to reduce thermal/order bias. Timings include
                // the actual Swift-to-Metal writeback and exclude CPU readback.
                for iteration in 0..<5 {
                    for useCompiled in (iteration.isMultiple(of: 2) ? [false, true] : [true, false]) {
                        let start = ContinuousClock.now
                        if useCompiled {
                            try optimized.run(request: request, output: optimizedOutput)
                        } else {
                            try reference.run(request: request, output: referenceOutput)
                        }
                        let elapsed = start.duration(to: .now).components
                        let milliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
                        if useCompiled { compiledMilliseconds.append(milliseconds) }
                        else { referenceMilliseconds.append(milliseconds) }
                    }
                }
                let alphaDelta = maximumDelta(
                    InferenceTestHarness.readAlpha(output: referenceOutput),
                    InferenceTestHarness.readAlpha(output: optimizedOutput)
                )
                let foregroundDelta = maximumDelta(
                    readForeground(referenceOutput.foregroundTexture),
                    readForeground(optimizedOutput.foregroundTexture)
                )
                #expect(alphaDelta <= 0.001, "Compiled alpha diverged at \(rung), \(screen)")
                #expect(foregroundDelta <= 0.001, "Compiled RGB diverged at \(rung), \(screen)")
                let measurement: [String: Any] = [
                    "resolution": rung, "screen": String(describing: screen), "samples": 5,
                    "reference_ms": referenceMilliseconds.sorted()[2],
                    "compiled_ms": compiledMilliseconds.sorted()[2],
                    "maximum_alpha_error": alphaDelta, "maximum_foreground_error": foregroundDelta,
                ]
                let json = try JSONSerialization.data(withJSONObject: measurement, options: [.sortedKeys])
                print("COMPILED_GRAPH_BENCHMARK \(String(decoding: json, as: UTF8.self))")
            }
        }
        // Both engines deinitialize here, exercising compiled graph ownership
        // as well as inference. This caught a failure that numeric tests missed.
    }

    private func readForeground(_ texture: any MTLTexture) -> [Float] {
        var pixels = [Float](repeating: 0, count: texture.width * texture.height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            texture.getBytes(base, bytesPerRow: texture.width * 16,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return pixels
    }

    @Test("Optimized Swift dispatches every long temporal profile with finite refined output",
          .enabled(if: MLXKeyingEngine.defaultCompilationEnabled, "Requires the production optimized MLX compiler"))
    func compiledTemporalProfiles() async throws {
        let entry = try InferenceTestHarness.makeEntry()
        let engine = MLXKeyingEngine(cacheEntry: entry, compilationEnabled: true)
        try await engine.prepare(bridgeURL: InferenceTestHarness.bridgeURL512(), rung: 512, screenColor: .green)
        let source = broadcast(MLXArray([Float(0.05), 0.65, 0.05, 0]), to: [1, 512, 512, 4])
        let features = try engine.evaluateVideoStage([source, MLXArray.zeros([1, 65, 384])])
        try #require(features.count == 4)
        for frameCount in [8, 24, 48, 80] {
            try autoreleasepool {
                let temporal = try engine.evaluateVideoStage([
                    broadcast(source, to: [frameCount, 512, 512, 4]), -MLXArray.ones([1, frameCount]),
                    broadcast(features[0].expandedDimensions(axis: 1), to: [1, frameCount] + Array(features[0].shape.dropFirst())),
                    broadcast(features[1].expandedDimensions(axis: 1), to: [1, frameCount] + Array(features[1].shape.dropFirst())),
                    broadcast(features[2].expandedDimensions(axis: 1), to: [1, frameCount] + Array(features[2].shape.dropFirst()))
                ])
                try #require(temporal.count == 2)
                #expect(temporal[0].shape == [1, frameCount, 512, 32, 32])
                #expect(temporal[1].shape == [frameCount, 512, 512, 1])
                for output in temporal { #expect(isFinite(output).all().item(Bool.self)) }
                for index in [0, frameCount - 1] {
                    let baton = temporal[0][0..<1, index..<(index + 1)].asType(.float16).asType(.float32)
                    let refined = try engine.evaluateVideoStage([source, baton, MLXArray.zeros([0])])
                    try #require(refined.count == 2)
                    for output in refined { #expect(isFinite(output).all().item(Bool.self)) }
                }
            }
            print("COMPILED_TEMPORAL_PROFILE frames=\(frameCount) finite=true")
            engine.clearMLXCache()
        }
    }

    private func maximumDelta(_ expected: [Float], _ actual: [Float]) -> Float {
        guard expected.count == actual.count else { return .infinity }
        var maximum: Float = 0
        for (reference, result) in zip(expected, actual) {
            guard reference.isFinite, result.isFinite else { return .infinity }
            maximum = max(maximum, abs(reference - result))
        }
        return maximum
    }

    @Test("zeroCopy and cpuStaging strategies produce the same alpha output")
    func strategyParity() async throws {
        let entry: MetalDeviceCacheEntry
        do { entry = try InferenceTestHarness.makeEntry() }
        catch { throw XCTSkip(error) }

        let bridgeURL = try InferenceTestHarness.bridgeURL512()

        // Run the same input through each strategy. We override the
        // build-time `inputStrategy` via the test override entry
        // points (added below) so we don't have to rebuild the engine.
        let zeroCopy = try await runOneInference(
            strategy: .zeroCopy,
            bridgeURL: bridgeURL,
            entry: entry
        )
        let cpuStaging = try await runOneInference(
            strategy: .cpuStaging,
            bridgeURL: bridgeURL,
            entry: entry
        )

        #expect(zeroCopy.count == cpuStaging.count, "Different output counts: \(zeroCopy.count) vs \(cpuStaging.count)")

        // Floating-point tolerance: MLX may schedule the two runs on
        // slightly different code paths (rawPointer aliases vs owned
        // arrays), so allow rounding noise but not divergence.
        let tolerance: Float = 1e-3
        var maxAbsDelta: Float = 0
        var firstDifferIndex: Int = -1
        for index in 0..<min(zeroCopy.count, cpuStaging.count) {
            let delta = abs(zeroCopy[index] - cpuStaging[index])
            if delta > maxAbsDelta {
                maxAbsDelta = delta
                if delta > tolerance && firstDifferIndex < 0 {
                    firstDifferIndex = index
                }
            }
        }
        if maxAbsDelta > tolerance {
            print("First diverging pixel index: \(firstDifferIndex) — zeroCopy=\(zeroCopy[firstDifferIndex]), cpuStaging=\(cpuStaging[firstDifferIndex])")
            print("Max |Δ|: \(maxAbsDelta)")
        }
        #expect(maxAbsDelta <= tolerance, "Strategies diverge: max |Δ| = \(maxAbsDelta) (tolerance \(tolerance))")
    }

    @Test("MLX produces identical output for the same input across 30 sequential calls")
    func outputStableAcrossManyInferences() async throws {
        let entry: MetalDeviceCacheEntry
        do { entry = try InferenceTestHarness.makeEntry() }
        catch { throw XCTSkip(error) }

        let bridgeURL = try InferenceTestHarness.bridgeURL512()
        let engine = MLXKeyingEngine(cacheEntry: entry)
        try await engine.prepare(bridgeURL: bridgeURL, rung: 512, screenColor: .green)

        let request = try InferenceTestHarness.makeRequest(rung: 512, entry: entry)
        let output = try InferenceTestHarness.makeOutput(rung: 512, entry: entry)

        // Frame 1 reference.
        try engine.run(request: request, output: output)
        let frame1 = InferenceTestHarness.readAlpha(output: output)

        // Run 29 more, checking each against frame 1 — the input is
        // identical every iteration so output must be too. If the
        // cache-limit fix corrupts MLX's internal state under pressure,
        // this is what would catch it.
        for iteration in 2...30 {
            try engine.run(request: request, output: output)
            let frameN = InferenceTestHarness.readAlpha(output: output)

            #expect(frame1.count == frameN.count, "Output count diverged at iteration \(iteration).")

            var maxAbsDelta: Float = 0
            for index in 0..<min(frame1.count, frameN.count) {
                maxAbsDelta = max(maxAbsDelta, abs(frame1[index] - frameN[index]))
            }
            // Same input, deterministic graph — output should match
            // exactly (within tiny float-noise tolerance). Anything
            // larger means the cache cap is breaking computation.
            let tolerance: Float = 1e-4
            #expect(
                maxAbsDelta <= tolerance,
                "Output drifted at iteration \(iteration): max |Δ| = \(maxAbsDelta) (tolerance \(tolerance))"
            )
            if maxAbsDelta > tolerance {
                print("Drift detected at iteration \(iteration): \(maxAbsDelta)")
                break
            }
        }
    }

    @Test("MLX returns a non-degenerate alpha matte for a structured input")
    func outputHasStructure() async throws {
        let entry: MetalDeviceCacheEntry
        do { entry = try InferenceTestHarness.makeEntry() }
        catch { throw XCTSkip(error) }

        let bridgeURL = try InferenceTestHarness.bridgeURL512()
        let alpha = try await runOneInference(
            strategy: .zeroCopy,
            bridgeURL: bridgeURL,
            entry: entry
        )

        var minValue: Float = .infinity
        var maxValue: Float = -.infinity
        var nonZero: Int = 0
        var nonOne: Int = 0
        for value in alpha {
            minValue = min(minValue, value)
            maxValue = max(maxValue, value)
            if value > 0.001 { nonZero += 1 }
            if value < 0.999 { nonOne += 1 }
        }

        let pixelCount = alpha.count
        // Mid-range guard: a wedged model would emit all 0 or all 1.
        // Any non-degenerate model should have both kinds in a 512² output
        // for a structured RGB input.
        #expect(nonZero > pixelCount / 100, "Alpha is essentially all zeros (\(nonZero) of \(pixelCount) pixels > 0.001).")
        #expect(nonOne > pixelCount / 100, "Alpha is essentially all ones (\(nonOne) of \(pixelCount) pixels < 0.999).")
        #expect(maxValue > minValue + 0.1, "Alpha range too narrow: [\(minValue), \(maxValue)].")

        print("Alpha range: [\(minValue), \(maxValue)], non-zero \(nonZero)/\(pixelCount), non-one \(nonOne)/\(pixelCount)")
    }

    // MARK: - Helpers

    /// Boots a fresh engine, applies the requested strategy, runs one
    /// inference on a deterministic gradient input, and returns the
    /// alpha texture pixels read back to CPU.
    private func runOneInference(
        strategy: MLXKeyingEngine.InputStrategy,
        bridgeURL: URL,
        entry: MetalDeviceCacheEntry
    ) async throws -> [Float] {
        let engine = MLXKeyingEngine(cacheEntry: entry)
        // Override the build-time strategy. The test entry point lives
        // on the engine for exactly this purpose; production paths
        // continue to use the default.
        engine.testOverrideInputStrategy(strategy)
        try await engine.prepare(bridgeURL: bridgeURL, rung: 512, screenColor: .green)

        let request = try InferenceTestHarness.makeRequest(rung: 512, entry: entry)
        let output = try InferenceTestHarness.makeOutput(rung: 512, entry: entry)
        try engine.run(request: request, output: output)

        return InferenceTestHarness.readAlpha(output: output)
    }
}

}
