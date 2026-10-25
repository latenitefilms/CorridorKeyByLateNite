//
//  CorridorKeyToolboxPlugIn+FxAnalyzer.swift
//  CorridorKey by LateNite
//
//  Implements the `FxAnalyzer` protocol so the plug-in can run MLX inference
//  for every frame of the source clip before the user expects real-time
//  playback. Compact frame references persist in the Library custom parameter;
//  complete predictions live in the bounded local sandbox cache. Moving a
//  library to another Mac requires Analyse Clip again.
//

import Foundation
import CoreMedia
import Metal
import simd

/// Per-plug-in analysis state. Accessed from the render thread and from the
/// background analysis callbacks, so every touch of the mutable fields below
/// must take `lock`.
///
/// Held as a stored property on `CorridorKeyToolboxPlugIn` so its lifetime is
/// pinned to the plug-in instance. Holding the state in a process-level
/// registry (as an earlier version did) leaked one full clip's worth of
/// compressed mattes per plug-in instance because the registry never learned
/// when an instance was released.
final class AnalysisSessionState: @unchecked Sendable {
    let lock = NSLock()
    var frameDuration: CMTime = .invalid
    var firstFrameTime: CMTime = .invalid
    var frameCount: Int = 0
    var analyzedCount: Int = 0
    var screenColorRaw: Int = 0
    var qualityModeRaw: Int = 0
    var inferenceResolution: Int = 0
    var matteWidth: Int = 0
    var matteHeight: Int = 0
    var frameReferences: [Int: AnalysisFrameReference] = [:]
    var cacheSession: AnalysisDiskCache.Session?
    var videoSettings = VideoInferenceSettings()
    var videoSession: VideoInferenceSession?
    var hintReader: DeferredAlphaHintReader?

    /// Previous-frame buffers used by the Phase 1 temporal-stability blend.
    /// These are the last frame's *blended* alpha (so the EMA accumulates
    /// across the clip) and the raw RGBA source at the same resolution so
    /// the motion gate can see whether a pixel actually moved.
    ///
    /// Reset when the session resets or when the inference resolution
    /// changes (which drops previous-frame sizing and forces the blender
    /// to restart from the next "current" frame).
    var temporalHistory = TemporalBlender.History()

    /// Cached temporal-blend configuration captured at setup time. Reading
    /// parameter values per frame would require a retrieval API round-trip
    /// on the analysis thread, so we snapshot at the start of the pass.
    var temporalStabilityEnabled: Bool = false
    var temporalStabilityStrength: Double = 0.5

    /// Cached hint configuration captured at setup time so the per-frame
    /// analyse path runs with the user's actual settings, not a default-
    /// constructed `PluginStateData`. Earlier builds dropped these onto
    /// the floor — the analyser always ran with `hintMode = .appleVision`
    /// and an empty hint set, which made the cached matte diverge from
    /// the Standalone Editor's output the moment the user picked a
    /// different mode or placed any subject hints.
    var hintModeRaw: Int = PluginStateData().hintMode.rawValue
    var hintPointSet: HintPointSet = HintPointSet()

    /// Snapshot for lock-free packing into an `AnalysisData` value. Callers are
    /// expected to already hold the lock; the copy isolates the dictionary so
    /// downstream serialisation can happen outside the critical section.
    func snapshotLocked() -> AnalysisData {
        AnalysisData(
            schemaVersion: AnalysisData.currentSchemaVersion,
            frameDuration: frameDuration,
            firstFrameTime: firstFrameTime,
            frameCount: frameCount,
            analyzedCount: analyzedCount,
            screenColorRaw: screenColorRaw,
            qualityModeRaw: qualityModeRaw,
            inferenceResolution: inferenceResolution,
            matteWidth: matteWidth,
            matteHeight: matteHeight,
            mattes: [:],
            hintConfiguration: AnalysisHintConfiguration(
                mode: HintMode(rawValue: hintModeRaw) ?? PluginStateData().hintMode, points: hintPointSet,
                video: videoSettings.analysisIdentity, temporalStabilityEnabled: temporalStabilityEnabled,
                temporalStabilityStrength: temporalStabilityEnabled ? temporalStabilityStrength : 0
            ),
            frameReferences: frameReferences
        )
    }

