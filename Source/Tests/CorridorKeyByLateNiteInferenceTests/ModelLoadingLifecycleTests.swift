import CoreMedia
import Foundation
import Metal
import Testing
@testable import CorridorKeyToolboxLogic
@testable import CorridorKeyToolboxMetalStages

extension MLXInferenceTests {
    /// Exercises the same pipeline used by FxPlug, with a fresh model registry
    /// so another test's analysis cannot hide an accidental eager load.
    @Suite("Model loading lifecycle", .serialized)
    struct ModelLoadingLifecycleTests {
        @Test("Construction, inspector reads and idle cleanup leave the model cold")
        func idlePipelineRemainsCold() {
            let registry = SharedMLXBridgeRegistry()
            let coordinator = InferenceCoordinator(bridgeRegistry: registry)
            let pipeline = RenderPipeline(inferenceCoordinator: coordinator)

            for _ in 0..<10 {
                #expect(pipeline.inferenceCoordinator.warmupStatus == .cold)
                #expect(pipeline.inferenceCoordinator.backendDescription == "Idle")
                coordinator.cancelWarmup()
                coordinator.releaseCacheBetweenSessions()
            }
            #expect(registry.status(deviceRegistryID: 1, rung: 512, screenColor: .green) == .cold)
            #expect(registry.residentEnginesSnapshot(deviceRegistryID: 1).isEmpty)
        }

        @Test("Pass-through, original, hint and cached playback never load the model")
        func playbackRemainsCold() throws {
            let registry = SharedMLXBridgeRegistry()
            let coordinator = InferenceCoordinator(bridgeRegistry: registry)
            let pipeline = RenderPipeline(inferenceCoordinator: coordinator)
            let device = try #require(MTLCreateSystemDefaultDevice())
            let source = try Self.makeTexture(device: device)
            let destination = try Self.makeTexture(device: device)
            var state = Self.analysisState()

            for mode in [OutputMode.processed, .original, .hint] {
                state.outputMode = mode
                let report = try pipeline.renderToTexture(source: source, destination: destination, state: state)
                #expect(report.effectiveInferenceResolution == (mode == .hint ? 512 : 0))
                Self.expectCold(registry, coordinator: coordinator, device: device)
            }

            // Reopening an analysed clip must play its saved prediction without
            // importing the model, including after a post-processing edit.
            state.outputMode = .processed
            state.cachedMatteInferenceResolution = 512
            let pixelCount = 512 * 512
            let blob = try AnalysisFrameCodec.encode(
                alpha: [Float](repeating: 0.5, count: pixelCount),
                foregroundHalfRGBA: AnalysisFrameCodec.foregroundHalfRGBA(
                    [Float](repeating: 0.4, count: pixelCount * 4)
                ), width: 512, height: 512
            )
            let cacheSession = try AnalysisDiskCache.shared.beginSession()
            state.cachedFrameReference = try AnalysisDiskCache.shared.store(blob, in: cacheSession)
            for strength in [0.0, 0.5] {
                state.despillStrength = strength
                let report = try pipeline.renderToTexture(source: source, destination: destination, state: state)
                #expect(report.backendDescription == "Analysed Cache (512px)")
                #expect(report.effectiveInferenceResolution == 512)
                Self.expectCold(registry, coordinator: coordinator, device: device)
            }
            withExtendedLifetime(cacheSession) {}
        }

        @Test("The first analysis frame loads the requested model and reports readiness")
        func firstAnalysisLoadsModel() throws {
            let registry = SharedMLXBridgeRegistry()
            let coordinator = InferenceCoordinator(bridgeRegistry: registry)
            let pipeline = RenderPipeline(inferenceCoordinator: coordinator)
            let entry = try InferenceTestHarness.makeEntry()
            let queue = try #require(entry.borrowCommandQueue())
            defer {
                entry.returnCommandQueue(queue)
                coordinator.releaseCacheBetweenSessions()
            }
            let source = try Self.makeTexture(device: entry.device)
            var state = Self.analysisState()
            state.screenColor = .blue
            Self.expectCold(registry, coordinator: coordinator, device: entry.device)

            let result = try pipeline.extractAlphaMatteForAnalysis(
                sourceTexture: source, state: state, workingGamut: .rec709,
                renderTime: .zero, device: entry.device, entry: entry, commandQueue: queue
            )

            #expect(coordinator.warmupStatus == .ready(resolution: 512))
            #expect(coordinator.backendDescription.contains("CorridorKey v2"))
            #expect(result.inferenceResolution == 512)
            #expect(result.alpha.count == result.width * result.height)
            #expect(result.alpha.allSatisfy { $0.isFinite && (0...1).contains($0) })
            #expect(!result.foregroundHalfRGBA.isEmpty)
            let loadedEngine = try #require(registry.readyEngine(
                deviceRegistryID: entry.device.registryID, rung: 512, screenColor: .blue
            ))

