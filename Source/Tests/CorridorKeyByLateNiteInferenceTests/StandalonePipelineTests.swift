import CoreVideo
import CoreMedia
import CoreGraphics
import Foundation
import ImageIO
import Metal
import simd
import Synchronization
import Testing
import UniformTypeIdentifiers
@testable import CorridorKeyToolboxLogic
@testable import CorridorKeyToolboxMetalStages

extension MLXInferenceTests {
    /// Exercises the production AVFoundation adapter, cache codec and renderer.
    /// A direct model test cannot detect a second flip introduced by a host.
    @Suite("Standalone pipeline", .serialized)
    struct StandalonePipelineTests {
        @Test("Cached edge decontamination survives solid source restoration", arguments: [false, true])
        func cachedEdgeDecontamination(keepOriginal: Bool) throws {
            let engine = try StandaloneRenderEngine()
            let source = try Self.makeSource(width: 512, height: 512) { _, _ in SIMD4<UInt8>(51, 204, 51, 255) }
            var state = Self.neutralState()
            state.video.keepOriginalInSolidAreas = keepOriginal
            state.cachedMatteInferenceResolution = 512
            let alpha: Float = keepOriginal ? 0.97 : 0.5
            state.cachedMatteBlob = try AnalysisFrameCodec.encode(
                alpha: [Float](repeating: alpha, count: 512 * 512),
                foregroundHalfRGBA: Self.constantForeground(SIMD4<Float>(0.2, 0.8, 0.2, 1)), width: 512, height: 512
            )
            let baseline = Self.readRGBA(try engine.render(source: source, state: state, renderTime: .zero).destinationTexture)
            state.edgeDecontaminateEnabled = true
            state.edgeDecontaminateStrength = 1
            let corrected = Self.readRGBA(try engine.render(source: source, state: state, renderTime: .zero).destinationTexture)
            #expect(corrected[1] < baseline[1] - 0.008)
            #expect(corrected[0] == baseline[0] && corrected[2] == baseline[2])
            #expect(corrected[3] == baseline[3], "Edge colour correction must preserve alpha.")
            state.edgeDecontaminateStrength = 0
            #expect(Self.readRGBA(try engine.render(source: source, state: state, renderTime: .zero).destinationTexture) == baseline)
        }

        @Test("Cached light wrap reaches opaque silhouette edges, obeys radius and preserves interiors", arguments: [false, true])
        func cachedLightWrap(keepOriginal: Bool) throws {
            let engine = try StandaloneRenderEngine()
            let source = try Self.makeSource(width: 512, height: 512) { _, _ in SIMD4<UInt8>(76, 76, 76, 255) }
            var state = Self.neutralState()
            state.video.keepOriginalInSolidAreas = keepOriginal
            state.cachedMatteInferenceResolution = 512
            state.cachedMatteBlob = try AnalysisFrameCodec.encode(
                alpha: (0..<(512 * 512)).map { $0 % 512 < 256 ? Float(0) : Float(1) },
                foregroundHalfRGBA: Self.constantForeground(SIMD4<Float>(0.2, 0.2, 0.2, 1)), width: 512, height: 512
            )
            let baseline = Self.readRGBA(try engine.render(source: source, state: state, renderTime: .zero).destinationTexture)
            state.lightWrapEnabled = true
            state.lightWrapStrength = 1
            state.lightWrapRadius = 2
            let narrow = Self.readRGBA(try engine.render(source: source, state: state, renderTime: .zero).destinationTexture)
            state.lightWrapRadius = 12
            let wide = Self.readRGBA(try engine.render(source: source, state: state, renderTime: .zero).destinationTexture)
            let edge = (256 * 512 + 256) * 4
            let innerEdge = (256 * 512 + 260) * 4
            let interior = (256 * 512 + 450) * 4
            #expect(narrow[edge] > baseline[edge] + 0.03)
            #expect(wide[innerEdge] > narrow[innerEdge] + 0.01)
            #expect(wide[interior] == baseline[interior])
            #expect(wide[0] == 0 && wide[3] == 0, "Light wrap must not illuminate the transparent background.")
            #expect(wide[edge + 3] == baseline[edge + 3])
            state.lightWrapStrength = 0
            #expect(Self.readRGBA(try engine.render(source: source, state: state, renderTime: .zero).destinationTexture) == baseline)
        }