    func resetLocked() {
        frameDuration = .invalid
        firstFrameTime = .invalid
        frameCount = 0
        analyzedCount = 0
        screenColorRaw = 0
        qualityModeRaw = 0
        inferenceResolution = 0
        matteWidth = 0
        matteHeight = 0
        frameReferences.removeAll(keepingCapacity: false)
        cacheSession = nil
        videoSession = nil
        hintReader = nil
        videoSettings = VideoInferenceSettings()
        temporalHistory = TemporalBlender.History()
        temporalStabilityEnabled = false
        temporalStabilityStrength = 0.5
        hintModeRaw = PluginStateData().hintMode.rawValue
        hintPointSet = HintPointSet()
    }
}

/// Last known persisted analysis snapshot for this plug-in instance.
///
/// Final Cut Pro may render with an older encoded `pluginState` immediately
/// after a seek or custom-parameter write. Keeping the same-process snapshot
/// lets the render callback recover the current frame's matte while the host
/// propagates the published header-storage parameter.
final class AnalysisSnapshotStore: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: AnalysisData?

    func store(_ snapshot: AnalysisData) {
        lock.lock()
        self.snapshot = snapshot
        lock.unlock()
    }

    func clear() {
        lock.lock()
        snapshot = nil
        lock.unlock()
    }

    func currentSnapshot() -> AnalysisData? {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    func cachedMatte(
        at renderTime: CMTime,
        screenColorRaw: Int,
        hintConfiguration: AnalysisHintConfiguration
    ) -> CachedAnalysisMatte? {
        currentSnapshot()?.cachedMatte(
            at: renderTime,
            screenColorRaw: screenColorRaw,
            hintConfiguration: hintConfiguration
        )
    }
}

extension CorridorKeyToolboxPlugIn {

    // MARK: - Inspector wiring (called by the +Parameters extension)

    func startForwardAnalysisPass() {
        guard let actionAPI = apiManager.api(for: (any FxCustomParameterActionAPI_v4).self) as? any FxCustomParameterActionAPI_v4 else {
            PluginLog.error("Analyse Clip: FxCustomParameterActionAPI_v4 is unavailable.")
            return
        }
        // FxPlug only vends the analysis / parameter APIs inside an action
        // bracket when the call comes from a custom UI view. Without this
        // wrapping, `apiManager.api(for:)` returns nil for both the analysis
        // and parameter-setting APIs, which is exactly what "Analyse Clip is
        // unavailable" in the logs was catching.
        actionAPI.startAction(self)
        defer { actionAPI.endAction(self) }

        guard let analysisAPI = apiManager.api(for: (any FxAnalysisAPI_v2).self) as? any FxAnalysisAPI_v2 else {
            PluginLog.error("Analyse Clip: FxAnalysisAPI_v2 is unavailable.")
            return
        }
        let state = analysisAPI.analysisStateForEffect()
        if state == kFxAnalysisState_AnalysisRequested || state == kFxAnalysisState_AnalysisStarted {
            PluginLog.notice("Analyse Clip: analysis already in progress; ignoring duplicate click.")
            return
        }
        do {
            try analysisAPI.startForwardAnalysis(kFxAnalysisLocation_GPU)
            PluginLog.notice("Analyse Clip: forward analysis requested.")
        } catch {
            PluginLog.error("Analyse Clip: failed to start forward analysis: \(error.localizedDescription)")
        }
    }

    func clearAnalysisCache() {
        let session = analysisSession
        session.lock.lock()
        session.resetLocked()
        session.lock.unlock()
        analysisSnapshotStore.clear()

        guard let actionAPI = apiManager.api(for: (any FxCustomParameterActionAPI_v4).self) as? any FxCustomParameterActionAPI_v4 else {
            PluginLog.error("Reset Analysis: FxCustomParameterActionAPI_v4 is unavailable.")
            return
        }
        actionAPI.startAction(self)
        defer { actionAPI.endAction(self) }

        if !HeaderCustomParameterStorage.setDictionary(
            NSDictionary(),
            for: HeaderStorageKey.analysisData,
            using: apiManager
        ) {
            PluginLog.error("Reset Analysis: header custom parameter write failed.")
        }
        PluginLog.notice("Analysis cache cleared.")
    }

    // MARK: - FxAnalyzer conformance

