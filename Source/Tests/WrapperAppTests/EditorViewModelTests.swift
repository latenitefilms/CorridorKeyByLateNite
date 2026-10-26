//
//  EditorViewModelTests.swift
//  CorridorKey by LateNite — WrapperAppTests
//
//  Drives the @Observable view model that owns the editor window.
//  These tests would have caught the original "permission denied"
//  regression — `loadClip(at:)` is exactly the entry point the
//  `.fileImporter` callback in `EditorView` calls, so anything that
//  blocks at the AVURLAsset layer surfaces here.
//

import Testing
import SwiftUI
import Foundation
import CoreMedia
@testable import CorridorKeyByLateNiteApp

@Suite("EditorViewModel", .serialized)
@MainActor
struct EditorViewModelTests {

    @Test("Reset All restores factory settings, invalidates changed analysis and supports one-step undo")
    func resetAllParameters() throws {
        let model = EditorViewModel(renderEngine: try StandaloneRenderEngine())
        let preferences = EditorPreferences.makeInitialState()
        defer {
            EditorPreferences.qualityMode = preferences.qualityMode
            EditorPreferences.hintMode = preferences.hintMode
            EditorPreferences.upscaleMethod = preferences.upscaleMethod
        }
        model.state = PluginStateData(qualityMode: .draft512, hintMode: .manual,
            alphaGamma: 1.4, lightWrapEnabled: true, edgeDecontaminateEnabled: true)
        model.state.video.timeAwareness = .four
        model.state.video.keepOriginalInSolidAreas = true
        let previous = model.state
        model.matteCache[0] = MatteCacheEntry(blob: Data([1]), width: 1, height: 1, inferenceResolution: 512)
        model.analysisStatus = .completed(elapsedSeconds: 1, totalFrames: 1)
        model.phase = .ready
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        model.resetAllParameters()
        #expect(model.state == PluginStateData())
        #expect(model.matteCache.isEmpty)
        #expect(model.analysisStatus == .idle)
        #expect(undo.undoActionName == "Reset All Parameters")
        undo.undo()
        #expect(model.state == previous)
        #expect(model.matteCache.count == 1)
        #expect(!undo.canUndo)
        undo.redo()
        #expect(model.state == PluginStateData())
        #expect(model.matteCache.isEmpty)
        model.closeClip()
    }

