//
//  AnalysisRunner.swift
//  CorridorKey by LateNite — Standalone Editor
//
//  Mirrors `CorridorKeyToolboxPlugIn+FxAnalyzer` for the standalone
//  editor: prepares every frame through the shared v2 video session,
//  refines its overlapping temporal windows, and stores complete frames
//  on disk with small in-memory references keyed by frame index. The render
//  preview then short-circuits MLX by feeding cached mattes into
//  `RenderPipeline.renderToTexture` exactly the way the FxPlug renders
//  cached frames inside Final Cut Pro.
//
//  Runs as a Swift `Task` driven by `EditorViewModel`. Yields
//  cooperative cancellation between frames so the user can stop the
//  pass at any time. Reports progress via an `AsyncStream` so the
//  inspector progress UI stays current without polling.
//

import Foundation
import CoreMedia
import CoreVideo

#if CORRIDOR_KEY_HEADLESS_TESTS
@testable import CorridorKeyToolboxLogic
@testable import CorridorKeyToolboxMetalStages
#endif

/// Per-frame storage built up during the analysis pass. Exposed via
/// `EditorProject.matteCache` so previews can reach in for a cached
/// matte by frame index instead of triggering MLX on every scrub.
struct MatteCacheEntry: Sendable {
    let inlineBlob: Data?
    let reference: AnalysisFrameReference?
    let width: Int
    let height: Int
    let inferenceResolution: Int

    /// Inline construction is retained for small fixtures and immediate single-frame callers.
    init(blob: Data, width: Int, height: Int, inferenceResolution: Int) {
        self.inlineBlob = blob
        self.reference = nil
        self.width = width
        self.height = height
        self.inferenceResolution = inferenceResolution
    }

    /// Production analyses retain only this small file descriptor per frame.
    init(reference: AnalysisFrameReference, width: Int, height: Int, inferenceResolution: Int) {
        self.inlineBlob = nil
        self.reference = reference
        self.width = width
        self.height = height
        self.inferenceResolution = inferenceResolution
    }

    /// Explicit readback for diagnostics/tests; rendering resolves references on its worker.
    var blob: Data {
        get throws {
            if let reference { return try AnalysisDiskCache.shared.load(reference) }
            guard let inlineBlob else { throw AnalysisDiskCacheError.missingFrame }
            return inlineBlob
        }
    }
}

/// Status events the runner pushes during a pass. Drives the
/// progress bar and the success / failure alerts in the editor.
enum AnalysisRunnerEvent: @unchecked Sendable {
    /// Total frame count became known (or changed).
    case totalFramesResolved(Int)
    /// Frozen features are ready; temporal inference and refinement follow.
    case framePrepared(frameIndex: Int)
    /// One frame was processed. Indices are zero-based and may arrive backwards
    /// when propagating a single reference hint. `engineDescription` identifies
    /// the model backend; analysis never substitutes a rough-matte fallback.
    case frameProcessed(frameIndex: Int, engineDescription: String, entry: MatteCacheEntry)
    /// Pass finished without error. Includes the total elapsed seconds.
    case completed(elapsedSeconds: Double)
    /// Pass aborted with an error.
    case failed(String)
    /// User cancelled the pass.
    case cancelled
}