    @objc(desiredAnalysisTimeRange:forInputWithTimeRange:error:)
    func desiredAnalysisTimeRange(
        _ desiredRange: UnsafeMutablePointer<CMTimeRange>,
        forInputWithTimeRange inputTimeRange: CMTimeRange
    ) throws {
        desiredRange.pointee = inputTimeRange
        PluginLog.notice(
            "Analyse: desired time range = \(CMTimeGetSeconds(inputTimeRange.duration))s."
        )
    }

    @objc(setupAnalysisForTimeRange:frameDuration:error:)
    func setupAnalysis(
        for analysisRange: CMTimeRange,
        frameDuration: CMTime
    ) throws {
        guard let retrieval = apiManager.api(for: (any FxParameterRetrievalAPI_v6).self) as? any FxParameterRetrievalAPI_v6 else {
            throw NSError(
                domain: FxPlugErrorDomain,
                code: kFxError_APIUnavailable,
                userInfo: [NSLocalizedDescriptionKey: "Could not access parameter retrieval API during analysis setup."]
            )
        }

        let screenColor: ScreenColor = {
            var raw: Int32 = 0
            guard retrieval.getIntValue(&raw, fromParameter: ParameterIdentifier.screenColor, at: analysisRange.start) else {
                return .green
            }
            return ScreenColor(rawValue: Int(raw)) ?? .green
        }()
        let qualityMode: QualityMode = {
            var raw: Int32 = 0
            guard retrieval.getIntValue(&raw, fromParameter: ParameterIdentifier.qualityMode, at: analysisRange.start) else {
                return .automatic
            }
            return QualityMode(rawValue: Int(raw)) ?? .automatic
        }()

        // We don't know the clip's intrinsic resolution at setup time, so use
        // the baseline long edge to pick an inference rung. Automatic settles
        // for 1024px which is the practical sweet spot between storage cost
        // and edge fidelity; the user can still pick Ultra/Maximum manually.
        let longEdge = Int(1920)
        // Setup uses the system default device's recorded capability so
        // the analyse pass picks the same rung the render path will
        // pick. Hosts that route to a different device per frame fall
        // through to the static ceiling.
        let setupDeviceID = MTLCreateSystemDefaultDevice()?.registryID
        let inferenceResolution: Int
        if let setupDeviceID {
            inferenceResolution = qualityMode.resolvedInferenceResolution(
                forLongEdge: longEdge,
                deviceRegistryID: setupDeviceID
            )
        } else {
            inferenceResolution = qualityMode.resolvedInferenceResolution(forLongEdge: longEdge)
        }

        // Temporal stability settings are also snapshotted at setup so the
        // per-frame analyser doesn't hit the parameter retrieval API from a
        // background thread. These read with safe defaults if the project
        // predates the parameter.
        let temporalEnabled: Bool = {
            var raw = ObjCBool(false)
            retrieval.getBoolValue(&raw, fromParameter: ParameterIdentifier.temporalStabilityEnabled, at: analysisRange.start)
            return raw.boolValue
        }()
        let temporalStrength: Double = {
            var value: Double = 0.5
            retrieval.getFloatValue(&value, fromParameter: ParameterIdentifier.temporalStabilityStrength, at: analysisRange.start)
            return value
        }()

        // Snapshot hint configuration too. The per-frame analyser
        // needs these to match what the Standalone Editor would
        // produce for the same source — without this the FxPlug
        // analyse always ran with `.appleVision` + empty hints and
        // ignored whatever the user picked in the inspector / OSC.
        let hintModeValue: HintMode = {
            var raw: Int32 = Int32(PluginStateData().hintMode.rawValue)
            retrieval.getIntValue(&raw, fromParameter: ParameterIdentifier.hintMode, at: analysisRange.start)
            return HintMode(rawValue: Int(raw)) ?? PluginStateData().hintMode
        }()
        let hintPoints = loadHintPointSet(using: retrieval)

        let frameCount = Self.frameCount(in: analysisRange, frameDuration: frameDuration)
        let videoConfiguration = videoSettings(using: retrieval, at: analysisRange.start)
        try videoConfiguration.validate(frameCount: frameCount)
        let hintReader = videoConfiguration.useAlphaHint
            ? DeferredAlphaHintReader(settings: videoConfiguration, frameCount: frameCount, frameDuration: frameDuration) : nil
        let session = analysisSession
        let cacheSession = try AnalysisDiskCache.shared.beginSession()
        session.lock.lock()
        session.resetLocked()
        session.cacheSession = cacheSession
        session.videoSettings = videoConfiguration
        session.hintReader = hintReader
        session.frameDuration = frameDuration
        session.firstFrameTime = analysisRange.start
        session.frameCount = frameCount
        session.screenColorRaw = screenColor.rawValue
        session.qualityModeRaw = qualityMode.rawValue
        session.inferenceResolution = inferenceResolution
        session.matteWidth = inferenceResolution
        session.matteHeight = inferenceResolution
        session.temporalStabilityEnabled = temporalEnabled
        session.temporalStabilityStrength = temporalStrength
        session.hintModeRaw = hintModeValue.rawValue
        session.hintPointSet = hintPoints
        session.lock.unlock()
        analysisSnapshotStore.clear()

        PluginLog.notice(
            "Analyse setup: \(frameCount) frame(s) at \(inferenceResolution)px, screen=\(screenColor.displayName), hint=\(hintModeValue.displayName), userHints=\(hintPoints.points.count)."
        )
    }