    @Test("Opening an empty standalone editor requests model warm-up before import")
    func editorLaunchWarmup() async throws {
        let model = EditorViewModel(renderEngine: try StandaloneRenderEngine())
        model.state.qualityMode = .draft512
        #expect(model.warmupStatus == .cold)
        model.prepareModelForEditor()
        #expect(model.clipInfo == nil)
        #expect(model.warmupStatus == .warming(resolution: 512) || model.warmupStatus == .ready(resolution: 512))
        model.prepareModelForEditor()
        model.closeClip()
        #expect(model.warmupStatus != .cold, "Closing media must not cancel editor-level warm-up.")
        let other = EditorViewModel(renderEngine: try StandaloneRenderEngine())
        other.state.qualityMode = .draft512
        other.prepareModelForEditor()
        for task in model.cancelWorkForEditorShutdown() { await task.value }
        #expect(other.renderEngine.warmupStatus(forResolution: 512, screenColor: other.state.screenColor) != .cold,
                "Closing one window must not cancel another window's shared model load.")
        for task in other.cancelWorkForEditorShutdown() { await task.value }
    }

    @Test("Inspector renders empty, single-frame and multi-frame reference sliders", arguments: [0, 1, 2, 120])
    func inspectorRendersReferenceFrameSlider(totalFrames: Int) throws {
        let viewModel = EditorViewModel(renderEngine: try StandaloneRenderEngine())
        viewModel.totalFrames = totalFrames

        // Exercise both the initially disabled control and Single Frame mode.
        // Disabling a stepped Slider does not prevent its range validation.
        for hintFrames in [AlphaHintFrames.allFrames, .singleFrame] {
            viewModel.state.video.hintFrames = hintFrames
            let renderer = ImageRenderer(content: InspectorView(viewModel: viewModel)
                .frame(width: 400, height: 900))
            let image = try #require(renderer.cgImage)
            #expect(image.width > 0)
            #expect(image.height > 0)
            #expect(viewModel.state.video.referenceFrame == 0)
        }
    }

    @Test("Missing local analysis keeps Analyse Clip available and retains failing export references")
    func missingCacheCanBeAnalysedAgain() async throws {
        let url = try await SyntheticVideoFixture.writeMP4(frameCount: 1, fps: 24)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let viewModel = EditorViewModel(renderEngine: try StandaloneRenderEngine())
        await viewModel.loadClip(at: url)
        for task in viewModel.cancelWorkForEditorShutdown() { await task.value }
        viewModel.state.qualityMode = .draft512
        viewModel.matteCache[0] = MatteCacheEntry(
            reference: AnalysisFrameReference(sessionID: UUID(), frameID: UUID(), byteCount: 100),
            width: 512, height: 512, inferenceResolution: 512
        )
        viewModel.renderPreview(at: .zero)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if case .failed = viewModel.analysisStatus { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(viewModel.phase.isReady)
        #expect(viewModel.analysisStatus == .failed(AnalysisDiskCacheError.missingFrame.localizedDescription))
        #expect(viewModel.latestPreview == nil)
        #expect(viewModel.matteCache[0]?.reference != nil)
        viewModel.closeClip()
    }

    @Test("loads a synthetic MP4 and transitions to .ready with clip metadata populated")
    func loadsClipFromFileImporterURL() async throws {
        let url = try await SyntheticVideoFixture.writeMP4()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let engine = try StandaloneRenderEngine()
        let viewModel = EditorViewModel(renderEngine: engine)
        await viewModel.loadClip(at: url)

        #expect(viewModel.phase.isReady, "View model should be ready, instead got: \(viewModel.phase)")
        #expect(viewModel.clipInfo?.url == url)
        #expect(viewModel.totalFrames > 0)
        #expect(viewModel.renderSize == CGSize(width: 320, height: 180))
    }

    @Test("step button advances and rewinds the playhead by whole frames")
    func stepAdvancesPlayheadByWholeFrames() async throws {
        let url = try await SyntheticVideoFixture.writeMP4()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let engine = try StandaloneRenderEngine()
        let viewModel = EditorViewModel(renderEngine: engine)
        await viewModel.loadClip(at: url)
        let initialFrame = framesAtPlayhead(viewModel)

        viewModel.step(byFrames: 3)
        #expect(framesAtPlayhead(viewModel) == initialFrame + 3)

        viewModel.step(byFrames: -2)
        #expect(framesAtPlayhead(viewModel) == initialFrame + 1)

        // Advancing past the end should clamp to the last frame.
        viewModel.step(byFrames: 999)
        #expect(framesAtPlayhead(viewModel) == viewModel.totalFrames - 1)
    }

    @Test("closeClip returns the editor to the empty state and drops the cache")
    func closeClipResetsState() async throws {
        let url = try await SyntheticVideoFixture.writeMP4()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let engine = try StandaloneRenderEngine()
        let viewModel = EditorViewModel(renderEngine: engine)
        await viewModel.loadClip(at: url)
        viewModel.matteCache[0] = MatteCacheEntry(
            blob: Data([0]),
            width: 1,
            height: 1,
            inferenceResolution: 512
        )
        viewModel.closeClip()
        #expect(viewModel.phase == .noClipLoaded)
        #expect(viewModel.clipInfo == nil)
        #expect(viewModel.matteCache.isEmpty)
    }

    @Test("loading a clip that doesn't exist surfaces a load failure phase")
    func loadFailureIsRecoverable() async throws {
        let bogus = FileManager.default.temporaryDirectory
            .appending(path: "Definitely-Not-Real-\(UUID().uuidString).mp4")
        let engine = try StandaloneRenderEngine()
        let viewModel = EditorViewModel(renderEngine: engine)
        await viewModel.loadClip(at: bogus)
        if case .loadFailed = viewModel.phase {
            // expected
        } else {
            Issue.record("Expected .loadFailed phase, got \(viewModel.phase)")
        }
    }

    @Test("editing a parameter does not crash even with no clip loaded")
    func parameterChangeIsSafeWithoutClip() throws {
        let engine = try StandaloneRenderEngine()
        let viewModel = EditorViewModel(renderEngine: engine)
        viewModel.state.alphaGamma = 1.5
        viewModel.parameterDidChange()
        #expect(viewModel.phase == .noClipLoaded)
    }

    @Test("app termination cancellation reaches the active analysis runner")
    func terminationCancellationStopsActiveAnalysisRunner() async throws {
        let url = try await SyntheticVideoFixture.writeMP4(frameCount: 24, fps: 24)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let engine = try StandaloneRenderEngine()
        let viewModel = EditorViewModel(renderEngine: engine)
        await viewModel.loadClip(at: url)
        for task in viewModel.cancelWorkForEditorShutdown() {
            await task.value
        }

        viewModel.state.qualityMode = .draft512
        viewModel.runAnalysis()
        #expect(viewModel.hasInflightEditorWork)
        #expect(EditorWorkRegistry.shared.hasInflightEditorWork)

        let tasks = EditorWorkRegistry.shared.cancelAllWorkForAppTermination()
        #expect(tasks.count >= 2, "Expected both the UI task and analysis runner task to be cancelled.")

        for task in tasks {
            await task.value
        }
        #expect(!viewModel.hasInflightEditorWork)
    }

    @Test("Quality-Mode change picks an inference resolution within the supported ladder")
    func qualityModeRespectsLadder() {
        for mode in QualityMode.allCases {
            let resolution = mode.resolvedInferenceResolution(forLongEdge: 1920)
            let supported = QualityMode.inferenceLadder
            #expect(supported.contains(resolution),
                    "QualityMode \(mode) resolved to \(resolution), outside the ladder \(supported)")
        }
    }

    @Test("Manual hints edit and undo only their source frame and invalidate analysed mattes")
    func manualHintFrameEditing() throws {
        let viewModel = EditorViewModel(renderEngine: try StandaloneRenderEngine())
        let savedHintMode = EditorPreferences.hintMode
        defer { EditorPreferences.hintMode = savedHintMode }
        // Metadata alone exercises editing without starting a decoder or model warm-up.
        viewModel.clipInfo = MediaSourceInfo(
            url: URL(fileURLWithPath: "/tmp/hint-editing.mov"), renderSize: CGSize(width: 320, height: 180),
            nominalFrameRate: 24, duration: CMTime(value: 4, timescale: 24), nativePixelFormat: 0,
            timescale: 24000, videoTrackID: 1, preferredTransform: .identity,
            colorPrimaries: nil, transferFunction: nil, yCbCrMatrix: nil
        )
        let undo = UndoManager()
        undo.groupsByEvent = false
        viewModel.undoManager = undo
        viewModel.state.hintMode = .manual
        viewModel.matteCache[0] = MatteCacheEntry(blob: Data([1]), width: 1, height: 1, inferenceResolution: 512)
        viewModel.analysisStatus = .completed(elapsedSeconds: 1, totalFrames: 1)
        viewModel.oscTool = .foregroundHint
        viewModel.phase = .ready
        undo.beginUndoGrouping()
        viewModel.handleOSCClick(atNormalizedPoint: CGPoint(x: 0.5, y: 0.5))
        undo.endUndoGrouping()
        #expect(viewModel.currentFrameHints.count == 1)
        #expect(viewModel.matteCache.isEmpty)
        #expect(viewModel.analysisStatus == .idle)

        viewModel.playheadTime = CMTime(value: 1, timescale: 24)
        #expect(viewModel.currentFrameHints.isEmpty)
        viewModel.oscTool = .ignoreHint
        undo.beginUndoGrouping()
        viewModel.handleOSCClick(atNormalizedPoint: CGPoint(x: 0.5, y: 0.5))
        undo.endUndoGrouping()
        #expect(viewModel.state.hintPointSet.points.count == 2)
        #expect(viewModel.currentFrameHints.first?.kind == .ignore)

        undo.beginUndoGrouping()
        viewModel.clearHintsOnCurrentFrame()
        undo.endUndoGrouping()
        #expect(viewModel.currentFrameHints.isEmpty)
        #expect(viewModel.state.hintPointSet.points.count == 1)
        // Undo after seeking must restore the original frame, not the new playhead.
        viewModel.playheadTime = .zero
        undo.undo()
        #expect(viewModel.currentFrameHints.first?.kind == .foreground)
        #expect(viewModel.state.hintPointSet.points.count == 2)
        viewModel.playheadTime = CMTime(value: 1, timescale: 24)
        #expect(viewModel.currentFrameHints.first?.kind == .ignore)
        undo.redo()
        #expect(viewModel.currentFrameHints.isEmpty)
        viewModel.closeClip()
        #expect(viewModel.state.hintPointSet.isEmpty)
        #expect(!undo.canUndo)
    }

    @Test("Changing Hint mode invalidates the cache while post-processing keeps it")
    func hintModeCacheInvalidation() throws {
        let viewModel = EditorViewModel(renderEngine: try StandaloneRenderEngine())
        viewModel.matteCache[0] = MatteCacheEntry(blob: Data([1]), width: 1, height: 1, inferenceResolution: 512)
        viewModel.state.alphaGamma = 1.3
        #expect(viewModel.matteCache.count == 1)
        viewModel.state.hintMode = viewModel.state.hintMode == .manual ? .automatic : .manual
        #expect(viewModel.matteCache.isEmpty)
    }

    private func framesAtPlayhead(_ viewModel: EditorViewModel) -> Int {
        let fps = max(Double(viewModel.clipInfo?.nominalFrameRate ?? 1), 0.001)
        return Int((viewModel.playheadTime.seconds * fps).rounded())
    }
}