actor AnalysisRunner {

    private let renderEngine: StandaloneRenderEngine
    private let videoSource: any EditorMediaSource

    init(renderEngine: StandaloneRenderEngine, videoSource: any EditorMediaSource) {
        self.renderEngine = renderEngine
        self.videoSource = videoSource
    }

    /// Runs the analysis pass to completion or until the wrapping task
    /// is cancelled. Each frame's matte blob is delivered through
    /// `eventHandler` so the editor can store it directly in its
    /// `EditorProject` cache without the runner needing to know about
    /// the project type.
    func run(
        state: PluginStateData,
        eventHandler: @Sendable (AnalysisRunnerEvent) -> Void
    ) async {
        defer { renderEngine.releaseAnalysisCache() }
        let startedAt = Date()
        let info = videoSource.info
        let frameCount = videoSource.totalFrameCount()
        let frameRate = max(Double(info.nominalFrameRate), 0.001)
        let timescale = info.timescale
        eventHandler(.totalFramesResolved(frameCount))

        // Build the AVAssetReader once for the whole pass — far faster
        // than reseeking per frame via AVAssetImageGenerator.
        let frameReader: any MediaFrameReader
        do {
            frameReader = try await videoSource.makeFrameReader(startTime: .zero)
        } catch {
            eventHandler(.failed(String(describing: error)))
            return
        }
        defer { frameReader.cancel() }

        var frameIndex = 0
        let cacheSession: AnalysisDiskCache.Session
        do {
            cacheSession = try AnalysisDiskCache.shared.beginSession()
        } catch {
            eventHandler(.failed(error.localizedDescription))
            return
        }
        defer { withExtendedLifetime(cacheSession) {} }
        let videoSession: VideoInferenceSession
        let hintReader: AlphaHintReader?
        do {
            try state.video.validate(frameCount: frameCount)
            hintReader = state.video.useAlphaHint
                ? try await AlphaHintReader(settings: state.video, frameCount: frameCount,
                                            frameDuration: CMTime(seconds: 1 / frameRate, preferredTimescale: timescale)) : nil
            videoSession = try renderEngine.makeVideoSession(state: state, frameCount: frameCount, sourceSize: info.renderSize)
        } catch {
            eventHandler(.failed(error.localizedDescription))
            return
        }
        var temporalHistory = TemporalBlender.History()
        let temporalConfiguration = TemporalBlender.Configuration(
            strength: state.temporalStabilityEnabled ? Float(state.temporalStabilityStrength) : 0,
            motionThreshold: 0.05
        )
        while !Task.isCancelled {
            let frame: ReaderFrame?
            do {
                frame = try frameReader.nextFrame()
            } catch {
                eventHandler(.failed(String(describing: error)))
                return
            }
            guard let frame else { break }

            let renderTime: CMTime
            if frame.presentationTime.isValid && frame.presentationTime.isNumeric {
                renderTime = frame.presentationTime
            } else {
                renderTime = CMTime(
                    seconds: Double(frameIndex) / frameRate,
                    preferredTimescale: timescale
                )
            }

            do {
                try renderEngine.appendVideoFrame(source: frame.pixelBuffer, state: state, renderTime: renderTime,
                                                   frameIndex: frameIndex, session: videoSession, hintReader: hintReader)
                eventHandler(.framePrepared(frameIndex: frameIndex))
            } catch {
                eventHandler(.failed(error.localizedDescription))
                return
            }
            frameIndex += 1
            // Yield cooperative cancellation between frames; otherwise
            // a tight inference loop blocks Task.checkCancellation.
            await Task.yield()
        }

        if Task.isCancelled {
            eventHandler(.cancelled)
            return
        }
        do {
            try videoSession.finish { frame in
                var alpha = frame.alpha
                temporalHistory.apply(alpha: &alpha, source: frame.source,
                                      width: frame.geometry.contentWidth, height: frame.geometry.contentHeight,
                                      frameIndex: frame.index, configuration: temporalConfiguration)
                let blob = try AnalysisFrameCodec.encode(alpha: alpha, foregroundHalfRGBA: frame.foregroundHalfRGBA,
                                                         width: frame.geometry.contentWidth, height: frame.geometry.contentHeight)
                let reference = try AnalysisDiskCache.shared.store(blob, in: cacheSession)
                let entry = MatteCacheEntry(reference: reference, width: frame.geometry.contentWidth,
                                            height: frame.geometry.contentHeight, inferenceResolution: frame.geometry.resolution)
                eventHandler(.frameProcessed(frameIndex: frame.index, engineDescription: "CorridorKey v2 · MLX", entry: entry))
            }
        } catch is CancellationError {
            eventHandler(.cancelled)
            return
        } catch {
            eventHandler(.failed(error.localizedDescription))
            return
        }
        let elapsed = Date().timeIntervalSince(startedAt)
        eventHandler(.completed(elapsedSeconds: elapsed))
    }
}