            // Another instance and screen colour must reuse the same weights.
            let otherCoordinator = InferenceCoordinator(bridgeRegistry: registry)
            let reusedEngine = try otherCoordinator.engineForAnalysis(
                resolution: 512, screenColor: .green, cacheEntry: entry
            )
            #expect(reusedEngine === loadedEngine)
            let request = try InferenceTestHarness.makeRequest(rung: 512, entry: entry)
            let inference = try otherCoordinator.runInference(request: request, screenColor: .green, cacheEntry: entry)
            #expect(InferenceTestHarness.readAlpha(output: inference.output).allSatisfy { $0.isFinite })
            #expect(otherCoordinator.warmupStatus == .ready(resolution: 512))
            #expect(registry.residentEnginesSnapshot(deviceRegistryID: entry.device.registryID).count == 1)
        }

        @Test("A failed on-demand load is reported by the requesting coordinator")
        func failedLoadReportsStatus() throws {
            let registry = SharedMLXBridgeRegistry()
            let coordinator = InferenceCoordinator(bridgeRegistry: registry)
            let entry = try InferenceTestHarness.makeEntry()

            #expect(throws: KeyingInferenceError.self) {
                try coordinator.engineForAnalysis(resolution: 256, screenColor: .blue, cacheEntry: entry)
            }
            guard case .failed(let message) = coordinator.warmupStatus else {
                Issue.record("The inspector should report the model-loading error.")
                return
            }
            #expect(!message.isEmpty)
            #expect(registry.residentEnginesSnapshot(deviceRegistryID: entry.device.registryID).isEmpty)
            #expect(registry.status(deviceRegistryID: entry.device.registryID, rung: 512, screenColor: .blue) == .cold)
        }

        /// Checks every supported shape and colour because they share one v2 model.
        private static func expectCold(
            _ registry: SharedMLXBridgeRegistry,
            coordinator: InferenceCoordinator,
            device: any MTLDevice
        ) {
            #expect(coordinator.warmupStatus == .cold)
            #expect(coordinator.backendDescription == "Idle")
            #expect(registry.residentEnginesSnapshot(deviceRegistryID: device.registryID).isEmpty)
            for resolution in MLXBridgeArtifact.ladder {
                for color in ScreenColor.allCases {
                    #expect(registry.status(
                        deviceRegistryID: device.registryID, rung: resolution, screenColor: color
                    ) == .cold)
                }
            }
        }

        /// Keeps the lifecycle test independent of optional Vision and temporal work.
        private static func analysisState() -> PluginStateData {
            var state = PluginStateData(
                qualityMode: .draft512, hintMode: .automatic,
                autoDespeckleEnabled: false, despillStrength: 0,
                lightWrapEnabled: false, edgeDecontaminateEnabled: false,
                temporalStabilityEnabled: false, upscaleMethod: .bilinear
            )
            state.video.timeAwareness = .off
            return state
        }

        /// Creates a small deterministic source and render target on the real GPU.
        private static func makeTexture(device: any MTLDevice) throws -> any MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba32Float, width: 64, height: 64, mipmapped: false
            )
            descriptor.storageMode = .shared
            descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
            let texture = try #require(device.makeTexture(descriptor: descriptor))
            let pixels = [SIMD4<Float>](repeating: SIMD4(0.2, 0.8, 0.3, 1), count: 64 * 64)
            pixels.withUnsafeBytes { bytes in
                if let baseAddress = bytes.baseAddress {
                    texture.replace(region: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0,
                                    withBytes: baseAddress, bytesPerRow: 64 * MemoryLayout<SIMD4<Float>>.stride)
                }
            }
            return texture
        }
    }
}
