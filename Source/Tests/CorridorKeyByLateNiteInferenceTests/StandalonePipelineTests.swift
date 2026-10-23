import CoreVideo
import CoreGraphics
import Foundation
import ImageIO
import Metal
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
            let upper = Self.bandMean(analysed.alphaFloats, width: analysed.width, rows: 16..<96)
            let lower = Self.bandMean(analysed.alphaFloats, width: analysed.width, rows: 416..<496)
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

        @Test("Cached playback preserves native source detail and records warmed frame time")
        func cachedPlayback() throws {
            let engine = try StandaloneRenderEngine()
            let source = try Self.makeSource(width: 1920, height: 1080) { column, _ in
                SIMD4<UInt8>(column.isMultiple(of: 2) ? 230 : 20, 64, 120, 255)
            }
            var state = Self.neutralState()
            state.outputMode = .foregroundOnly
            state.cachedMatteInferenceResolution = 512
            state.cachedMatteBlob = try MatteCodec.encode(
                alpha: [Float](repeating: 1, count: 512 * 512), width: 512, height: 512
            )
            _ = try engine.render(source: source, state: state, renderTime: .zero)
            var milliseconds: [Double] = []
            for _ in 0..<7 {
                let start = ContinuousClock.now
                let rendered = try engine.render(source: source, state: state, renderTime: .zero)
                let elapsed = start.duration(to: .now).components
                milliseconds.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
                let pixels = Self.readRGBA(rendered.destinationTexture)
                #expect(abs(pixels[(540 * 1920 + 960) * 4] - 230.0 / 255) < 0.01)
                #expect(abs(pixels[(540 * 1920 + 961) * 4] - 20.0 / 255) < 0.01)
            }
            print("Cached 1080p foreground playback, milliseconds: \(milliseconds); median: \(milliseconds.sorted()[3])")
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
            state.cachedMatteBlob = try MatteCodec.encode(alpha: alpha, width: 512, height: 512)
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
                    received.withLock { $0[frameIndex] = entry.blob }
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
            var frameIndex = 0
            while let frame = try reader.nextFrame() {
                let output = try engine.extractMatteBlob(source: frame.pixelBuffer, state: state, renderTime: frame.presentationTime)
                var alpha = output.alphaFloats
                history.apply(alpha: &alpha, source: output.sourceFloats, width: output.width, height: output.height,
                              frameIndex: frameIndex, configuration: .init(strength: 0.75, motionThreshold: 0.05))
                let expected = try MatteCodec.encode(alpha: alpha, width: output.width, height: output.height)
                #expect(cached[frameIndex] == expected)
                frameIndex += 1
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
            PluginStateData(qualityMode: .draft512, hintMode: .automatic,
                            autoDespeckleEnabled: false, despillStrength: 0,
                            lightWrapEnabled: false, edgeDecontaminateEnabled: false,
                            temporalStabilityEnabled: false, upscaleMethod: .bilinear)
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
            alpha[(rows.lowerBound * width)..<(rows.upperBound * width)].reduce(0, +)
                / Float(rows.count * width)
        }
    }
}