    @objc(analyzeFrame:atTime:error:)
    func analyzeFrame(
        _ frame: FxImageTile,
        atTime frameTime: CMTime
    ) throws {
        let session = analysisSession

        session.lock.lock()
        let frameDuration = session.frameDuration
        let firstFrameTime = session.firstFrameTime
        let frameCount = session.frameCount
        let screenColorRaw = session.screenColorRaw
        let temporalEnabled = session.temporalStabilityEnabled
        let temporalStrength = session.temporalStabilityStrength
        let hintModeRaw = session.hintModeRaw
        let hintPointSet = session.hintPointSet
        let videoConfiguration = session.videoSettings
        let deferredHint = session.hintReader
        let existingVideoSession = session.videoSession
        let qualityModeRaw = session.qualityModeRaw
        let cacheSession = session.cacheSession
        var temporalHistory = session.temporalHistory
        session.lock.unlock()

        guard frameCount > 0, let cacheSession else {
            throw NSError(
                domain: FxPlugErrorDomain,
                code: kFxError_AnalysisError,
                userInfo: [NSLocalizedDescriptionKey: "Analysis was not initialised before analyzeFrame was called."]
            )
        }
        guard let frameIndex = Self.frameIndex(
            for: frameTime,
            firstFrameTime: firstFrameTime,
            frameDuration: frameDuration,
            frameCount: frameCount
        ) else {
            PluginLog.notice("Analyse: skipping out-of-range frame at \(CMTimeGetSeconds(frameTime))s.")
            return
        }

        // Log entry-into-a-frame as well as the finish line. If the renderer
        // hangs inside `extractAlphaMatteForAnalysis` (MLX stall, GPU hang,
        // deadlock, etc.) the "started" line lands in the log but the
        // matching "cached" line never does — pinpointing the hang.
        PluginLog.notice("Analyse frame \(frameIndex + 1)/\(frameCount) started.")

        let deviceCache = MetalDeviceCache.shared
        guard let device = deviceCache.device(forRegistryID: frame.deviceRegistryID) else {
            throw NSError(
                domain: FxPlugErrorDomain,
                code: kFxError_AnalysisError,
                userInfo: [NSLocalizedDescriptionKey: "Analyse: unknown GPU with registry id \(frame.deviceRegistryID)."]
            )
        }
        let entry = try deviceCache.entry(for: device)
        guard let commandQueue = entry.borrowCommandQueue() else {
            throw NSError(
                domain: FxPlugErrorDomain,
                code: kFxError_AnalysisError,
                userInfo: [NSLocalizedDescriptionKey: "Analyse: no Metal command queue is available."]
            )
        }
        defer { entry.returnCommandQueue(commandQueue) }

        guard let sourceTexture = frame.metalTexture(for: device) else {
            throw NSError(
                domain: FxPlugErrorDomain,
                code: kFxError_AnalysisError,
                userInfo: [NSLocalizedDescriptionKey: "Analyse: analysis frame had no Metal texture."]
            )
        }

        if frameIndex == 0 {
            PluginLog.notice("Analyse input: imageOrigin=\(frame.imageOrigin), canonical cache rows=top-to-bottom.")
        }

        // Build the analyse-state with the snapshotted user values. The
        // hint mode + hint points are critical here: skipping them would
        // make the cached matte differ from the Standalone Editor's
        // output for the same source. Other parameters (despill, light
        // wrap, etc.) only kick in at *render* time when the cached
        // matte is being composited, so they don't need to thread
        // through the analyse path.
        var analyseState = PluginStateData(
            screenColor: ScreenColor(rawValue: screenColorRaw) ?? .green,
            qualityMode: QualityMode(rawValue: qualityModeRaw) ?? .automatic,
            hintMode: HintMode(rawValue: hintModeRaw) ?? PluginStateData().hintMode,
            hintPointSet: hintPointSet
        )
        analyseState.video = videoConfiguration

        let workingGamut: WorkingColorGamut
        if let gamutAPI = apiManager.api(for: (any FxColorGamutAPI_v2).self) as? any FxColorGamutAPI_v2 {
            workingGamut = ColorGamutMatrix.gamut(fromColorPrimariesRaw: UInt(gamutAPI.colorPrimaries()))
        } else {
            workingGamut = .rec709
        }

        let videoSession: VideoInferenceSession
        if let existingVideoSession {
            videoSession = existingVideoSession
        } else {
            videoSession = try renderPipeline.makeVideoInferenceSession(
                sourceWidth: sourceTexture.width, sourceHeight: sourceTexture.height,
                state: analyseState, frameCount: frameCount, entry: entry,
                readbackSource: temporalEnabled && temporalStrength > 0)
            session.lock.withLock { session.videoSession = videoSession }
        }
        let hintReader = try deferredHint?.waitForReader()
        let hintTexture = try hintReader?.texture(frameIndex: frameIndex, sourceWidth: sourceTexture.width,
                                                 sourceHeight: sourceTexture.height, device: device, commandQueue: commandQueue)
        try renderPipeline.appendVideoFrame(sourceTexture: sourceTexture, hintTexture: hintTexture,
                                             state: analyseState, workingGamut: workingGamut, renderTime: frameTime,
                                             frameIndex: frameIndex, session: videoSession, entry: entry,
                                             commandQueue: commandQueue, sourceRowOrder: ImageRowOrder(imageOrigin: frame.imageOrigin))
        func storeFrame(_ result: VideoInferenceFrame) throws {
            var alpha = result.alpha
            temporalHistory.apply(alpha: &alpha, source: result.source,
                                  width: result.geometry.contentWidth, height: result.geometry.contentHeight,
                                  frameIndex: result.index,
                                  configuration: TemporalBlender.Configuration(strength: temporalEnabled ? Float(temporalStrength) : 0,
                                                                               motionThreshold: 0.05))
            let blob = try AnalysisFrameCodec.encode(alpha: alpha, foregroundHalfRGBA: result.foregroundHalfRGBA,
                                                     width: result.geometry.contentWidth, height: result.geometry.contentHeight)
            let reference = try AnalysisDiskCache.shared.store(blob, in: cacheSession)
            let snapshot: AnalysisData? = session.lock.withLock {
                session.inferenceResolution = result.geometry.resolution
                session.matteWidth = result.geometry.contentWidth
                session.matteHeight = result.geometry.contentHeight
                session.frameReferences[result.index] = reference
                session.analyzedCount = session.frameReferences.count
                session.temporalHistory = temporalHistory
                return session.analyzedCount % 10 == 0 || session.analyzedCount == frameCount ? session.snapshotLocked() : nil
            }
            if let snapshot { persist(snapshot: snapshot) }
            PluginLog.notice("Refined source frame \(result.index + 1)/\(frameCount); Time Awareness: \(videoConfiguration.timeAwareness.displayName).")
        }
        if videoConfiguration.timeAwareness == .off {
            try videoSession.finishPreparedFrame(onFrame: storeFrame)
        } else {
            PluginLog.notice("Prepared frame \(frameIndex + 1)/\(frameCount) for v2 Time Awareness.")
        }
        guard frameIndex == frameCount - 1 else { return }
        try videoSession.finish(checkCancellation: {
            try Task.checkCancellation()
            if let api = self.apiManager.api(for: (any FxAnalysisAPI_v2).self) as? any FxAnalysisAPI_v2,
               api.analysisStateForEffect() == kFxAnalysisState_AnalysisInterrupted { throw CancellationError() }
        }, onFrame: storeFrame)
    }

