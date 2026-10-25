//
//  AnalysisAndExportTests.swift
//  CorridorKey by LateNite — WrapperAppTests
//
//  End-to-end tests for the standalone editor's two background
//  passes:
//
//  * `AnalysisRunner` — walks every frame of a clip, builds matte
//    blobs, fires status events.
//  * `ProResExporter` — replays the clip through the keyer using the
//    cached mattes and writes a ProRes 4444 .mov.
//
//  Both paths use a synthetic 12-frame clip so the suite finishes
//  in a few seconds even on the slowest M-series chip we ship to.
//

import Testing
import Foundation
import AVFoundation
import CoreMedia
import Metal
@testable import CorridorKeyByLateNiteApp

@Suite("AnalysisRunner & ProResExporter", .serialized)
struct AnalysisAndExportTests {

    @Test("analyse pass walks every frame and reports completion")
    func analysisCoversEveryFrame() async throws {
        let url = try await SyntheticVideoFixture.writeMP4(frameCount: 8, fps: 24)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let engine = try StandaloneRenderEngine()
        let source = try await VideoSource(url: url)
        let runner = AnalysisRunner(renderEngine: engine, videoSource: source)

        let collector = EventCollector<AnalysisRunnerEvent>()
        await runner.run(state: PluginStateData(qualityMode: .draft512)) { event in
            collector.append(event)
        }
        let events = collector.snapshot()

        let processedCount = events.reduce(into: 0) { count, event in
            if case .frameProcessed = event { count += 1 }
        }
        #expect(processedCount == 8)
        let completed = events.contains { event in
            if case .completed = event { return true }
            return false
        }
        #expect(completed)
    }

    @Test("matte cache survives the analyse pass with one entry per source frame")
    func analysisFillsMatteCache() async throws {
        let url = try await SyntheticVideoFixture.writeMP4(frameCount: 6, fps: 24)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let engine = try StandaloneRenderEngine()
        let source = try await VideoSource(url: url)
        let runner = AnalysisRunner(renderEngine: engine, videoSource: source)

        let cacheCollector = MatteCacheCollector()
        await runner.run(state: PluginStateData(qualityMode: .draft512)) { event in
            if case let .frameProcessed(index, _, entry) = event {
                cacheCollector.set(index: index, entry: entry)
            }
        }
        let cache = cacheCollector.snapshot()
        #expect(cache.count == 6)
        for entry in cache.values {
            #expect(try !entry.blob.isEmpty)
            #expect(entry.inferenceResolution > 0)
        }
    }

    @Test("temporal analysis exports a playable linear ProRes 4444 movie with matching color tags")
    func exportProducesPlayableMOV() async throws {
        let inputURL = try await SyntheticVideoFixture.writeMP4(frameCount: 6, fps: 24)
        defer { try? FileManager.default.removeItem(at: inputURL.deletingLastPathComponent()) }

        let engine = try StandaloneRenderEngine()
        let source = try await VideoSource(url: inputURL)
        var state = PluginStateData(qualityMode: .draft512)
        state.video.timeAwareness = .four
        state.video.linearizeOutput = true
        // A synchronized movie exercises the external matte reader all the
        // way through analysis, sandbox access, cached rendering and export.
        state.video.useAlphaHint = true
        state.video.alphaHintAsset = try AlphaHintAsset(url: inputURL)

        // Run analysis so the exporter has cached mattes to feed.
        let runner = AnalysisRunner(renderEngine: engine, videoSource: source)
        let cacheCollector = MatteCacheCollector()
        await runner.run(state: state) { event in
            if case let .frameProcessed(index, _, entry) = event {
                cacheCollector.set(index: index, entry: entry)
            }
        }
        let cache = cacheCollector.snapshot()
        try #require(cache.count == 6, "Temporal analysis with a matching external movie must produce all six frames before export")

        let outputURL = inputURL.deletingLastPathComponent()
            .appending(path: "Output.mov")
        let snapshot = ExportProjectSnapshot(
            state: state,
            cachedMattes: cache
        )
        let exporter = ProResExporter(
            renderEngine: engine,
            videoSource: source,
            project: snapshot
        )
        let collector = EventCollector<ExportRunnerEvent>()
        await exporter.run(options: ExportOptions(
            destination: outputURL,
            codec: .proRes4444,
            preserveAlpha: true
        )) { event in
            collector.append(event)
        }
        let events = collector.snapshot()

        let completed = events.contains { event in
            if case .completed = event { return true }
            return false
        }
        #expect(completed, "Export did not complete: \(events)")
        #expect(FileManager.default.fileExists(atPath: outputURL.path))

        // Verify the written file is a real movie AV Foundation can
        // read back — same gate FCP would apply on import.
        let writtenAsset = AVURLAsset(url: outputURL)
        let writtenTracks = try await writtenAsset.loadTracks(withMediaType: .video)
        #expect(writtenTracks.count == 1)
        let writtenDuration = try await writtenAsset.load(.duration)
        #expect(writtenDuration.seconds > 0.20)
        let writtenTrack = try #require(writtenTracks.first)
        let descriptions = try await writtenTrack.load(.formatDescriptions)
        let description = try #require(descriptions.first)
        let transfer = CMFormatDescriptionGetExtension(
            description, extensionKey: kCMFormatDescriptionExtension_TransferFunction
        ) as? String
        #expect(transfer == kCVImageBufferTransferFunction_Linear as String)
    }