        @Test("Time Awareness Off emits each frame immediately and matches deferred single-frame inference")
        func singleFrameStreamingMatchesDeferred() async throws {
            let engine = try StandaloneRenderEngine()
            defer { engine.releaseAnalysisCache() }
            var state = PluginStateData(qualityMode: .draft512, hintMode: .none)
            state.video.timeAwareness = .off
            let buffer = try Self.makeSource(width: 128, height: 80) { column, _ in
                column < 64 ? SIMD4<UInt8>(200, 30, 80, 255) : SIMD4<UInt8>(20, 200, 30, 255)
            }
            let streamed = try engine.makeVideoSession(state: state, frameCount: 2, sourceSize: CGSize(width: 128, height: 80))
            var immediate: [VideoInferenceFrame] = []
            for index in 0..<2 {
                try engine.appendVideoFrame(source: buffer, state: state, renderTime: CMTime(value: Int64(index), timescale: 24),
                                            frameIndex: index, session: streamed, hintReader: nil)
                try streamed.finishPreparedFrame { immediate.append($0) }
                #expect(immediate.count == index + 1)
                #expect(immediate.last?.index == index)
            }
            try streamed.finish { _ in Issue.record("Streaming completion emitted a duplicate frame") }
            let deferred = try engine.makeVideoSession(state: state, frameCount: 2, sourceSize: CGSize(width: 128, height: 80))
            for index in 0..<2 {
                try engine.appendVideoFrame(source: buffer, state: state, renderTime: CMTime(value: Int64(index), timescale: 24),
                                            frameIndex: index, session: deferred, hintReader: nil)
            }
            var count = 0
            try deferred.finish { result in
                let expected = immediate[result.index]
                #expect(result.alpha.count == expected.alpha.count)
                let maximumError = zip(result.alpha, expected.alpha).map { abs($0 - $1) }.max() ?? 0
                #expect(maximumError < 0.00001)
                #expect(result.foregroundHalfRGBA == expected.foregroundHalfRGBA)
                count += 1
            }
            #expect(count == 2)
        }

        @Test("Linear output preserves signed source RGB in solid regions and never transforms alpha")
        func linearOutputControls() throws {
            let engine = try StandaloneRenderEngine()
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: 4, height: 4, mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
            let source = try #require(engine.device.makeTexture(descriptor: descriptor))
            let destination = try #require(engine.device.makeTexture(descriptor: descriptor))
            let color = SIMD4<Float>(-0.125, 2, 0.5, 1)
            try [SIMD4<Float>](repeating: color, count: 16).withUnsafeBytes {
                let base = try #require($0.baseAddress)
                source.replace(region: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0,
                               withBytes: base, bytesPerRow: 64)
            }
            var state = Self.neutralState()
            state.outputMode = .processed
            state.video.inputIsLinear = true
            state.video.linearizeOutput = true
            state.video.keepOriginalInSolidAreas = true
            state.cachedMatteInferenceResolution = 512
            state.cachedMatteBlob = try AnalysisFrameCodec.encode(
                alpha: [Float](repeating: 0.98, count: 512 * 512),
                foregroundHalfRGBA: Self.constantForeground(SIMD4(0.2, 0.4, 0.6, 1)), width: 512, height: 512)
            _ = try RenderPipeline().renderToTexture(source: source, destination: destination, state: state, workingGamut: .rec709)
            let pixels = Self.readRGBA(destination)
            let alpha = Float(Float16(0.98))
            #expect(abs(pixels[3] - alpha) < 0.0001)
            for channel in 0..<3 { #expect(abs(pixels[channel] - color[channel] * alpha) < 0.0001) }
            state.outputMode = .original
            _ = try RenderPipeline().renderToTexture(source: source, destination: destination, state: state, workingGamut: .rec709)
            #expect(Array(Self.readRGBA(destination).prefix(4)) == [color.x, color.y, color.z, color.w])
        }

        @Test("Disk-backed rendering matches inline frames and rejects lost, wrong-size or damaged predictions")
        func diskBackedRendering() throws {
            let engine = try StandaloneRenderEngine()
            let source = try Self.makeSource(width: 64, height: 48) { _, _ in SIMD4<UInt8>(40, 170, 60, 255) }
            let foreground = try AnalysisFrameCodec.foregroundHalfRGBA(
                [Float](repeating: 0.4, count: 512 * 384 * 4)
            )
            let blob = try AnalysisFrameCodec.encode(
                alpha: [Float](repeating: 0.65, count: 512 * 384), foregroundHalfRGBA: foreground,
                width: 512, height: 384
            )
            var state = Self.neutralState()
            state.cachedMatteInferenceResolution = 512
            state.cachedMatteBlob = blob
            let inline = try engine.render(source: source, state: state, renderTime: .zero)
            let session = try AnalysisDiskCache.shared.beginSession()
            state.cachedMatteBlob = nil
            state.cachedFrameReference = try AnalysisDiskCache.shared.store(blob, in: session)
            let disk = try engine.render(source: source, state: state, renderTime: .zero)
            #expect(Self.readRGBA(inline.destinationTexture) == Self.readRGBA(disk.destinationTexture))

            state.cachedFrameReference = AnalysisFrameReference(sessionID: UUID(), frameID: UUID(), byteCount: blob.count)
            #expect(throws: AnalysisDiskCacheError.self) { try engine.render(source: source, state: state, renderTime: .zero) }

            let wrongSize = try AnalysisFrameCodec.encode(
                alpha: [Float](repeating: 0.65, count: 16 * 16),
                foregroundHalfRGBA: Data(repeating: 0, count: 16 * 16 * 8), width: 16, height: 16
            )
            state.cachedFrameReference = try AnalysisDiskCache.shared.store(wrongSize, in: session)
            #expect(throws: AnalysisDiskCacheError.self) { try engine.render(source: source, state: state, renderTime: .zero) }

            // Preserve the compressed envelope but truncate its LZ4 stream.
            state.cachedFrameReference = try AnalysisDiskCache.shared.store(Data(blob.prefix(17)), in: session)
            #expect(throws: AnalysisDiskCacheError.self) { try engine.render(source: source, state: state, renderTime: .zero) }
            withExtendedLifetime(session) {}
        }

        @Test("Preview worker preserves source pixels and rejects cancelled queued renders")
        func previewWorker() async throws {
            let engine = try StandaloneRenderEngine()
            let worker = StandalonePreviewRenderer(engine: engine)
            let source = try Self.makeSource(width: 64, height: 48) { column, row in
                SIMD4<UInt8>(UInt8(column * 3), UInt8(row * 4), 97, 255)
            }
            let frame = ReaderFrame(pixelBuffer: source, presentationTime: .zero, duration: .invalid)
            let expected = try engine.renderShowingOriginal(source: source)
            let actual = try await worker.render(frame: frame, state: Self.neutralState(), showingOriginal: true)
            #expect(Self.readRGBA(expected.destinationTexture) == Self.readRGBA(actual.destinationTexture))
            let cancelled = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await worker.render(frame: frame, state: Self.neutralState())
            }
            await #expect(throws: CancellationError.self) { try await cancelled.value }
        }

