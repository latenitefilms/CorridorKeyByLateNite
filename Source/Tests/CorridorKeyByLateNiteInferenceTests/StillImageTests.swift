import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import Synchronization
import Testing
import UniformTypeIdentifiers

#if CORRIDOR_KEY_HEADLESS_TESTS
@testable import CorridorKeyToolboxLogic
@testable import CorridorKeyToolboxMetalStages
#else
@testable import CorridorKeyByLateNiteApp
#endif

@Suite("Still image import and export", .serialized)
struct StillImageTests {
    @Test("PNG, TIFF, JPEG, and HEIC enter the same single-frame pipeline", arguments: ["png", "tiff", "jpeg", "heic"])
    func importsImage(format: String) async throws {
        let url = try Self.writeImage(type: #require(UTType(filenameExtension: format)))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let source = try await MediaSourceLoader.load(url: url)
        #expect(source.info.kind == .stillImage)
        #expect(source.info.renderSize == CGSize(width: 64, height: 48))
        #expect(source.totalFrameCount() == 1)
        #expect(source.nearestFrameTime(to: CMTime(seconds: 10, preferredTimescale: 600)) == .zero)
        let first = try await source.makeFrame(atTime: .zero)
        let second = try await source.makeFrame(atTime: .zero)
        #expect(first === second, "Parameter edits must reuse the decoded source")
        #expect(CVPixelBufferGetPixelFormatType(first) == kCVPixelFormatType_64RGBAHalf)
        let reader = try await source.makeFrameReader()
        #expect(try reader.nextFrame()?.presentationTime == .zero)
        #expect(try reader.nextFrame() == nil)
        let cancelledReader = try await source.makeFrameReader()
        cancelledReader.cancel()
        #expect(try cancelledReader.nextFrame() == nil)
        let pastEnd = try await source.makeFrameReader(startTime: CMTime(value: 1, timescale: 1))
        #expect(try pastEnd.nextFrame() == nil)
        let probe = try await source.makeFrame(atTime: .zero, preferredPixelFormat: kCVPixelFormatType_32BGRA)
        #expect(CVPixelBufferGetPixelFormatType(probe) == kCVPixelFormatType_32BGRA)
    }

    @Test("EXIF rotations and reflections preserve pixel orientation", arguments: Array(1...8))
    func orientation(orientation: Int) async throws {
        let url = try Self.writeImage(type: .tiff, orientation: orientation)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let source = try await StillImageSource(url: url)
        let rotated = orientation >= 5
        #expect(source.info.renderSize == CGSize(width: rotated ? 48 : 64, height: rotated ? 64 : 48))
        let buffer = try await source.makeFrame(atTime: .zero, preferredPixelFormat: kCVPixelFormatType_32BGRA)
        // Original corners are red, blue, green, white in row order.
        let expectedCorners = [
            [0, 1, 2, 3], [1, 0, 3, 2], [3, 2, 1, 0], [2, 3, 0, 1],
            [0, 2, 1, 3], [2, 0, 3, 1], [3, 1, 2, 0], [1, 3, 0, 2]
        ][orientation - 1]
        let corners = [(0, 0), (CVPixelBufferGetWidth(buffer) - 1, 0),
                       (0, CVPixelBufferGetHeight(buffer) - 1),
                       (CVPixelBufferGetWidth(buffer) - 1, CVPixelBufferGetHeight(buffer) - 1)]
        for (index, point) in corners.enumerated() {
            let actual = try Self.pixel(buffer, column: point.0, row: point.1)
            let expected = Self.cornerColors[expectedCorners[index]]
            for channel in 0..<3 { #expect(abs(Int(actual[channel]) - Int(expected[channel])) <= 2) }
        }
    }

    @Test("Unsupported, corrupt, missing, and oversized images fail recoverably")
    func rejectsInvalidImages() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Broken.png")
        try Data("Not an image".utf8).write(to: url)
        await #expect(throws: StillImageSourceError.self) { _ = try await MediaSourceLoader.load(url: url) }
        await #expect(throws: StillImageSourceError.self) {
            _ = try await MediaSourceLoader.load(url: directory.appending(path: "Missing.tiff"))
        }
        let large = try Self.writeImage(type: .png, width: 16_385, height: 1)
        defer { try? FileManager.default.removeItem(at: large.deletingLastPathComponent()) }
        await #expect(throws: StillImageSourceError.self) { _ = try await StillImageSource(url: large) }
    }

