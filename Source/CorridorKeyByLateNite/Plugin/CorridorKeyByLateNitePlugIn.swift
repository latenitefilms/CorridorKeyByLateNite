//
//  CorridorKeyToolboxPlugIn.swift
//  CorridorKey by LateNite
//
//  Main FxPlug entry point. Final Cut Pro instantiates this class through the
//  `ProPlugPlugInList` declaration in Info.plist and routes every tileable
//  effect call through it. Keeping the class thin and delegating work to
//  dedicated helpers keeps the integration layer easy to maintain.
//

import Foundation

@objc(CorridorKeyToolboxPlugIn)
final class CorridorKeyToolboxPlugIn: NSObject, FxTileableEffect, FxAnalyzer {

    // MARK: - Stored properties

    /// The FxPlug API manager the host hands us at construction. All runtime
    /// capabilities – parameter creation, retrieval, timing, colour gamut – are
    /// fetched through this manager on demand.
    let apiManager: any PROAPIAccessing

    /// Lightweight per-instance renderer; construction allocates no GPU or
    /// model resources. Immutable so inspector and analysis callbacks can
    /// safely share it from their first access.
    let renderPipeline = RenderPipeline()

    /// Rolling timing of the last rendered frame in milliseconds. Used only
    /// for internal performance tracing.
    let lastFrameMilliseconds = AtomicDouble(0)

    /// Last render backend used by the tile renderer. The inspector header
    /// reads this for the same Backend row the Standalone Editor exposes.
    let lastRenderReport = AtomicRenderReport()

    /// Per-instance analysis session. Holds the in-flight matte cache while a
    /// forward-analysis pass is running; dropped back to empty once cleanup
    /// has flushed the final result to the Library. Owned by the plug-in
    /// (rather than a separate registry) so it deallocates automatically when
    /// Final Cut Pro releases the instance — previously, a process-level
    /// registry leaked a full clip's worth of mattes per instance.
    let analysisSession = AnalysisSessionState()

    /// Decoded analysis metadata reused while capturing immutable render state.
    let analysisSnapshotStore = AnalysisSnapshotStore()

    /// Both custom rows observe one bridge; hosting views own its lifetime.
    @MainActor weak var inspectorBridge: CorridorKeyInspectorBridge?

    // MARK: - Init

    @objc required init?(apiManager: any PROAPIAccessing) {
        self.apiManager = apiManager
        super.init()
        PluginLog.notice("CorridorKeyToolboxPlugIn instantiated.")

        // FxPlug also creates instances for parameter discovery and cached
        // playback. Only an analysis frame is allowed to request the model.
    }

    deinit {
        PluginLog.notice("CorridorKeyToolboxPlugIn deallocated.")
    }
}

/// Minimal thread-safe wrapper used for publishing a single Double across
/// threads without reaching for a full lock-based class each time.
final class AtomicDouble: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double

    init(_ initial: Double) { self.value = initial }

    func set(_ newValue: Double) {
        lock.lock(); value = newValue; lock.unlock()
    }

    func read() -> Double {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

/// Thread-safe one-value store for the last render report published by the
/// render callback. Kept separate from `AtomicDouble` so the report remains a
/// value type and the FxPlug bridge can read it without touching Metal state.
final class AtomicRenderReport: @unchecked Sendable {
    private let lock = NSLock()
    private var value: RenderReport?

    /// Reports backend transitions only, avoiding per-frame disk logging.
    @discardableResult
    func set(_ newValue: RenderReport) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let changed = value?.backendDescription != newValue.backendDescription
            || value?.effectiveInferenceResolution != newValue.effectiveInferenceResolution
        value = newValue
        return changed
    }

    func read() -> RenderReport? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
