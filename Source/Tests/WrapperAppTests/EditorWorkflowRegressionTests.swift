import AVFoundation
import Foundation
import SwiftUI
import Testing
@testable import CorridorKeyByLateNiteApp

// Share the editor suite's serialization: its termination test intentionally
// cancels every registered editor, including a concurrently running benchmark.
extension EditorViewModelTests {
    @Test("A keyed batch analyses automatically and writes a transparent ProRes movie")
    func keyedBatchExports() async throws {
        let url = try await SyntheticVideoFixture.writeMP4(frameCount: 2, fps: 24)
        let folder = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = BatchExportModel(engine: try StandaloneRenderEngine())
        model.add([url])
        model.selectDestination(folder)
        let settings = PluginStateData(qualityMode: .draft512, hintMode: .none)
        model.start(state: settings)
        let deadline = ContinuousClock.now.advanced(by: .seconds(90))
        while model.isRunning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        if model.isRunning, let task = model.cancel() { await task.value }
        guard case .completed(let output) = model.items[0].status else {
            Issue.record("Keyed batch did not complete: \(model.items[0].status)")
            return
        }
        let decoded = try await VideoSource(url: output)
        #expect(decoded.totalFrameCount() == 2)
        let buffer = try await decoded.makeFrame(atTime: .zero, preferredPixelFormat: kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        // The synthetic source is opaque. A transparent corner proves the queue
        // used the generated matte rather than exporting source pass-through.
        #expect(base[3] < 128)
    }

    @Test("Undo and redo restore both settings and the correct analysis generation")
    func undoRestoresAnalysis() throws {
        let model = EditorViewModel(renderEngine: try StandaloneRenderEngine())
        model.state = PluginStateData()
        model.phase = .ready
        let manager = UndoManager()
        manager.groupsByEvent = false
        model.undoManager = manager
        let savedPreferences = EditorPreferences.makeInitialState()
        defer {
            EditorPreferences.qualityMode = savedPreferences.qualityMode
            EditorPreferences.hintMode = savedPreferences.hintMode
            EditorPreferences.upscaleMethod = savedPreferences.upscaleMethod
            model.closeClip()
        }
        let session = try AnalysisDiskCache.shared.beginSession()
        let blob = try AnalysisFrameCodec.encode(alpha: [0.25], foregroundHalfRGBA: Data(count: 8), width: 1, height: 1)
        let reference = try AnalysisDiskCache.shared.store(blob, in: session)
        model.matteCache[0] = MatteCacheEntry(reference: reference, width: 1, height: 1, inferenceResolution: 512)
        let originalStatus = EditorAnalysisStatus.completed(elapsedSeconds: 2, totalFrames: 1)
        model.analysisStatus = originalStatus
        let original = model.state
        manager.beginUndoGrouping()
        model.state.video.timeAwareness = .four
        manager.endUndoGrouping()
        #expect(model.matteCache.isEmpty)
        manager.undo()
        #expect(model.state == original)
        #expect(model.analysisStatus == originalStatus)
        #expect(try model.matteCache[0]?.blob == blob)
        manager.redo()
        #expect(model.state.video.timeAwareness == .four)
        #expect(model.matteCache.isEmpty)
        #expect(model.analysisStatus == .idle)
        // New analysis after a redo must itself be retained by the next undo.
        model.matteCache[0] = MatteCacheEntry(blob: Data([9]), width: 1, height: 1, inferenceResolution: 512)
        model.analysisStatus = .completed(elapsedSeconds: 3, totalFrames: 1)
        manager.undo()
        #expect(try model.matteCache[0]?.blob == blob)
        manager.redo()
        #expect(try model.matteCache[0]?.blob == Data([9]))
    }

    @Test("A slider gesture is one undo and output-only edits keep analysis")
    func sliderUndoIsCoalesced() throws {
        let model = EditorViewModel(renderEngine: try StandaloneRenderEngine())
        let preferences = EditorPreferences.makeInitialState()
        defer {
            EditorPreferences.qualityMode = preferences.qualityMode
            EditorPreferences.hintMode = preferences.hintMode
            EditorPreferences.upscaleMethod = preferences.upscaleMethod
            model.closeClip()
        }
        model.state = PluginStateData()
        let manager = UndoManager()
        manager.groupsByEvent = false
        model.undoManager = manager
        model.phase = .ready
        model.matteCache[0] = MatteCacheEntry(blob: Data([1]), width: 1, height: 1, inferenceResolution: 512)
        model.parameterEditingChanged(true)
        manager.beginUndoGrouping()
        model.state.alphaGamma = 1.1
        manager.endUndoGrouping()
        for value in [1.2, 1.3] {
            model.state.alphaGamma = value
        }
        model.parameterEditingChanged(false)
        #expect(model.matteCache.count == 1)
        manager.undo()
        #expect(model.state.alphaGamma == 1)
        #expect(model.matteCache.count == 1)
        #expect(!manager.canUndo)
        manager.redo()
        #expect(model.state.alphaGamma == 1.3)
        model.matteCache[1] = MatteCacheEntry(blob: Data([2]), width: 1, height: 1, inferenceResolution: 512)
        model.analysisStatus = .running(processed: 2, total: 3)
        manager.undo()
        #expect(model.matteCache.count == 2)
        #expect(model.analysisStatus == .running(processed: 2, total: 3))
        model.analysisStatus = .completed(elapsedSeconds: 1, totalFrames: 2)
        // Adjusting an inactive temporal control cannot invalidate the key.
        manager.beginUndoGrouping()
        model.state.temporalStabilityStrength = 0.8
        manager.endUndoGrouping()
        #expect(model.matteCache.count == 2)
        model.closeClip()
    }

    @Test("Batch filenames preserve existing files and distinguish matching basenames")
    func batchNamesAreUnique() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let existing = folder.appending(path: "Shot (Keyed).mov")
        try Data([1, 2, 3]).write(to: existing)
        let outputs = BatchExportNaming.destinations(for: [URL(filePath: "/a/Shot.mov"), URL(filePath: "/b/Shot.mov")], in: folder)
        #expect(outputs.map(\.lastPathComponent) == ["Shot (Keyed) 2.mov", "Shot (Keyed) 3.mov"])
        #expect(try Data(contentsOf: existing) == Data([1, 2, 3]))
        var state = PluginStateData(hintMode: .manual)
        state.hintPointSet.add(HintPoint(x: 0.5, y: 0.5, kind: .foreground))
        state.video.useAlphaHint = true
        state.despillStrength = 0.25
        state.video.timeAwareness = .four
        let settings = BatchExportNaming.sharedSettings(from: state)
        #expect(settings.hintPointSet.isEmpty)
        #expect(settings.hintMode == .automatic)
        #expect(!settings.video.useAlphaHint)
        #expect(settings.despillStrength == 0.25)
        #expect(settings.video.timeAwareness == .four)
    }