    @Test("Lossless exports retain dimensions, 16-bit precision, and fractional alpha", arguments: StillImageExportFormat.allCases)
    func exportAlpha(format: StillImageExportFormat) async throws {
        let url = try Self.writeImage(type: .png)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let source = try await StillImageSource(url: url)
        let engine = try StandaloneRenderEngine()
        let cache = try Self.cache(alpha: 0.5)
        let events = Mutex<[ExportRunnerEvent]>([])
        for outputMode in [OutputMode.processed, .foregroundPlusMatte, .matteOnly] {
            var state = Self.neutralState()
            state.outputMode = outputMode
            let output = url.deletingLastPathComponent().appending(path: "Keyed-\(outputMode.rawValue).\(format.filenameExtension)")
            let exporter = StillImageExporter(renderEngine: engine, source: source,
                                              project: ExportProjectSnapshot(state: state, cachedMattes: [0: cache]))
            await exporter.run(options: StillImageExportOptions(destination: output, format: format)) { event in
                events.withLock { $0.append(event) }
            }
            #expect(events.withLock { $0.contains { if case .completed(output) = $0 { true } else { false } } })
            let written = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(written, 0, nil))
            #expect(image.width == 64 && image.height == 48)
            #expect(image.bitsPerComponent == 16)
            // Image IO uses the extended equivalent for some 16-bit TIFFs.
            #expect([CGColorSpace.sRGB, CGColorSpace.extendedSRGB].contains(image.colorSpace?.name))
            let imported = try await StillImageSource(url: output)
            let buffer = try await imported.makeFrame(atTime: .zero, preferredPixelFormat: kCVPixelFormatType_32BGRA)
            let actual = try Self.pixel(buffer, column: 32, row: 24)
            if outputMode == .matteOnly {
                #expect(actual[3] == 255)
                #expect(abs(Int(actual[0]) - 128) <= 2)
            } else {
                #expect(abs(Int(actual[3]) - 128) <= 2)
                // The decoder returns premultiplied RGB: .8 * .5 = .4.
                #expect(abs(Int(actual[0]) - 102) <= 3)
                #expect(abs(Int(actual[1]) - 26) <= 3)
                #expect(abs(Int(actual[2]) - 51) <= 3)
            }
        }
    }

    @Test("Cancellation preserves an existing destination")
    func cancelExport() async throws {
        let url = try Self.writeImage(type: .png)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let source = try await StillImageSource(url: url)
        let output = url.deletingLastPathComponent().appending(path: "Existing.png")
        let sentinel = Data("existing file".utf8)
        try sentinel.write(to: output)
        let exporter = StillImageExporter(renderEngine: try StandaloneRenderEngine(), source: source,
                                          project: ExportProjectSnapshot(state: Self.neutralState(), cachedMattes: [:]))
        let events = Mutex<[ExportRunnerEvent]>([])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await exporter.run(options: StillImageExportOptions(destination: output, format: .png)) { event in
                events.withLock { $0.append(event) }
            }
        }
        await task.value
        #expect(try Data(contentsOf: output) == sentinel)
        #expect(events.withLock { $0.contains { if case .cancelled = $0 { true } else { false } } })
    }

    @Test("Wide-gamut image exports keep their RGB profile", arguments: StillImageExportFormat.allCases)
    func wideGamutExport(format: StillImageExportFormat) async throws {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let url = try Self.writeImage(type: .png, colorSpace: colorSpace)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let source = try await StillImageSource(url: url)
        #expect(source.info.imageColorSpace?.name == CGColorSpace.displayP3)
        let output = url.deletingLastPathComponent().appending(path: "Wide.\(format.filenameExtension)")
        let exporter = StillImageExporter(renderEngine: try StandaloneRenderEngine(), source: source,
                                          project: ExportProjectSnapshot(state: Self.neutralState(), cachedMattes: [:]))
        await exporter.run(options: StillImageExportOptions(destination: output, format: format)) { _ in }
        let written = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(written, 0, nil))
        #expect([CGColorSpace.displayP3, CGColorSpace.extendedDisplayP3].contains(image.colorSpace?.name))
    }

    @Test("Failed image writes report failure without completing")
    func failedExport() async throws {
        let url = try Self.writeImage(type: .png)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let source = try await StillImageSource(url: url)
        let output = url.deletingLastPathComponent().appending(path: "Missing/Keyed.png")
        let exporter = StillImageExporter(renderEngine: try StandaloneRenderEngine(), source: source,
                                          project: ExportProjectSnapshot(state: Self.neutralState(), cachedMattes: [:]))
        let events = Mutex<[ExportRunnerEvent]>([])
        await exporter.run(options: StillImageExportOptions(destination: output, format: .png)) { event in
            events.withLock { $0.append(event) }
        }
        #expect(events.withLock { $0.contains { if case .failed = $0 { true } else { false } } })
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test("Analysis consumes one still and builds a usable matte cache")
    func analysis() async throws {
        let url = try Self.writeImage(type: .png)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let source = try await StillImageSource(url: url)
        let engine = try StandaloneRenderEngine()
        let events = Mutex<[AnalysisRunnerEvent]>([])
        let runner = AnalysisRunner(renderEngine: engine, videoSource: source)
        await runner.run(state: Self.neutralState()) { event in events.withLock { $0.append(event) } }
        let entries = events.withLock { events in
            events.compactMap { event -> MatteCacheEntry? in
                if case .frameProcessed(let index, _, let entry) = event {
                    #expect(index == 0)
                    return entry
                }
                return nil
            }
        }
        #expect(entries.count == 1)
        #expect(events.withLock { $0.contains { if case .completed = $0 { true } else { false } } })
        let entry = try #require(entries.first)
        #expect(!entry.blob.isEmpty)
    }

    #if !CORRIDOR_KEY_HEADLESS_TESTS
    @Test("Editor loads stills, disables playback, keeps hints, and exports images")
    @MainActor
    func editorFlow() async throws {
        let url = try Self.writeImage(type: .png)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let model = EditorViewModel(renderEngine: try StandaloneRenderEngine())
        defer { model.closeClip() }
        await model.loadClip(at: url)
        #expect(model.phase.isReady)
        #expect(model.isStillImage)
        #expect(model.totalFrames == 1)
        model.togglePlayback()
        #expect(!model.isPlaying)
        model.scrub(toNormalized: 1)
        model.step(byFrames: 1)
        #expect(model.playheadTime == .zero)
        model.oscTool = .foregroundHint
        model.handleOSCClick(atNormalizedPoint: CGPoint(x: 0.5, y: 0.5))
        #expect(model.state.hintPointSet.points.count == 1)
        model.state = Self.neutralState()
        model.matteCache[0] = try Self.cache(alpha: 0.5)
        let output = url.deletingLastPathComponent().appending(path: "Editor.png")
        model.runExport(options: StillImageExportOptions(destination: output, format: .png))
        let deadline = ContinuousClock.now + .seconds(15)
        while model.exportStatus.inProgress, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(model.exportStatus == .completed(output))
        model.closeClip()
        #expect(!model.isStillImage)
        #expect(model.phase == .noClipLoaded)
    }
    #endif

    private static let cornerColors: [[UInt8]] = [[255, 0, 0, 255], [0, 0, 255, 255],
                                                  [0, 255, 0, 255], [255, 255, 255, 255]]

    private static func writeImage(
        type: UTType, orientation: Int = 1, width: Int = 64, height: Int = 48,
        colorSpace: CGColorSpace? = nil
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "StillImageTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "Source.\(type.preferredFilenameExtension ?? "image")")
        var pixels: [UInt8] = []
        for row in 0..<height {
            for column in 0..<width {
                pixels.append(contentsOf: cornerColors[(row >= height / 2 ? 2 : 0) + (column >= width / 2 ? 1 : 0)])
            }
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let colorSpace = try #require(colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                        bytesPerRow: width * 4, space: colorSpace,
                                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    private static func pixel(_ buffer: CVPixelBuffer, column: Int, row: Int) throws -> [UInt8] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let offset = row * CVPixelBufferGetBytesPerRow(buffer) + column * 4
        return [base[offset + 2], base[offset + 1], base[offset], base[offset + 3]]
    }

    private static func neutralState() -> PluginStateData {
        PluginStateData(qualityMode: .draft512, hintMode: .automatic, autoDespeckleEnabled: false,
                        refinerStrength: 0, despillStrength: 0, lightWrapEnabled: false,
                        edgeDecontaminateEnabled: false, temporalStabilityEnabled: false, upscaleMethod: .bilinear)
    }

    private static func cache(alpha: Float) throws -> MatteCacheEntry {
        let pixelCount = 512 * 512
        let foreground = [SIMD4<Float>](repeating: SIMD4(0.8, 0.2, 0.4, 1), count: pixelCount)
        let half = try foreground.withUnsafeBytes {
            try AnalysisFrameCodec.foregroundHalfRGBA(Array($0.bindMemory(to: Float.self)))
        }
        let blob = try AnalysisFrameCodec.encode(alpha: [Float](repeating: alpha, count: pixelCount),
                                                 foregroundHalfRGBA: half, width: 512, height: 512)
        return MatteCacheEntry(blob: blob, width: 512, height: 512, inferenceResolution: 512)
    }
}
