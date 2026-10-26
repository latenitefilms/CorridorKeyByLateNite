//
//  TransportPolishTests.swift
//  CorridorKey by LateNite — WrapperAppTests
//
//  Targeted regressions for the round of UI polish that landed in
//  v1.0:
//
//  * Frame counter — for an N-frame clip the "current / total"
//    label must never read N+1, even when the playhead lands on
//    the asset's exact duration (which is one frame past the last
//    sample's presentation time).
//  * Timecode formatting — HH:MM:SS:FF (non-drop-frame), not the
//    older HH:MM:SS.ss centisecond format.
//  * Preview-backdrop state — the right-click context menu mutates
//    `EditorViewModel.previewBackdrop`, so the view binding has to
//    be readable and writable from any actor.
//

import Testing
import Foundation
import CoreMedia
@testable import CorridorKeyByLateNiteApp

@Suite("Transport polish", .serialized)
struct TransportPolishTests {

    @Test("Playback publishes matching frame timing and comparison reuses the paused source")
    @MainActor
    func comparisonStaysOnPresentedFrame() async throws {
        let url = try await SyntheticVideoFixture.writeMP4(frameCount: 8, fps: 25)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let model = EditorViewModel(renderEngine: try StandaloneRenderEngine())
        model.state.outputMode = .original
        await model.loadClip(at: url)
        defer { model.closeClip() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while model.latestPreview == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = try #require(model.latestPreview)
        model.togglePlayback()
        for _ in 0..<80 {
            try await Task.sleep(for: .milliseconds(5))
            let displayed = try #require(model.latestPreview)
            #expect(model.playheadTime == displayed.presentationTime)
        }
        model.togglePlayback()
        let paused = try #require(model.latestPreview)
        #expect(model.playheadTime == paused.presentationTime)
        for showingOriginal in [true, false, true, false] {
            model.isShowingOriginal = showingOriginal
            try await Task.sleep(for: .milliseconds(30))
            let compared = try #require(model.latestPreview)
            #expect(model.playheadTime == paused.presentationTime)
            #expect(compared.presentationTime == paused.presentationTime)
            // Original output aliases the decoder buffer. Retaining this exact
            // buffer prevents random-access decoding from choosing a nearby sample.
            #expect(compared.pixelBuffer === paused.pixelBuffer)
        }
    }

    @Test("Frame stepping and boundary jumps pause playback and clamp to actual samples")
    @MainActor
    func navigationPausesPlayback() throws {
        let model = EditorViewModel(renderEngine: try StandaloneRenderEngine())
        model.clipInfo = MediaSourceInfo(
            url: URL(filePath: "/tmp/transport-test.mov"), renderSize: CGSize(width: 1920, height: 1080),
            nominalFrameRate: 25, duration: CMTime(value: 4, timescale: 25), nativePixelFormat: 0,
            timescale: 25000, videoTrackID: 1, preferredTransform: .identity,
            colorPrimaries: nil, transferFunction: nil, yCbCrMatrix: nil
        )
        model.totalFrames = 4
        model.phase = .ready
        model.togglePlayback()
        #expect(model.isPlaying)
        model.step(byFrames: 1)
        #expect(!model.isPlaying)
        #expect(abs(model.playheadTime.seconds - 0.04) < 0.0001)
        model.togglePlayback()
        model.jumpToLastFrame()
        #expect(!model.isPlaying)
        #expect(abs(model.playheadTime.seconds - 0.12) < 0.0001)
        model.step(byFrames: 1)
        #expect(abs(model.playheadTime.seconds - 0.12) < 0.0001)
        model.togglePlayback()
        model.jumpToFirstFrame()
        #expect(!model.isPlaying)
        #expect(model.playheadTime == .zero)
        model.step(byFrames: -1)
        #expect(model.playheadTime == .zero)
        model.totalFrames = 1
        model.jumpToLastFrame()
        #expect(model.playheadTime == .zero)
        model.closeClip()
    }

    @Test("nearestFrameTime clamps to the last valid frame so the counter never overshoots")
    func nearestFrameTimeClampsToLastFrame() async throws {
        let synthURL = try await SyntheticVideoFixture.writeMP4(frameCount: 4, fps: 24)
        defer { try? FileManager.default.removeItem(at: synthURL.deletingLastPathComponent()) }
        let source = try await VideoSource(url: synthURL)
        try #require(source.totalFrameCount() == 4)
        let durationSeconds = source.info.duration.seconds
        // The asset's duration is exactly `frameCount / fps` — one
        // frame-duration past the last sample's presentation time.
        // Asking for a snap at duration must still resolve to the
        // last sample (frame index 3), not frame index 4.
        let snappedAtDuration = source.nearestFrameTime(
            to: CMTime(seconds: durationSeconds, preferredTimescale: 24_000)
        )
        let snappedFrameIndex = Int((snappedAtDuration.seconds * 24.0).rounded())
        #expect(snappedFrameIndex == 3, "nearestFrameTime should cap at the last valid frame index, got \(snappedFrameIndex).")

        // Past-the-end inputs collapse onto the last frame too, so
        // a long scrub or a programmatic seek that overshoots
        // never produces an "off-by-one" counter glimpse.
        let snappedPastEnd = source.nearestFrameTime(
            to: CMTime(seconds: durationSeconds * 5, preferredTimescale: 24_000)
        )
        #expect(Int((snappedPastEnd.seconds * 24.0).rounded()) == 3)
    }

    @Test("scrubbing the editor view model to the right end never exceeds the total frame count")
    @MainActor
    func scrubToEndStaysAtLastFrame() async throws {
        let synthURL = try await SyntheticVideoFixture.writeMP4(frameCount: 4, fps: 24)
        defer { try? FileManager.default.removeItem(at: synthURL.deletingLastPathComponent()) }
        let engine = try StandaloneRenderEngine()
        let viewModel = EditorViewModel(renderEngine: engine)
        await viewModel.loadClip(at: synthURL)
        try #require(viewModel.phase.isReady)
        try #require(viewModel.totalFrames == 4)

        viewModel.scrub(toNormalized: 1.0)
        let frameIndex = Int((viewModel.playheadTime.seconds * 24).rounded())
        #expect(frameIndex == 3, "Scrub-to-end produced frame index \(frameIndex); the transport bar would read 'N+1 / N f'.")
    }

    /// Slider position 1.0 must put the playhead on the **last
    /// frame**. Repeats the round-trip across every frame index
    /// so short clips can't sneak in a regression at the boundary
    /// — the legacy duration-based mapping topped out at 0.75 on
    /// a 4-frame clip, hiding the final sample behind the right
    /// edge of the slider.
    @Test("Slider reaches the last frame on a 4-frame clip and round-trips at every frame")
    @MainActor
    func sliderRoundTripsToFinalFrame() async throws {
        let synthURL = try await SyntheticVideoFixture.writeMP4(frameCount: 4, fps: 24)
        defer { try? FileManager.default.removeItem(at: synthURL.deletingLastPathComponent()) }
        let engine = try StandaloneRenderEngine()
        let viewModel = EditorViewModel(renderEngine: engine)
        await viewModel.loadClip(at: synthURL)
        try #require(viewModel.phase.isReady)
        try #require(viewModel.totalFrames == 4)

        // Walk every position in [0, 1] in 1/3 steps (the natural
        // granularity of a 4-frame clip) and confirm we land on
        // the right frame.
        for (index, fraction) in [0.0, 1.0/3.0, 2.0/3.0, 1.0].enumerated() {
            viewModel.scrub(toNormalized: fraction)
            let landedFrame = Int((viewModel.playheadTime.seconds * 24).rounded())
            #expect(landedFrame == index,
                    "Slider \(fraction) should snap to frame \(index); landed on \(landedFrame).")
        }
    }