        @Test("Host analysis and playback respect independent source and destination image origins")
        func hostImageOrigins() throws {
            let engine = try StandaloneRenderEngine()
            let bridge = try PixelBufferTextureBridge(device: engine.device)
            let pipeline = RenderPipeline()
            let entry = try MetalDeviceCache.shared.entry(for: engine.device)
            let queue = try #require(entry.borrowCommandQueue())
            defer { entry.returnCommandQueue(queue) }
            let width = 64
            let height = 48
            let state = Self.neutralState()
            var textures: [(order: ImageRowOrder, texture: any MTLTexture, owner: CVPixelBuffer)] = []
            for order in ImageRowOrder.allCases {
                let source = try Self.makeSource(width: width, height: height) { column, row in
                    let visualRow = order == .topToBottom ? row : height - 1 - row
                    if visualRow < height / 2 {
                        return SIMD4<UInt8>(column < width / 2 ? 210 : 150, 65, 120, 255)
                    }
                    return SIMD4<UInt8>(25, 220, 25, 255)
                }
                textures.append((order, try bridge.makeTexture(for: source).metalTexture, source))
            }
            let reference = try pipeline.extractAlphaMatteForAnalysis(
                sourceTexture: textures[0].texture, state: state, workingGamut: .rec709,
                renderTime: .zero, device: engine.device, entry: entry, commandQueue: queue
            )
            let reversed = try pipeline.extractAlphaMatteForAnalysis(
                sourceTexture: textures[1].texture, state: state, workingGamut: .rec709,
                renderTime: .zero, device: engine.device, entry: entry, commandQueue: queue,
                sourceRowOrder: .bottomToTop
            )
            #expect(reference.alpha == reversed.alpha)
            #expect(reference.foregroundHalfRGBA == reversed.foregroundHalfRGBA)
            #expect(Self.bandMean(reference.alpha, width: reference.width, rows: 16..<96)
                    > Self.bandMean(reference.alpha, width: reference.width, rows: (reference.height - 96)..<(reference.height - 16)) + 0.3)
            let cache = try AnalysisFrameCodec.encode(
                alpha: reversed.alpha, foregroundHalfRGBA: reversed.foregroundHalfRGBA, width: reversed.width, height: reversed.height
            )
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = [.shaderRead, .renderTarget]
            let destination = try #require(engine.device.makeTexture(descriptor: descriptor))
            for useCache in [false, true] {
                for mode in [OutputMode.processed, .matteOnly, .foregroundOnly, .sourcePlusMatte, .foregroundPlusMatte, .hint] {
                    var configured = state
                    configured.outputMode = mode
                    if useCache {
                        configured.cachedMatteBlob = cache
                        configured.cachedMatteInferenceResolution = 512
                    }
                    _ = try pipeline.renderToTexture(source: textures[0].texture, destination: destination, state: configured)
                    let expected = Self.readRGBA(destination)
                    for source in textures {
                        for destinationOrder in ImageRowOrder.allCases {
                            _ = try pipeline.renderToTexture(
                                source: source.texture, destination: destination, state: configured,
                                sourceRowOrder: source.order, destinationRowOrder: destinationOrder
                            )
                            let actual = Self.readRGBA(destination)
                            var maximumError: Float = 0
                            for row in 0..<height {
                                let outputRow = destinationOrder == .topToBottom ? row : height - 1 - row
                                for column in 0..<(width * 4) {
                                    maximumError = max(maximumError, abs(expected[row * width * 4 + column] - actual[outputRow * width * 4 + column]))
                                }
                            }
                            #expect(maximumError < 0.002, "Source \(source.order), destination \(destinationOrder), mode \(mode), cache \(useCache)")
                        }
                    }
                }
            }
            withExtendedLifetime(textures) {}
        }

