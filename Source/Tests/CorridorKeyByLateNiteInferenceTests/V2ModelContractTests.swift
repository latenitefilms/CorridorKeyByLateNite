import Foundation
import MLX
import Metal
import Testing
@testable import CorridorKeyToolboxLogic
@testable import CorridorKeyToolboxMetalStages

/// Regression coverage for v2's shared weights and multi-resolution contract.
extension MLXInferenceTests {
@Suite("CorridorKey v2 contract", .serialized)
struct V2ModelContractTests {
    @Test("Zero-copy input owns its Metal buffer only for the array lifetime")
    func inputBufferOwnershipIsBalanced() throws {
        let entry = try InferenceTestHarness.makeEntry()
        weak var observedBuffer: (any MTLBuffer)?
        var array: MLXArray?
        try autoreleasepool {
            let buffer = try #require(entry.device.makeBuffer(length: 128 * 128 * 4 * MemoryLayout<Float>.size,
                                                              options: .storageModeShared))
            observedBuffer = buffer
            buffer.contents().initializeMemory(as: Float.self, repeating: 0.5, count: 128 * 128 * 4)
            array = MLXKeyingEngine.makeInputArray(buffer: buffer, resolution: 128)
        }
        #expect(observedBuffer != nil)
        try autoreleasepool {
            let input = try #require(array)
            #expect(input[0, 0, 0, 0].item(Float.self) == 0.5)
        }
        array = nil
        MLXKeyingEngine.synchronizeMLXGPUStream()
        MLX.Memory.clearCache()
        #expect(observedBuffer == nil)
    }

    @Test("All screen colours and quality levels use one v2 artifact")
    func sharedArtifact() {
        let names = Set(ScreenColor.allCases.flatMap { screenColor in
            MLXBridgeArtifact.ladder.map { resolution in
                MLXBridgeArtifact.filename(forResolution: resolution, screenColor: screenColor)
            }
        })
        #expect(names == ["corridorkey_v2.mlxfn"])
        #expect(MLXBridgeArtifact.ladder.allSatisfy { $0 > 0 && $0.isMultiple(of: 128) })
        for memory in [8.0, 16.0, 32.0, 64.0, 128.0] {
            #expect(SharedMLXBridgeRegistry.bridgeBudget(forWorkingSetGB: memory) == 1)
        }
    }

    @Test("One loaded engine accepts another quality level and screen colour")
    func sharedEngineAcrossQualities() async throws {
        let entry = try InferenceTestHarness.makeEntry()
        let engine = MLXKeyingEngine(cacheEntry: entry)
        let artifact = try InferenceTestHarness.bridgeURL512()
        #expect(MLX.Memory.cacheLimit <= 1024 * 1024 * 1024)
        try await engine.prepare(bridgeURL: artifact, rung: 512, screenColor: .green)
        for resolution in [512, 768] {
            let request = try InferenceTestHarness.makeRequest(rung: resolution, entry: entry)
            let output = try InferenceTestHarness.makeOutput(rung: resolution, entry: entry)
            try engine.run(request: request, output: output)
            let alpha = InferenceTestHarness.readAlpha(output: output)
            #expect(alpha.count == resolution * resolution)
            #expect(alpha.allSatisfy { $0.isFinite && (0...1).contains($0) })
        }
        try await engine.prepare(bridgeURL: artifact, rung: 768, screenColor: .blue)
        #expect(engine.backendDisplayName.contains("CorridorKey v2"))
        engine.clearMLXCache()
    }

    @Test("Unsupported dimensions fail before reading an input buffer")
    func unsupportedResolution() async throws {
        let entry = try InferenceTestHarness.makeEntry()
        let engine = MLXKeyingEngine(cacheEntry: entry)
        #expect(!engine.supports(resolution: 513, screenColor: .green))
        #expect(!engine.supports(resolution: -1, screenColor: .blue))
        do {
            try await engine.prepare(resolution: 513, screenColor: .green)
            Issue.record("An unsupported resolution was accepted")
        } catch KeyingInferenceError.unsupportedResolution(513) {
            // Expected: no rounded-up graph may interpret a differently sized buffer.
        }
    }

    @Test("Registry shares its engine across both colours and every quality")
    func registrySharesWeights() throws {
        let entry = try InferenceTestHarness.makeEntry()
        let registry = SharedMLXBridgeRegistry.shared
        let deviceID = entry.device.registryID
        let engine = try registry.waitForReady(deviceRegistryID: deviceID, rung: 512,
                                              screenColor: .green, cacheEntry: entry)
        for screenColor in ScreenColor.allCases {
            for resolution in MLXBridgeArtifact.ladder {
                let shared = registry.readyEngine(deviceRegistryID: deviceID, rung: resolution,
                                                  screenColor: screenColor)
                #expect(shared === engine)
            }
        }
        #expect(registry.residentEnginesSnapshot(deviceRegistryID: deviceID).count == 1)
    }
}

}