    @Test("Batch continues after failure, preserves completed shots, and cancels pending work")
    func batchFailureCancellationAndRetry() async throws {
        let sourceURL = try await SyntheticVideoFixture.writeMP4(frameCount: 3, fps: 24)
        let folder = sourceURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let badURL = folder.appending(path: "Broken.mov")
        try Data([0]).write(to: badURL)
        let model = BatchExportModel(engine: try StandaloneRenderEngine())
        model.add([badURL, sourceURL, sourceURL])
        #expect(model.items.count == 2)
        model.selectDestination(folder)
        var state = PluginStateData()
        state.outputMode = .original
        model.start(state: state)
        let deadline = ContinuousClock.now.advanced(by: .seconds(45))
        while model.isRunning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!model.isRunning)
        guard case .failed = model.items[0].status else { Issue.record("Corrupt source should fail individually"); return }
        guard case .completed(let output) = model.items[1].status else { Issue.record("Valid second shot should export"); return }
        let source = try await VideoSource(url: output)
        #expect(source.totalFrameCount() == 3)
        #expect(model.pendingCount == 1)
        model.start(state: state)
        if let task = model.cancel() { await task.value }
        #expect(!model.isRunning)
        #expect(model.items[1].status == .completed(output))
        #expect(model.items[0].status == .cancelled)
        // A competing destination must never be deleted by a batch exporter.
        let originalBytes = try Data(contentsOf: output)
        let exporter = ProResExporter(renderEngine: try StandaloneRenderEngine(), videoSource: source,
                                     project: ExportProjectSnapshot(state: state, cachedMattes: [:]))
        await exporter.run(options: ExportOptions(destination: output, codec: .proRes4444,
                                                  preserveAlpha: true, overwriteExisting: false)) { _ in }
        #expect(try Data(contentsOf: output) == originalBytes)
    }

    @Test("Unanalysed preview aliases the source and ProRes playback reaches realtime")
    func proResPlayback() async throws {
        let repository = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = repository.appending(path: "LLM Resources/Benchmark/JallenClownWater/Input/HardestShotEver - 1sec.mov")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let engine = try StandaloneRenderEngine()
        let source = try await VideoSource(url: url)
        let reader = try await PlaybackFrameReader(source: source, startTime: .zero)
        let frame = try #require(try await reader.nextFrame())
        let renderer = StandalonePreviewRenderer(engine: engine)
        let result = try await renderer.render(frame: frame, state: PluginStateData())
        #expect(result.destinationPixelBuffer === frame.pixelBuffer)
        #expect(result.report.effectiveInferenceResolution == 0)
        let model = EditorViewModel(renderEngine: engine)
        await model.loadClip(at: url)
        model.loopEnabled = true
        model.togglePlayback()
        try await Task.sleep(for: .seconds(3))
        let achieved = model.measuredPlaybackFPS
        print("JallenClownWater 4K ProRes editor playback: \(achieved) fps; target \(model.targetPlaybackFPS) fps")
        #expect(model.isPlaying)
        #expect(model.warmupStatus == .cold)
        #expect(achieved >= Double(source.info.nominalFrameRate) * 0.95)
        model.closeClip()
        for task in model.cancelWorkForEditorShutdown() { await task.value }
    }
}