        @Test("Manual Hint analysis and diagnostic use only the current frame's annotations",
              arguments: [HintPointKind.foreground, .background, .ignore])
        func manualHintsAreFrameScoped(kind: HintPointKind) throws {
            let engine = try StandaloneRenderEngine()
            let source = try Self.makeSource(width: 64, height: 64) { _, _ in
                kind == .foreground ? SIMD4<UInt8>(25, 220, 25, 255) : SIMD4<UInt8>(210, 65, 120, 255)
            }
            let duration = CMTime(value: 1, timescale: 24)
            let frame = try #require(HintFrame(time: .zero, duration: duration))
            var annotated = Self.neutralState()
            annotated.hintMode = .manual
            annotated.hintPointSet = HintPointSet(points: [
                HintPoint(x: 0.5, y: 0.5, kind: kind, radiusNormalized: 0.3, frame: frame)
            ])
            // An unmarked frame in a manually annotated clip must still analyse.
            let unmarked = try engine.extractMatteBlob(source: source, state: annotated, renderTime: duration)
            var unannotated = annotated
            unannotated.hintPointSet.clear()
            let automatic = try engine.extractMatteBlob(source: source, state: unannotated, renderTime: duration)
            let maxDelta = zip(unmarked.alphaFloats, automatic.alphaFloats).reduce(Float.zero) {
                max($0, abs($1.0 - $1.1))
            }
            #expect(maxDelta < 0.0001, "Annotations must not leak to adjacent frames")

            annotated.outputMode = .hint
            let markedPixels = Self.readRGBA(try engine.render(source: source, state: annotated, renderTime: .zero).destinationTexture)
            let unmarkedPixels = Self.readRGBA(try engine.render(source: source, state: annotated, renderTime: duration).destinationTexture)
            var baseline = unannotated
            baseline.outputMode = .hint
            let baselinePixels = Self.readRGBA(try engine.render(source: source, state: baseline, renderTime: duration).destinationTexture)
            #expect(unmarkedPixels == baselinePixels)
            let center = (32 * 64 + 32) * 4
            if kind == .foreground {
                #expect(markedPixels[center] > unmarkedPixels[center] + 0.1)
            } else {
                #expect(markedPixels[center] <= unmarkedPixels[center])
            }
            // Points guide local areas; they do not turn everything outside them into background.
            #expect(markedPixels[0] == unmarkedPixels[0])
        }

        @Test("Analysis and cached composition preserve source orientation",
              arguments: ScreenColor.allCases, [false, true])
        func orientation(screenColor: ScreenColor, subjectAtTop: Bool) throws {
            let engine = try StandaloneRenderEngine()
            let bridge = try PixelBufferTextureBridge(device: engine.device)
            let source = try Self.makeSource(width: 128, height: 80) { _, row in
                let subject = (row < 40) == subjectAtTop
                if subject { return SIMD4<UInt8>(210, 65, 120, 255) }
                return screenColor == .green
                    ? SIMD4<UInt8>(25, 220, 25, 255) : SIMD4<UInt8>(25, 25, 220, 255)
            }
            var state = Self.neutralState()
            state.screenColor = screenColor
            if screenColor == .custom {
                state.video.customScreenColor = SIMD3<Double>(ScreenColor.blue.canonicalScreenReference)
            }
            let analysed = try engine.extractMatteBlob(source: source, state: state, renderTime: .zero)
            let sourceTexture = try bridge.makeTexture(for: source).metalTexture
            let entry = try MetalDeviceCache.shared.entry(for: engine.device)
            let queue = try #require(entry.borrowCommandQueue())
            defer { entry.returnCommandQueue(queue) }
            let direct = try RenderPipeline().extractAlphaMatteForAnalysis(
                sourceTexture: sourceTexture, state: state, workingGamut: .rec709,
                renderTime: .zero, device: engine.device, entry: entry, commandQueue: queue
            )
            let maxDelta = zip(analysed.alphaFloats, direct.alpha).reduce(Float.zero) {
                max($0, abs($1.0 - $1.1))
            }
            #expect(maxDelta < 0.001, "Standalone must cache the shared renderer's row order unchanged")
            #expect(analysed.foregroundHalfRGBA == direct.foregroundHalfRGBA,
                    "Both hosts must retain the model's reconstructed foreground unchanged")
            let upper = Self.bandMean(analysed.alphaFloats, width: analysed.width, rows: 16..<96)
            let lower = Self.bandMean(analysed.alphaFloats, width: analysed.width, rows: (analysed.height - 96)..<(analysed.height - 16))
            #expect(subjectAtTop ? upper > lower + 0.2 : lower > upper + 0.2)