    @objc(cleanupAnalysis:)
    func cleanupAnalysis() throws {
        let session = analysisSession
        session.lock.lock()
        let snapshot = session.snapshotLocked()
        session.lock.unlock()
        persist(snapshot: snapshot)
        // Fully reset the session so the inspector header's
        // `liveAnalysisProgress()` returns nil — clearing the in-flight
        // progress bar in our custom UI even when Final Cut Pro itself
        // cancelled the pass via its global progress bar (in which case
        // the user never touched our Cancel button). The persisted
        // frame references live in the Library, and pixels remain on disk.
        // This releases session state and its active-pass eviction lease.
        session.lock.lock()
        session.resetLocked()
        session.lock.unlock()
        // Release the Metal side of the readback cache on every device the
        // session touched. The analyser might run against a different GPU
        // next session, so we drop everything and re-warm lazily.
        for device in MTLCopyAllDevices() {
            if let entry = try? MetalDeviceCache.shared.entry(for: device) {
                entry.clearAnalysisReadbackTextures()
                entry.releaseVisionHintEngine()
            }
        }
        // Drop MLX's per-process buffer cache. During an analysis pass
        // MLX caches every intermediate (model activations, transient
        // tensors) for re-use; without this hook it would persist
        // multiple GB of buffers between editing sessions. Clearing
        // here gives us bounded steady-state memory while leaving the
        // hot path inside an analysis pass completely untouched.
        renderPipeline.inferenceCoordinator.releaseCacheBetweenSessions()
        PluginLog.notice(
            "Analyse: cleanup — \(snapshot.analyzedCount) of \(snapshot.frameCount) frame(s) persisted."
        )
    }