    @Test("external hint movies reject mismatched timing and seek to the requested preview frame")
    func hintMovieTimingAndPreview() async throws {
        let url = try await SyntheticVideoFixture.writeMP4(frameCount: 6)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var settings = VideoInferenceSettings()
        settings.useAlphaHint = true
        settings.alphaHintAsset = try AlphaHintAsset(url: url)
        let source = try await VideoSource(url: url)
        #expect(source.totalFrameCount() == 6)
        await #expect(throws: VideoInferenceSettingsError.self) {
            _ = try await AlphaHintReader(settings: settings, frameCount: 5, frameDuration: CMTime(value: 1, timescale: 24))
        }
        await #expect(throws: VideoInferenceSettingsError.self) {
            _ = try await AlphaHintReader(settings: settings, frameCount: 6, frameDuration: CMTime(value: 1, timescale: 30))
        }
        let engine = try StandaloneRenderEngine()
        let queue = try #require(engine.device.makeCommandQueue())
        let sequential = try await AlphaHintReader(settings: settings, frameCount: 6, frameDuration: CMTime(value: 1, timescale: 24))
        var expected: (any MTLTexture)?
        for index in 0...3 {
            expected = try sequential.texture(frameIndex: index, sourceWidth: 320, sourceHeight: 180,
                                              device: engine.device, commandQueue: queue)
        }
        let preview = try await AlphaHintReader(settings: settings, frameCount: 0, frameDuration: .invalid, previewFrame: 3)
        let actual = try #require(try preview.texture(frameIndex: 3, sourceWidth: 320, sourceHeight: 180,
                                                    device: engine.device, commandQueue: queue))
        let reference = try #require(expected)
        var referenceBytes = [UInt16](repeating: 0, count: 320 * 180 * 4)
        var actualBytes = referenceBytes
        try referenceBytes.withUnsafeMutableBytes {
            let address = try #require($0.baseAddress)
            reference.getBytes(address, bytesPerRow: 320 * 8,
                               from: MTLRegionMake2D(0, 0, 320, 180), mipmapLevel: 0)
        }
        try actualBytes.withUnsafeMutableBytes {
            let address = try #require($0.baseAddress)
            actual.getBytes(address, bytesPerRow: 320 * 8,
                            from: MTLRegionMake2D(0, 0, 320, 180), mipmapLevel: 0)
        }
        #expect(actualBytes == referenceBytes)
    }
}

/// Tiny thread-safe collector for `@Sendable` event closures.
final class EventCollector<Event>: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [Event] = []

    func append(_ event: Event) {
        lock.lock(); defer { lock.unlock() }
        events.append(event)
    }

    func snapshot() -> [Event] {
        lock.lock(); defer { lock.unlock() }
        return events
    }
}

/// Thread-safe matte-cache assembler so a `@Sendable` event handler
/// can drop per-frame entries into a shared dictionary without falling
/// foul of Swift 6 strict concurrency.
final class MatteCacheCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [Int: MatteCacheEntry] = [:]

    func set(index: Int, entry: MatteCacheEntry) {
        lock.lock(); defer { lock.unlock() }
        entries[index] = entry
    }

    func snapshot() -> [Int: MatteCacheEntry] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }
}