            state.cachedMatteBlob = analysed.blob
            state.cachedMatteInferenceResolution = analysed.inferenceResolution
            state.outputMode = .matteOnly
            let rendered = try engine.render(source: source, state: state, renderTime: .zero)
            let pixels = Self.readRGBA(rendered.destinationTexture)
            let top = pixels[(10 * 128 + 64) * 4]
            let bottom = pixels[(70 * 128 + 64) * 4]
            #expect(subjectAtTop ? top > bottom + 0.2 : bottom > top + 0.2)
        }

        @Test("Cached playback uses reconstructed RGB and records warmed frame time")
        func cachedPlayback() throws {
            let engine = try StandaloneRenderEngine()
            let source = try Self.makeSource(width: 1920, height: 1080) { column, _ in
                SIMD4<UInt8>(column.isMultiple(of: 2) ? 230 : 20, 64, 120, 255)
            }
            var state = Self.neutralState()
            state.outputMode = .foregroundOnly
            state.cachedMatteInferenceResolution = 512
            state.cachedMatteBlob = try AnalysisFrameCodec.encode(
                alpha: [Float](repeating: 1, count: 512 * 512),
                foregroundHalfRGBA: Self.constantForeground(SIMD4<Float>(0.4, 0.2, 0.3, 1)),
                width: 512, height: 512
            )
            _ = try engine.render(source: source, state: state, renderTime: .zero)
            var milliseconds: [Double] = []
            for _ in 0..<7 {
                let start = ContinuousClock.now
                let rendered = try engine.render(source: source, state: state, renderTime: .zero)
                let elapsed = start.duration(to: .now).components
                milliseconds.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
                let pixels = Self.readRGBA(rendered.destinationTexture)
                #expect(abs(pixels[(540 * 1920 + 960) * 4] - 0.4) < 0.001)
                #expect(abs(pixels[(540 * 1920 + 961) * 4] - 0.4) < 0.001)
            }
            print("Cached 1080p foreground playback, milliseconds: \(milliseconds); median: \(milliseconds.sorted()[3])")
        }

        @Test("Legacy and damaged caches fall back to the source")
        func invalidCachedFrame() throws {
            let engine = try StandaloneRenderEngine()
            let source = try Self.makeSource(width: 128, height: 80) { _, _ in
                SIMD4<UInt8>(200, 50, 100, 255)
            }
            let valid = try AnalysisFrameCodec.encode(
                alpha: [Float](repeating: 1, count: 512 * 512),
                foregroundHalfRGBA: Self.constantForeground(SIMD4<Float>(0, 0, 0, 1)),
                width: 512, height: 512
            )
            let legacy = try MatteCodec.encode(alpha: [Float](repeating: 1, count: 512 * 512), width: 512, height: 512)
            for blob in [legacy, Data(valid.dropLast())] {
                var state = Self.neutralState()
                state.cachedMatteBlob = blob
                state.cachedMatteInferenceResolution = 512
                let rendered = try engine.render(source: source, state: state, renderTime: .zero)
                let pixels = Self.readRGBA(rendered.destinationTexture)
                #expect(abs(pixels[0] - 200.0 / 255) < 0.001)
            }
        }

        @Test("Cached foreground returns to the host working gamut", arguments: WorkingColorGamut.allCases)
        func cachedForegroundWorkingGamut(gamut: WorkingColorGamut) throws {
            let engine = try StandaloneRenderEngine()
            let source = try Self.makeSource(width: 128, height: 80) { _, _ in
                SIMD4<UInt8>(20, 200, 30, 255)
            }
            let bridge = try PixelBufferTextureBridge(device: engine.device)
            let sourceTexture = try bridge.makeTexture(for: source).metalTexture
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: 128, height: 80, mipmapped: false
            )
            descriptor.storageMode = .shared
            descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
            let destination = try #require(engine.device.makeTexture(descriptor: descriptor))
            let expected = SIMD3<Float>(0.4, 0.2, 0.3)
            let linearExpected = expected
            func decode(_ value: Float) -> Float { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
            func encode(_ value: Float) -> Float {
                let magnitude = abs(value)
                let output = magnitude <= 0.0031308 ? magnitude * 12.92 : 1.055 * pow(magnitude, 1 / 2.4) - 0.055
                return value < 0 ? -output : output
            }
            let canonical = ColorGamutMatrix.transform(for: gamut).workingToRec709 * SIMD3(decode(linearExpected.x), decode(linearExpected.y), decode(linearExpected.z))
            let modelRGB = SIMD3(encode(canonical.x), encode(canonical.y), encode(canonical.z))
            var state = Self.neutralState()
            state.outputMode = .foregroundOnly
            state.cachedMatteInferenceResolution = 512
            state.cachedMatteBlob = try AnalysisFrameCodec.encode(
                alpha: [Float](repeating: 1, count: 512 * 512),
                foregroundHalfRGBA: Self.constantForeground(SIMD4<Float>(modelRGB, 1)),
                width: 512, height: 512
            )
            _ = try RenderPipeline().renderToTexture(
                source: sourceTexture, destination: destination, state: state, workingGamut: gamut
            )
            let rendered = Self.readRGBA(destination)
            for channel in 0..<3 {
                #expect(abs(rendered[channel] - expected[channel]) < 0.001)
            }
        }

        @Test("Concurrent cached renders retain their own foreground")
        func concurrentCachedFrames() async throws {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for red: Float in [0.125, 0.875] {
                    group.addTask {
                        let engine = try StandaloneRenderEngine()
                        let source = try Self.makeSource(width: 128, height: 80) { _, _ in
                            SIMD4<UInt8>(20, 200, 30, 255)
                        }
                        var state = Self.neutralState()
                        state.outputMode = .foregroundOnly
                        state.cachedMatteInferenceResolution = 512
                        state.cachedMatteBlob = try AnalysisFrameCodec.encode(
                            alpha: [Float](repeating: 1, count: 512 * 512),
                            foregroundHalfRGBA: Self.constantForeground(SIMD4<Float>(red, 0.25, 0.5, 1)),
                            width: 512, height: 512
                        )
                        for _ in 0..<8 {
                            let rendered = try engine.render(source: source, state: state, renderTime: .zero)
                            #expect(abs(Self.readRGBA(rendered.destinationTexture)[0] - red) < 0.001)
                        }
                    }
                }
                try await group.waitForAll()
            }
        }

        @Test("Real v2 frames measure complete-cache cost at every quality")
        func cachePerformance() async throws {
            let repository = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let video = try await VideoSource(url: repository.appending(path: "LLM Resources/Benchmark/NikoDruid/Niko - 4 frames.mov"))
            let source = try await video.makeFrame(atTime: .zero)
            let engine = try StandaloneRenderEngine()
            defer { engine.releaseAnalysisCache() }
            let cacheSession = try AnalysisDiskCache.shared.beginSession()
            defer { withExtendedLifetime(cacheSession) {} }
            for quality in QualityMode.allCases where quality != .automatic {
                var state = Self.neutralState()
                state.qualityMode = quality
                let output = try engine.extractMatteBlob(source: source, state: state, renderTime: .zero)
                state.cachedMatteBlob = output.blob
                state.cachedMatteInferenceResolution = output.inferenceResolution
                var diskState = state
                diskState.cachedMatteBlob = nil
                diskState.cachedFrameReference = try AnalysisDiskCache.shared.store(output.blob, in: cacheSession)
                let header = try #require(AnalysisFrameCodec.parseHeader(output.blob))
                var decoded = Data(count: header.decodedByteCount)
                var decodeMilliseconds: [Double] = []
                var renderMilliseconds: [Double] = []
                var uncachedReadMilliseconds: [Double] = []
                var cachedReadMilliseconds: [Double] = []
                _ = try engine.render(source: source, state: state, renderTime: .zero)
                for _ in 0..<7 {
                    let decodeStart = ContinuousClock.now
                    let success = decoded.withUnsafeMutableBytes { AnalysisFrameCodec.decode(output.blob, into: $0) }
                    decodeMilliseconds.append(Self.milliseconds(since: decodeStart))
                    #expect(success)
                    try autoreleasepool {
                        let renderStart = ContinuousClock.now
                        _ = try engine.render(source: source, state: state, renderTime: .zero)
                        renderMilliseconds.append(Self.milliseconds(since: renderStart))
                    }
                    // Only our compressed-RAM cache is cleared. The filesystem
                    // may retain these just-written bytes; this is not cold SSD I/O.
                    AnalysisDiskCache.shared.clearMemory()
                    try autoreleasepool {
                        let start = ContinuousClock.now
                        _ = try engine.render(source: source, state: diskState, renderTime: .zero)
                        uncachedReadMilliseconds.append(Self.milliseconds(since: start))
                    }
                    try autoreleasepool {
                        let start = ContinuousClock.now
                        _ = try engine.render(source: source, state: diskState, renderTime: .zero)
                        cachedReadMilliseconds.append(Self.milliseconds(since: start))
                    }
                }
                print("V2 cache \(output.inferenceResolution): bytes=\(output.blob.count), decode median ms=\(decodeMilliseconds.sorted()[3]), render median ms=\(renderMilliseconds.sorted()[3])")
                print("V2 disk cache \(output.inferenceResolution): RAM miss median ms=\(uncachedReadMilliseconds.sorted()[3]), RAM hit median ms=\(cachedReadMilliseconds.sorted()[3]), retained bytes=\(AnalysisDiskCache.shared.retainedMemoryBytes)")
                if output.inferenceResolution == 2048,
                   let destination = ProcessInfo.processInfo.environment["CORRIDORKEY_CACHE_BENCHMARK_RAW"] {
                    try decoded.write(to: URL(fileURLWithPath: destination))
                }
            }
        }

        private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
            let duration = start.duration(to: .now).components
            return Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
        }

        @Test("Interior erode and blur change source mixing without changing output alpha")
        func interiorControls() throws {
            let engine = try StandaloneRenderEngine()
            let source = try Self.makeSource(width: 512, height: 512) { _, _ in
                SIMD4<UInt8>(80, 180, 80, 255)
            }
            var state = Self.neutralState()
            state.sourcePassthroughEnabled = true
            state.passthroughErodeNormalized = 0
            state.passthroughBlurNormalized = 0
            state.despillStrength = 1
            state.spillMethod = .average
            state.destinationLongEdgePixels = 1920
            state.cachedMatteInferenceResolution = 512
            let alpha = (0..<(512 * 512)).map { Float($0 % 512 < 256 ? 1 : 0) }
            state.cachedMatteBlob = try AnalysisFrameCodec.encode(
                alpha: alpha,
                foregroundHalfRGBA: Self.constantForeground(SIMD4<Float>(80.0 / 255, 180.0 / 255, 80.0 / 255, 1)),
                width: 512, height: 512
            )
            state.outputMode = .foregroundOnly
            let original = Self.readRGBA(try engine.render(source: source, state: state, renderTime: .zero).destinationTexture)
            state.passthroughErodeNormalized = 8
            let eroded = Self.readRGBA(try engine.render(source: source, state: state, renderTime: .zero).destinationTexture)
            state.passthroughErodeNormalized = 0
            state.passthroughBlurNormalized = 8
            let blurred = Self.readRGBA(try engine.render(source: source, state: state, renderTime: .zero).destinationTexture)
            let edgeGreen = (256 * 512 + 253) * 4 + 1
            #expect(original[edgeGreen] > eroded[edgeGreen] + 0.05)
            #expect(original[edgeGreen] > blurred[edgeGreen] + 0.01)
            state.outputMode = .matteOnly
            let matteWithBlur = Self.readRGBA(try engine.render(source: source, state: state, renderTime: .zero).destinationTexture)
            state.sourcePassthroughEnabled = false
            let matteWithoutBlur = Self.readRGBA(try engine.render(source: source, state: state, renderTime: .zero).destinationTexture)
            #expect(matteWithBlur == matteWithoutBlur)
        }

        @Test("Reanalysis at the same time uses the current source and hints")
        func reanalysisUsesCurrentInput() throws {
            let engine = try StandaloneRenderEngine()
            let background = try Self.makeSource(width: 128, height: 80) { _, _ in
                SIMD4<UInt8>(25, 220, 25, 255)
            }
            let subject = try Self.makeSource(width: 128, height: 80) { _, _ in
                SIMD4<UInt8>(210, 65, 120, 255)
            }
            let first = try engine.extractMatteBlob(source: background, state: Self.neutralState(), renderTime: .zero)
            let second = try engine.extractMatteBlob(source: subject, state: Self.neutralState(), renderTime: .zero)
            let firstMean = first.alphaFloats.reduce(0, +) / Float(first.alphaFloats.count)
            let secondMean = second.alphaFloats.reduce(0, +) / Float(second.alphaFloats.count)
            #expect(secondMean > firstMean + 0.5)
        }

        @Test("Concurrent analysis sessions cannot overwrite another frame's input")
        func concurrentAnalysis() async throws {
            try await withThrowingTaskGroup(of: (Bool, Float).self) { group in
                for isSubject in [false, true] {
                    group.addTask {
                        let engine = try StandaloneRenderEngine()
                        let source = try Self.makeSource(width: 128, height: 80) { _, _ in
                            isSubject ? SIMD4<UInt8>(210, 65, 120, 255) : SIMD4<UInt8>(25, 220, 25, 255)
                        }
                        let output = try engine.extractMatteBlob(source: source, state: Self.neutralState(), renderTime: .zero)
                        return (isSubject, output.alphaFloats.reduce(0, +) / Float(output.alphaFloats.count))
                    }
                }
                for try await (isSubject, alpha) in group {
                    #expect(isSubject ? alpha > 0.8 : alpha < 0.1)
                }
            }
        }

        @Test("Standalone analysis caches the same temporal blend as FxPlug")
        func analysisRunnerTemporalParity() async throws {
            let repository = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let video = try await VideoSource(url: repository.appending(path: "LLM Resources/Benchmark/NikoDruid/Niko - 4 frames.mov"))
            var state = Self.neutralState()
            state.temporalStabilityEnabled = true
            state.temporalStabilityStrength = 0.75
            let engine = try StandaloneRenderEngine()
            let runner = AnalysisRunner(renderEngine: engine, videoSource: video)
            let received = Mutex<[Int: Data]>([:])
            await runner.run(state: state) { event in
                switch event {
                case let .frameProcessed(frameIndex, _, entry):
                    received.withLock { $0[frameIndex] = try? entry.blob }
                case let .failed(message):
                    Issue.record(Comment(rawValue: message))
                default: break
                }
            }
            let cached = received.withLock { $0 }
            #expect(cached.count == 4)
            let reader = try await video.makeFrameReader(startTime: .zero)
            defer { reader.cancel(); engine.releaseAnalysisCache() }
            var history = TemporalBlender.History()
            let shared = try engine.makeVideoSession(state: state, frameCount: 4, sourceSize: video.info.renderSize)
            var frameIndex = 0
            while let frame = try reader.nextFrame() {
                try engine.appendVideoFrame(source: frame.pixelBuffer, state: state, renderTime: frame.presentationTime,
                    frameIndex: frameIndex, session: shared, hintReader: nil)
                frameIndex += 1
            }
            try shared.finish { output in
                var alpha = output.alpha
                history.apply(alpha: &alpha, source: output.source, width: output.geometry.contentWidth, height: output.geometry.contentHeight,
                              frameIndex: output.index, configuration: .init(strength: 0.75, motionThreshold: 0.05))
                let expected = try AnalysisFrameCodec.encode(alpha: alpha, foregroundHalfRGBA: output.foregroundHalfRGBA,
                    width: output.geometry.contentWidth, height: output.geometry.contentHeight)
                #expect(cached[output.index] == expected)
            }
        }

        @Test("HardestShotEver runs through standalone analysis and cached composition")
        func hardestShotPreview() async throws {
            let repository = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let clip = repository.appending(path: "LLM Resources/Benchmark/JallenClownWater/Input/HardestShotEver - 1sec.mov")
            let video = try await VideoSource(url: clip)
            let source = try await video.makeFrame(atTime: .zero)
            let engine = try StandaloneRenderEngine()
            defer { engine.releaseAnalysisCache() }
            var state = PluginStateData(qualityMode: .maximum2048)
            state.destinationLongEdgePixels = max(CVPixelBufferGetWidth(source), CVPixelBufferGetHeight(source))
            let analysis = try engine.extractMatteBlob(source: source, state: state, renderTime: .zero)
            state.cachedMatteBlob = analysis.blob
            state.cachedMatteInferenceResolution = analysis.inferenceResolution
            let processed = try engine.render(source: source, state: state, renderTime: .zero)
            let processedPixels = Self.readRGBA(processed.destinationTexture)
            #expect(processedPixels.allSatisfy { $0.isFinite })
            state.outputMode = .matteOnly
            let matte = try engine.render(source: source, state: state, renderTime: .zero)
            let bridge = try PixelBufferTextureBridge(device: engine.device)
            let original = try bridge.makeTexture(for: source).metalTexture
            let width = original.width
            let height = original.height
            let panelWidth = 640
            let panelHeight = panelWidth * height / width
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let context = try #require(CGContext(
                data: nil, width: panelWidth * 3, height: panelHeight,
                bitsPerComponent: 8, bytesPerRow: panelWidth * 12, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            let panels = [Self.readRGBA(original), Self.readRGBA(matte.destinationTexture), processedPixels]
            for (index, panel) in panels.enumerated() {
                var bytes = [UInt8](repeating: 255, count: panel.count)
                for pixelIndex in 0..<(width * height) {
                    let offset = pixelIndex * 4
                    // The renderer writes premultiplied RGB; put it over white
                    // for a visible comparison with the reported screenshot.
                    for channel in 0..<3 {
                        let value = panel[offset + channel] + 1 - panel[offset + 3]
                        bytes[offset + channel] = UInt8((max(0, min(1, value)) * 255).rounded())
                    }
                }
                let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
                let image = try #require(CGImage(
                    width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                    bytesPerRow: width * 4, space: colorSpace,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                    provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
                ))
                context.draw(image, in: CGRect(x: index * panelWidth, y: 0, width: panelWidth, height: panelHeight))
            }
            let preview = try #require(context.makeImage())
            let output = URL.temporaryDirectory.appending(path: "CorridorKey-v2-HardestShotEver.png")
            let destination = try #require(CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, preview, nil)
            #expect(CGImageDestinationFinalize(destination))
            print("HardestShotEver source / matte / composite: \(output.path)")
        }

        /// Removes optional postprocessing to isolate the source/matte contract.
        private static func neutralState() -> PluginStateData {
            PluginStateData(screenColor: .green, qualityMode: .draft512, hintMode: .automatic,
                            autoDespeckleEnabled: false, despillStrength: 0,
                            lightWrapEnabled: false, edgeDecontaminateEnabled: false,
                            temporalStabilityEnabled: false, upscaleMethod: .bilinear)
        }

        private static func constantForeground(_ color: SIMD4<Float>) throws -> Data {
            let pixels = [SIMD4<Float>](repeating: color, count: 512 * 512)
            return try pixels.withUnsafeBytes {
                try AnalysisFrameCodec.foregroundHalfRGBA(Array($0.bindMemory(to: Float.self)))
            }
        }

        private static func makeSource(
            width: Int, height: Int, pixel: (Int, Int) -> SIMD4<UInt8>
        ) throws -> CVPixelBuffer {
            let buffer = try PixelBufferTextureBridge.makeMetalCompatiblePixelBuffer(
                width: width, height: height, pixelFormat: kCVPixelFormatType_32BGRA
            )
            CVPixelBufferLockBaseAddress(buffer, [])
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for row in 0..<height {
                for column in 0..<width {
                    let color = pixel(column, row)
                    let offset = row * stride + column * 4
                    base[offset] = color.z
                    base[offset + 1] = color.y
                    base[offset + 2] = color.x
                    base[offset + 3] = color.w
                }
            }
            return buffer
        }

        private static func readRGBA(_ texture: any MTLTexture) -> [Float] {
            if texture.pixelFormat == .rgba32Float {
                var values = [Float](repeating: 0, count: texture.width * texture.height * 4)
                values.withUnsafeMutableBytes { pointer in
                    if let base = pointer.baseAddress {
                        texture.getBytes(base, bytesPerRow: texture.width * 16,
                            from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
                    }
                }
                return values
            }
            if texture.pixelFormat == .rgba16Float {
                var halves = [UInt16](repeating: 0, count: texture.width * texture.height * 4)
                halves.withUnsafeMutableBytes { pointer in
                    if let base = pointer.baseAddress {
                        texture.getBytes(base, bytesPerRow: texture.width * 8,
                                         from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
                    }
                }
                return halves.map { Float(Float16(bitPattern: $0)) }
            }
            var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
            bytes.withUnsafeMutableBytes { pointer in
                if let base = pointer.baseAddress {
                    texture.getBytes(base, bytesPerRow: texture.width * 4,
                                     from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
                }
            }
            var pixels = [Float](repeating: 0, count: bytes.count)
            for offset in stride(from: 0, to: bytes.count, by: 4) {
                pixels[offset] = Float(bytes[offset + 2]) / 255
                pixels[offset + 1] = Float(bytes[offset + 1]) / 255
                pixels[offset + 2] = Float(bytes[offset]) / 255
                pixels[offset + 3] = Float(bytes[offset + 3]) / 255
            }
            return pixels
        }

        private static func bandMean(_ alpha: [Float], width: Int, rows: Range<Int>) -> Float {
            guard rows.lowerBound >= 0, rows.upperBound * width <= alpha.count else {
                Issue.record("The requested orientation band exceeds the cropped prediction")
                return 0
            }
            return alpha[(rows.lowerBound * width)..<(rows.upperBound * width)].reduce(0, +)
                / Float(rows.count * width)
        }
    }
}