    /// The fps-indicator state on `EditorViewModel` defaults to
    /// zero outside of playback so the transport bar's badge is
    /// safely hidden. `targetPlaybackFPS` only populates once
    /// playback starts — a freshly-launched editor with no clip
    /// must not flash a stray "0 fps" badge.
    @Test("Playback fps state is zero before any clip loads")
    @MainActor
    func playbackFPSStartsZero() async throws {
        let engine = try StandaloneRenderEngine()
        let viewModel = EditorViewModel(renderEngine: engine)
        #expect(viewModel.measuredPlaybackFPS == 0)
        #expect(viewModel.targetPlaybackFPS == 0)
        #expect(viewModel.isPlaying == false)
    }

    @Test("preview backdrop pre-loads the bundled Sample image into the custom-image slot when available, otherwise defaults to checkerboard, and round-trips through every case")
    @MainActor
    func previewBackdropPreloadsBundledSampleAndRoundTrips() async throws {
        // Test isolation: the editor view model persists the saved
        // backdrop selection through the shared `UserDefaults`. When
        // the previous run left a non-`.customImage` selection, the
        // init's saved-selection branch wins regardless of whether
        // the bundled image loaded. Wipe the slate before this test
        // so the first-launch path is exercised cleanly.
        UserDefaults.standard.removeObject(forKey: BackdropPreferences.selectedKey)
        UserDefaults.standard.removeObject(forKey: BackdropPreferences.imageBookmarkKey)
        let engine = try StandaloneRenderEngine()
        let viewModel = EditorViewModel(renderEngine: engine)
        // Production launch: `Bundle.main` resolves to the wrapper
        // app, `Background.png` decodes into `customBackdropTexture`,
        // and the launch default lands on `.customImage` so the
        // user sees the keyer composited over the sample backdrop
        // immediately. Under XCTest / Swift Testing `Bundle.main`
        // is the test runner; the decode returns nil and the launch
        // default stays on the declared `.checkerboard`. Either is
        // correct — assert the pair stays consistent.
        if viewModel.customBackdropTexture != nil {
            #expect(viewModel.previewBackdrop == .customImage,
                    "Bundled Sample loaded into the custom-image slot — launch default should land on `.customImage` so users see a believable backdrop on first run.")
            #expect(viewModel.customBackdropImageName == EditorViewModel.bundledBackdropImageName,
                    "Pre-loaded starter should expose its friendly name in the popover.")
        } else {
            #expect(viewModel.previewBackdrop == .checkerboard,
                    "Bundled Sample unavailable — launch default should stay on `.checkerboard` so the user never lands on an unrenderable case.")
        }
        for backdrop in PreviewBackdrop.allCases {
            viewModel.previewBackdrop = backdrop
            #expect(viewModel.previewBackdrop == backdrop)
            #expect(!backdrop.displayName.isEmpty)
            #expect(!backdrop.systemImage.isEmpty)
        }
    }

    @Test("PreviewBackdrop covers the requested option set")
    func previewBackdropCoversRequiredOptions() {
        let names = Set(PreviewBackdrop.allCases.map(\.displayName))
        #expect(names.contains("Checkerboard"))
        #expect(names.contains("White"))
        #expect(names.contains("Black"))
        #expect(names.contains("Yellow"))
        #expect(names.contains("Red"))
    }

    @Test("HH:MM:SS:FF timecode formatter")
    func smpteTimecodeFormatter() {
        // Exercise the same helper the transport bar uses to render
        // the time label. Working at 24 fps so frame counts within a
        // second cap at 23 — a non-drop-frame setup matches the
        // timecode editors expect to see in standalone NLE tools.
        let formatter = TransportTimecodeFormatter(frameRate: 24)
        #expect(formatter.format(CMTime(seconds: 0.0, preferredTimescale: 24_000)) == "00:00:00:00")
        #expect(formatter.format(CMTime(seconds: 1.0 / 24, preferredTimescale: 24_000)) == "00:00:00:01")
        #expect(formatter.format(CMTime(seconds: 23.0 / 24, preferredTimescale: 24_000)) == "00:00:00:23")
        #expect(formatter.format(CMTime(seconds: 1.0, preferredTimescale: 24_000)) == "00:00:01:00")
        #expect(formatter.format(CMTime(seconds: 65.5, preferredTimescale: 24_000)) == "00:01:05:12")
        // Negative / invalid time values should clamp to zero so the
        // label never displays nonsense (e.g. negative frame numbers).
        #expect(formatter.format(.invalid) == "00:00:00:00")
        #expect(formatter.format(CMTime(seconds: -1, preferredTimescale: 24_000)) == "00:00:00:00")
    }
}