    // MARK: - Live progress for the inspector header

    /// Lightweight view into the in-memory session state used by the
    /// inspector bridge while analysis is running. Reading the persisted
    /// `AnalysisData` would only catch up every 10 frames (and wouldn't
    /// surface the chosen inference resolution until the first flush), which
    /// left the header stuck at "Analysing at 0px…" for long clips.
    func liveAnalysisProgress() -> (analysed: Int, total: Int, resolution: Int)? {
        let session = analysisSession
        session.lock.lock()
        defer { session.lock.unlock() }
        guard session.frameCount > 0 else { return nil }
        return (session.analyzedCount, session.frameCount, session.inferenceResolution)
    }

    // MARK: - Persistence + lookup helpers

    /// Writes the current frame-reference metadata into the published header custom
    /// parameter so Final Cut Pro's Motion Template wrapper persists it on
    /// the same channel as the inspector header.
    private func persist(snapshot: AnalysisData) {
        analysisSnapshotStore.store(snapshot)

        if HeaderCustomParameterStorage.setDictionary(
            snapshot.asParameterDictionary(),
            for: HeaderStorageKey.analysisData,
            using: apiManager
        ) {
            return
        }

        PluginLog.error("Persist analysis: header custom parameter write failed.")
    }

    /// Loads persisted metadata so `pluginState` can attach the current frame's
    /// local cache reference without moving complete image payloads through IPC.
    func loadAnalysisData(using retrieval: any FxParameterRetrievalAPI_v6) -> AnalysisData? {
        let headerDictionary = HeaderCustomParameterStorage.dictionaryValue(
            for: HeaderStorageKey.analysisData,
            using: retrieval
        )
        if let analysis = AnalysisData.fromParameterDictionary(headerDictionary) {
            analysisSnapshotStore.store(analysis)
            return analysis
        }

        return analysisSnapshotStore.currentSnapshot()
    }

    // MARK: - Frame index math

    static func frameCount(in range: CMTimeRange, frameDuration: CMTime) -> Int {
        let durationSeconds = CMTimeGetSeconds(frameDuration)
        guard durationSeconds > 0 else { return 0 }
        let totalSeconds = CMTimeGetSeconds(range.duration)
        let count = Int((totalSeconds / durationSeconds).rounded(.up))
        return max(0, count)
    }

    static func frameIndex(
        for renderTime: CMTime,
        firstFrameTime: CMTime,
        frameDuration: CMTime,
        frameCount: Int
    ) -> Int? {
        let durationSeconds = CMTimeGetSeconds(frameDuration)
        guard durationSeconds > 0 else { return nil }
        let delta = CMTimeGetSeconds(CMTimeSubtract(renderTime, firstFrameTime))
        let index = Int((delta / durationSeconds).rounded())
        guard index >= 0, index < frameCount else { return nil }
        return index
    }
}
