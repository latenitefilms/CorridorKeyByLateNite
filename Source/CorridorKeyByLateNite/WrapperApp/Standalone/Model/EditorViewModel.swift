//
//  EditorViewModel.swift
//  CorridorKey by LateNite — Standalone Editor
//
//  Single source of truth for the editor window. Holds:
//
//  * The currently-loaded `VideoSource` (or nil if no clip has been
//    imported).
//  * The live `PluginStateData` parameters bound to the inspector.
//  * The matte cache populated by the analysis pass.
//  * The current preview frame and any in-flight render task.
//  * Transport state (playhead, playing / paused).
//  * Analysis and export progress.
//
//  All UI bindings flow through `@Observable` properties so SwiftUI
//  invalidates only the panes whose data actually changed.
//

import Foundation
import Observation
import Metal
import CoreMedia
import AVFoundation
import Combine
import SwiftUI

/// Coarse states the editor can be in. Drives empty-state vs editor
/// chrome and which actions are enabled.
enum EditorPhase: @unchecked Sendable, Equatable {
    case noClipLoaded
    case loadingClip(URL)
    case ready
    case loadFailed(String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

/// Status of the analyse-clip pass. Drives the inspector progress UI.
enum EditorAnalysisStatus: @unchecked Sendable, Equatable {
    case idle
    case running(processed: Int, total: Int)
    case completed(elapsedSeconds: Double, totalFrames: Int)
    case failed(String)
    case cancelled

    var inProgress: Bool {
        if case .running = self { return true }
        return false
    }
}

/// Status of the export pass. Drives the export-sheet progress UI.
enum EditorExportStatus: @unchecked Sendable, Equatable {
    case idle
    case running(processed: Int, total: Int)
    case completed(URL)
    case failed(String)
    case cancelled

    var inProgress: Bool {
        if case .running = self { return true }
        return false
    }
}

/// Backdrop the preview surface composites the keyed image over.
/// `.customImage` is the launch default: the editor pre-loads the
/// bundled `Background.png` (a Castle Gate sample) into the
/// custom-image slot on first launch so a freshly-launched session
/// previews the keyer over a believable backdrop instead of a flat
/// checkerboard. The remaining cases cover the transparency-aware
/// checkerboard, four solid reference colours, and a user-picked
/// solid colour. `.customColor` and `.customImage` pair with
/// `EditorViewModel.customBackdropColor` and `customBackdropTexture`
/// respectively; the enum identity is what the Picker selects on,
/// while the supporting data lives on the view model so the inline
/// radio rows still get a stable tag.
enum PreviewBackdrop: Hashable, Sendable, CaseIterable, Identifiable {
    case checkerboard
    case white
    case black
    case yellow
    case red
    case customColor
    case customImage

    var id: Self { self }

    var displayName: String {
        switch self {
        case .checkerboard: return "Checkerboard"
        case .white: return "White"
        case .black: return "Black"
        case .yellow: return "Yellow"
        case .red: return "Red"
        case .customColor: return "Custom Colour…"
        case .customImage: return "Custom Image…"
        }
    }

    var systemImage: String {
        switch self {
        case .checkerboard: return "checkerboard.rectangle"
        case .white: return "rectangle.fill"
        case .black: return "rectangle.fill"
        case .yellow: return "rectangle.fill"
        case .red: return "rectangle.fill"
        case .customColor: return "paintpalette"
        case .customImage: return "photo"
        }
    }

    /// Concrete swatch RGB used when the picker shows a coloured chip
    /// for this case. `nil` means "draw the SF Symbol instead" — the
    /// checkerboard, custom colour, and custom image cases all use
    /// `systemImage` rendering because they don't represent a single
    /// fixed colour. Stored as `BackdropColor` (linear RGB triplet)
    /// so it's both Sendable and the SwiftUI `Color` round-trip is
    /// shared with the custom-colour swatch.
    var swatchColor: BackdropColor? {
        switch self {
        case .white: return BackdropColor(red: 1.0, green: 1.0, blue: 1.0)
        case .black: return BackdropColor(red: 0.0, green: 0.0, blue: 0.0)
        case .yellow: return BackdropColor(red: 1.0, green: 0.92, blue: 0.0)
        case .red: return BackdropColor(red: 1.0, green: 0.20, blue: 0.20)
        default: return nil
        }
    }

    /// Stable string identifier used by `BackdropPreferences` so older
    /// saves stay valid when a future build inserts or reorders cases.
    /// Reordering the `enum` declaration would otherwise silently shift
    /// every saved selection (a user who picked Yellow would be
    /// promoted to Red on the next launch); a string lookup avoids
    /// that class of bug entirely.
    var persistenceIdentifier: String {
        switch self {
        case .checkerboard: return "checkerboard"
        case .white: return "white"
        case .black: return "black"
        case .yellow: return "yellow"
        case .red: return "red"
        case .customColor: return "customColor"
        case .customImage: return "customImage"
        }
    }

    init?(persistenceIdentifier: String) {
        switch persistenceIdentifier {
        case "checkerboard": self = .checkerboard
        case "white": self = .white
        case "black": self = .black
        case "yellow": self = .yellow
        case "red": self = .red
        case "customColor": self = .customColor
        case "customImage": self = .customImage
        default: return nil
        }
    }
}

/// Linear RGB triplet a custom backdrop is rendered with. Stored on
/// the view model and persisted via UserDefaults so the user's last
/// pick survives a launch. Lives as a value type rather than
/// SwiftUI's `Color` so it's `Codable` and `Sendable` without
/// pulling in environment lookups.
struct BackdropColor: Hashable, Sendable, Codable {
    var red: Double
    var green: Double
    var blue: Double

    /// Neutral mid-grey default — readable on top of most clip
    /// looks without biasing the user's eye toward any hue.
    static let `default` = BackdropColor(red: 0.18, green: 0.18, blue: 0.18)
}

/// Modes the on-screen control overlay can be in. The user picks one
/// from the inspector; clicking the preview surface in any mode other
/// than `.disabled` adds or removes a hint point.
enum OnScreenControlTool: Hashable, Sendable, CaseIterable, Identifiable {
    case disabled
    case foregroundHint
    case backgroundHint
    case ignoreHint
    case eraseHint

    var id: Self { self }

    var displayName: String {
        switch self {
        case .disabled: return "Off"
        case .foregroundHint: return "Foreground"
        case .backgroundHint: return "Background"
        case .ignoreHint: return "Ignore"
        case .eraseHint: return "Erase"
        }
    }

    var systemImage: String {
        switch self {
        case .disabled: return "circle.slash"
        case .foregroundHint: return "plus.circle.fill"
        case .backgroundHint: return "minus.circle.fill"
        case .ignoreHint: return "xmark.circle.fill"
        case .eraseHint: return "eraser"
        }
    }
}

/// One reversible edit retains its exact analysis and its disk-cache leases.
private struct EditorEditSnapshot {
    let state: PluginStateData
    let mattes: [Int: MatteCacheEntry]
    let status: EditorAnalysisStatus
    let leases: [AnalysisDiskCache.Session]
}

@MainActor
@Observable
final class EditorViewModel {

    // MARK: - Foundational state

    @ObservationIgnored
    let renderEngine: StandaloneRenderEngine
    /// The queue belongs to the editor so permissions survive dismissing its sheet.
    let batchExport: BatchExportModel
    private let previewRenderer: StandalonePreviewRenderer
    /// Retains exactly the decoded frame on screen for source comparisons.
    @ObservationIgnored
    private var presentedSourceFrame: ReaderFrame?
    @ObservationIgnored
    private var warmsModelWhileOpen = false

    var phase: EditorPhase = .noClipLoaded
    /// All user-editable parameters. Bound directly to the inspector
    /// controls; mutating any property triggers a preview re-render via
    /// `parameterDidChange`. Initialised from `EditorPreferences` so
    /// the user's last-used Quality / Hint / Upscale Method choices
    /// survive across sessions; per-clip parameters (sliders, screen
    /// colour, etc.) start from the factory defaults inside
    /// `PluginStateData()`.
    var state: PluginStateData = EditorPreferences.makeInitialState() {
        didSet {
            guard !isRestoringEdit, oldValue != state else { return }
            if phase.isReady && (!isEditingParameter || !didRegisterParameterEdit) {
                registerUndo(state: oldValue, actionName: pendingEditName ?? "Change Keying Settings")
                didRegisterParameterEdit = isEditingParameter
            }
            guard oldValue.analysisHintConfiguration != state.analysisHintConfiguration
                    || oldValue.screenColor != state.screenColor || oldValue.qualityMode != state.qualityMode else { return }
            // An in-flight run owns the old annotations. Cancel it before
            // clearing, so queued results cannot repopulate a stale cache.
            cancelAnalysis()
            matteCache.removeAll()
            restoredAnalysisLeases = []
            analysisStatus = .idle
        }
    }
    /// Loaded clip metadata. `nil` while `.noClipLoaded`.
    var clipInfo: MediaSourceInfo?
    /// Stills use the shared keying controls without a playback timeline.
    var isStillImage: Bool { clipInfo?.kind == .stillImage }
    /// Most recently rendered frame, ready to draw on the preview
    /// surface. Updated whenever the playhead moves or a parameter
    /// changes.
    var latestPreview: PreviewFrame?
    /// Current playhead position in source time. Snapped to source
    /// frame boundaries on every set.
    var playheadTime: CMTime = .zero
    /// Total frame count for the loaded clip. Drives the scrubber
    /// granularity and analyse / export progress totals.
    var totalFrames: Int = 1
    /// Status of the most recent analyse pass.
    var analysisStatus: EditorAnalysisStatus = .idle
    /// Status of the most recent export pass.
    var exportStatus: EditorExportStatus = .idle
    /// In-memory matte cache populated by `runAnalysis`. Keyed by
    /// frame index.
    var matteCache: [Int: MatteCacheEntry] = [:]
    /// MLX warm-up status for the inspector badge.
    var warmupStatus: WarmupStatus = .cold
    /// User-readable description of the last render's backend (e.g.
    /// "Source Pass-Through", "Analysed Cache (1024px)"). Surfaced
    /// in the status row beneath the preview.
    var renderBackendDescription: String = "—"
    /// Effective render size, used to size the preview surface and
    /// label the export panel.
    var renderSize: CGSize = .zero
    /// Last-known engine description (mirrors the FxPlug
    /// "Inference Backend" badge — surfaces "MLX" vs "Rough matte").
    var lastEngineDescription: String = "—"
    /// Whether the transport is currently playing back. Drives the
    /// play / pause button glyph and the periodic playhead-advance
    /// loop.
    var isPlaying: Bool = false
    /// Whether playback should restart from frame 0 when it reaches
    /// the end of the clip. QuickTime's loop control mirrored.
    /// Defaults to on so users dragging through a short keying clip
    /// can let it loop while they tune parameters without having to
    /// rewind every time the playhead hits the end.
    var loopEnabled: Bool = true
    /// Rolling average of the per-tick playback frame rate, in
    /// frames per second. Computed by `runPlaybackLoop` from the
    /// wall-clock interval between successive renders. Zero outside
    /// playback. Drives the green/orange fps badge in the transport
    /// bar so the user can see at a glance whether their machine is
    /// keeping up with realtime.
    var measuredPlaybackFPS: Double = 0
    /// The frame rate the loaded clip would play at if every render
    /// landed instantly — i.e. the source's nominal frame rate. The
    /// transport bar's fps badge compares `measuredPlaybackFPS`
    /// against this threshold to colour itself green vs orange.
    var targetPlaybackFPS: Double = 0
    /// Currently-active OSC tool — drives the click handler on the
    /// preview surface.
    var oscTool: OnScreenControlTool = .disabled
    /// While the user holds the "Show Original" button, this flips
    /// to `true` and the preview renders the source frame straight
    /// through (no pre-inference, no MLX, no post). Releasing the
    /// button flips it back to `false`. The transient flag triggers
    /// an immediate re-render via its `didSet`.
    var isShowingOriginal: Bool = false {
        didSet {
            guard oldValue != isShowingOriginal else { return }
            renderPreview(at: playheadTime)
        }
    }
    /// Backdrop drawn behind the keyed preview image. The declared
    /// default is `.checkerboard`; `init` upgrades to `.customImage`
    /// on first launch by pre-loading the bundled `Background.png`
    /// (Castle Gate sample) into `customBackdropTexture`, so a
    /// freshly-launched editor composites its first clip over a
    /// believable scene rather than a flat checkerboard. The
    /// Background popover lets the user replace or clear that
    /// starter image, or pick a solid colour / checkerboard; that
    /// pick is persisted via `BackdropPreferences` and restored on
    /// the next launch — losing the backdrop on every launch was a
    /// recurring papercut.
    var previewBackdrop: PreviewBackdrop = .checkerboard {
        didSet {
            guard previewBackdrop != oldValue else { return }
            BackdropPreferences.saveSelected(previewBackdrop)
        }
    }
    /// Colour rendered behind the keyed image when `previewBackdrop`
    /// is `.customColor`. Persisted to UserDefaults so the user's
    /// last pick survives a launch.
    var customBackdropColor: BackdropColor = .default {
        didSet {
            guard customBackdropColor != oldValue else { return }
            BackdropPreferences.saveCustomColor(customBackdropColor)
        }
    }
    /// User-imported image rendered behind the keyed image when
    /// `previewBackdrop` is `.customImage`. The texture is built
    /// from the image data once at import time and re-used until
    /// the user picks a different image. SwiftUI invalidates on
    /// reassignment because the underlying object identity changes.
    var customBackdropTexture: (any MTLTexture)?
    /// Display name of the imported image (the URL's last path
    /// component) — surfaced in the menu so the user knows which
    /// file is currently in use.
    var customBackdropImageName: String?

    // MARK: - Internal state

    @ObservationIgnored
    private var videoSource: (any EditorMediaSource)?
    /// Invalidates imports that finish after another import or Close.
    @ObservationIgnored
    private var loadIdentifier = UUID()
    @ObservationIgnored
    private var inflightRenderTask: Task<Void, Never>?
    @ObservationIgnored
    private var analysisTask: Task<Void, Never>?
    @ObservationIgnored
    private var analysisRunnerTask: Task<Void, Never>?
    @ObservationIgnored
    private var analysisRunIdentifier = 0
    @ObservationIgnored
    private var exportTask: Task<Void, Never>?
    @ObservationIgnored
    private var exportRunnerTask: Task<Void, Never>?
    @ObservationIgnored
    private var exportRunIdentifier = 0
    /// Debounces preview re-renders during slider drags so the GPU
    /// isn't flooded with intermediate states. Reset every parameter
    /// edit; whoever fires last wins.
    @ObservationIgnored
    private var pendingPreviewTask: Task<Void, Never>?
    /// Background Task that drives playback. Replaces the legacy
    /// `Timer.scheduledTimer` loop so each tick can await the GPU
    /// render before advancing — earlier builds fired ticks at the
    /// source frame rate regardless of render latency, which on a
    /// short looping clip meant the displayed frame never actually
    /// caught up to the playhead.
    @ObservationIgnored
    private var playbackTask: Task<Void, Never>?
    @ObservationIgnored
    private var playbackRunIdentifier = UUID()
    /// Polls the shared MLX bridge registry while the rung is warming
    /// up so the inspector badge tracks `cold → warming → ready` in
    /// real time. Cancelled when the engine becomes `.ready` /
    /// `.failed`, when the editor closes, or when its displayed quality changes.
    @ObservationIgnored
    private var warmupPollingTask: Task<Void, Never>?
    @ObservationIgnored
    private var activeWarmupResolution: Int?
    /// Screen colour used for status queries. All v2 colours share one model.
    @ObservationIgnored
    private var activeWarmupScreenColor: ScreenColor?
    /// `UndoManager` the SwiftUI environment hands us at view-mount
    /// time. Hint-point mutations register undo / redo against this
    /// manager so Cmd-Z / Cmd-Shift-Z step through the user's edit
    /// history. Held weakly because the manager belongs to the
    /// hosting `NSWindow`; the view model must not extend its
    /// lifetime.
    @ObservationIgnored
    weak var undoManager: UndoManager?
    @ObservationIgnored
    private var isRestoringEdit = false
    @ObservationIgnored
    private var pendingEditName: String?
    @ObservationIgnored
    private var restoredAnalysisLeases: [AnalysisDiskCache.Session] = []
    @ObservationIgnored
    private var isEditingParameter = false
    @ObservationIgnored
    private var didRegisterParameterEdit = false

    /// A continuous slider drag is one undo operation, including its initial cache.
    func parameterEditingChanged(_ editing: Bool) {
        isEditingParameter = editing
        didRegisterParameterEdit = false
    }

    /// Captures values and small disk references, never a decoded clip. Leases
    /// protect the referenced predictions from eviction until this undo expires.
    private func registerUndo(state previousState: PluginStateData, actionName: String) {
        guard let undoManager, undoManager.isUndoRegistrationEnabled else { return }
        let needsGroup = !undoManager.groupsByEvent && undoManager.groupingLevel == 0
            && !undoManager.isUndoing && !undoManager.isRedoing
        if needsGroup { undoManager.beginUndoGrouping() }
        defer { if needsGroup { undoManager.endUndoGrouping() } }
        let snapshot = EditorEditSnapshot(
            state: previousState, mattes: matteCache,
            status: analysisStatus.inProgress ? .cancelled : analysisStatus,
            leases: (try? AnalysisDiskCache.shared.pinSessions(for: matteCache.values.compactMap(\.reference))) ?? []
        )
        undoManager.registerUndo(withTarget: self) { target in
            target.restoreEdit(snapshot, actionName: actionName)
        }
        undoManager.setActionName(actionName)
    }

    private func restoreEdit(_ snapshot: EditorEditSnapshot, actionName: String) {
        let canReuseAnalysis = state.analysisHintConfiguration == snapshot.state.analysisHintConfiguration
            && state.screenColor == snapshot.state.screenColor && state.qualityMode == snapshot.state.qualityMode
        registerUndo(state: state, actionName: actionName)
        if !canReuseAnalysis { cancelAnalysis() }
        isRestoringEdit = true
        state = snapshot.state
        isRestoringEdit = false
        if !canReuseAnalysis {
            matteCache = snapshot.mattes
            analysisStatus = snapshot.status
            restoredAnalysisLeases = snapshot.leases
        }
        parameterDidChange()
    }

    init(renderEngine: StandaloneRenderEngine) {
        self.renderEngine = renderEngine
        self.batchExport = BatchExportModel(engine: renderEngine)
        self.previewRenderer = StandalonePreviewRenderer(engine: renderEngine)
        self.customBackdropColor = BackdropPreferences.loadCustomColor() ?? .default

        let savedSelection = BackdropPreferences.loadSelected()
        let bookmarkData = BackdropPreferences.loadImageBookmark()

        // Pre-load the bundled `Background.png` (Castle Gate sample)
        // into the custom-image slot whenever the user hasn't
        // imported their own. Covers the first-ever launch (no
        // saved selection, no bookmark) AND every subsequent launch
        // where the user kept the bundled starter — the decoded
        // texture isn't persisted across launches, so we re-decode
        // it each time. Skipped when a user bookmark exists; the
        // async restore path below will install their image into
        // the same slot.
        if bookmarkData == nil,
           let bundledTexture = Self.loadBundledBackdropTexture(device: renderEngine.device) {
            self.customBackdropTexture = bundledTexture
            self.customBackdropImageName = Self.bundledBackdropImageName
        }

        // Restore the user's last backdrop pick. `.customImage` is
        // honoured immediately when we have either the bundled
        // starter (just loaded above) or a user bookmark queued for
        // async restore; otherwise we fall back to checkerboard so
        // the user doesn't land on an unrenderable case. Other
        // saved selections apply directly. First launch with the
        // bundled image loaded defaults to `.customImage` so the
        // user sees the keyer composited over the sample backdrop
        // immediately. Any assignment via `=` skips the property's
        // `didSet`, so this restoration doesn't write the value
        // straight back to UserDefaults — the on-disk record stays
        // exactly as the user left it. The first-launch upgrade is
        // saved explicitly via `BackdropPreferences.saveSelected`
        // so subsequent launches restore it through the regular
        // saved-selection path.
        if let savedSelection {
            if savedSelection == .customImage,
               self.customBackdropTexture == nil,
               bookmarkData == nil {
                self.previewBackdrop = .checkerboard
            } else {
                self.previewBackdrop = savedSelection
            }
        } else if self.customBackdropTexture != nil {
            self.previewBackdrop = .customImage
            BackdropPreferences.saveSelected(.customImage)
        }

        EditorWorkRegistry.shared.register(self)
        // Restore the user's last imported image asynchronously so
        // the editor window appears immediately. If the bookmark is
        // stale (file moved / deleted) we silently fall back to
        // checkerboard rather than surfacing an error on launch.
        if let bookmarkData {
            let restoreToImageBackdrop = savedSelection == .customImage
            Task { [weak self, device = renderEngine.device] in
                await Self.restoreCustomBackdropImage(
                    bookmarkData: bookmarkData,
                    device: device,
                    activateImageBackdrop: restoreToImageBackdrop,
                    into: self
                )
            }
        }
    }

    /// Friendly display name surfaced in the Background popover when
    /// the editor falls back to the bundled `Background.png` starter.
    /// Reads more naturally than the literal filename ("Background.png")
    /// while still telling the user this is a built-in image they can
    /// replace or clear.
    static let bundledBackdropImageName = "Sample"

    // MARK: - Custom backdrop import

    /// Loads `url` as the custom-image backdrop, switches the
    /// preview backdrop to `.customImage`, and persists a security-
    /// scoped bookmark so the same image is restored on next
    /// launch. Throws if the file is too large or the decode fails;
    /// callers surface the error in an alert.
    ///
    /// Decoding + texture upload runs on the main actor: `MTLTexture`
    /// isn't `Sendable`, so we'd have to wrap it in an unchecked
    /// transfer to push the work off main. For a typical backdrop
    /// image (PNG / JPEG ≤ 64 MB) the work is fast enough to land
    /// inside one frame; the import sheet is already modal so a few
    /// hundred milliseconds of UI freeze isn't perceptible.
    func importBackdropImage(from url: URL) async throws {
        let scopeStarted = url.startAccessingSecurityScopedResource()
        defer {
            if scopeStarted {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let data = try Data(contentsOf: url)
        let bookmarkData = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let texture = try BackdropImageLoader.makeTexture(from: data, device: renderEngine.device)
        self.customBackdropTexture = texture
        self.customBackdropImageName = url.lastPathComponent
        BackdropPreferences.saveImageBookmark(bookmarkData)
        // Replacing the bundled starter image leaves `previewBackdrop`
        // already on `.customImage`, so the property's `didSet`
        // would short-circuit before saving the selection. Save it
        // explicitly here so subsequent launches restore the user's
        // image instead of falling back to the checkerboard while
        // the bookmark loads silently in the background.
        self.previewBackdrop = .customImage
        BackdropPreferences.saveSelected(.customImage)
        renderPreview(at: playheadTime)
    }

    /// Drops the imported (or bundled-starter) image and falls back
    /// to the checkerboard backdrop. Clears the persisted bookmark
    /// too — next launch won't try to re-load a file the user just
    /// removed. Once cleared, the bundled starter doesn't return on
    /// the next launch either: the saved selection now reads
    /// `.checkerboard`, which the init's saved-selection path
    /// honours directly.
    func clearBackdropImage() {
        customBackdropTexture = nil
        customBackdropImageName = nil
        BackdropPreferences.clearImageBookmark()
        if previewBackdrop == .customImage {
            previewBackdrop = .checkerboard
            renderPreview(at: playheadTime)
        }
    }

    /// Loads the bundled `Background.png` (the Castle Gate sample)
    /// from the wrapper app's `Resources` group into a Metal texture.
    /// Returns `nil` when the resource isn't present in `Bundle.main`
    /// — the test runner's bundle, for example — or when the decode
    /// fails. Callers fall back to the checkerboard backdrop in that
    /// case so the user never lands on an unrenderable selection.
    private static func loadBundledBackdropTexture(device: any MTLDevice) -> (any MTLTexture)? {
        guard let url = Bundle.main.url(forResource: "Background", withExtension: "png"),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? BackdropImageLoader.makeTexture(from: data, device: device)
    }

    /// Resolves a security-scoped bookmark and pushes the resulting
    /// texture onto the view model. Runs on the main actor because
    /// `MTLTexture` isn't `Sendable`; the decode is fast enough not
    /// to disrupt the launch animation in practice (the editor
    /// window is already drawing by the time this fires).
    @MainActor
    private static func restoreCustomBackdropImage(
        bookmarkData: Data,
        device: any MTLDevice,
        activateImageBackdrop: Bool,
        into viewModel: EditorViewModel?
    ) async {
        var isStale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            // Bookmark unresolvable — likely the file was deleted
            // or moved. Drop the saved bookmark so we don't keep
            // trying.
            BackdropPreferences.clearImageBookmark()
            return
        }
        let scopeStarted = url.startAccessingSecurityScopedResource()
        defer {
            if scopeStarted {
                url.stopAccessingSecurityScopedResource()
            }
        }
        guard let data = try? Data(contentsOf: url) else { return }
        let texture: any MTLTexture
        do {
            texture = try BackdropImageLoader.makeTexture(from: data, device: device)
        } catch {
            return
        }
        guard let viewModel else { return }
        viewModel.customBackdropTexture = texture
        viewModel.customBackdropImageName = url.lastPathComponent
        // Only switch the active backdrop to `.customImage` when the
        // user's last saved selection was `.customImage`. Restoring
        // the texture without flipping the picker means the user's
        // last colour pick wins on launch, while the texture is
        // ready the moment they pick Custom Image from the menu.
        if activateImageBackdrop {
            viewModel.previewBackdrop = .customImage
            viewModel.renderPreview(at: viewModel.playheadTime)
        }
        if isStale {
            if let refreshed = try? url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                BackdropPreferences.saveImageBookmark(refreshed)
            }
        }
    }

    // MARK: - Clip loading

    /// Loads a video or still image. Existing matte cache is dropped.
    /// On success transitions to `.ready`, auto-detects the Screen
    /// Colour from the first frame, and renders the first frame for
    /// preview.
    func loadClip(at url: URL) async {
        cancelInflightWork(cancelModelWarmup: false)
        let identifier = UUID()
        loadIdentifier = identifier
        phase = .loadingClip(url)
        do {
            let source = try await MediaSourceLoader.load(url: url)
            guard loadIdentifier == identifier, !Task.isCancelled else { return }
            self.state.hintPointSet.clear()
            self.undoManager?.removeAllActions(withTarget: self)
            self.videoSource = source
            let info = source.info
            self.clipInfo = info
            self.totalFrames = source.totalFrameCount()
            self.renderSize = info.renderSize
            self.matteCache.removeAll(keepingCapacity: true)
            self.restoredAnalysisLeases = []
            self.analysisStatus = .idle
            self.exportStatus = .idle
            self.playheadTime = .zero
            self.latestPreview = nil
            self.presentedSourceFrame = nil
            guard loadIdentifier == identifier, !Task.isCancelled else { return }
            self.phase = .ready
            if warmsModelWhileOpen { beginWarmupForCurrentQuality() }
            renderPreview(at: .zero)
        } catch {
            guard loadIdentifier == identifier, !Task.isCancelled else { return }
            self.phase = .loadFailed(error.localizedDescription)
        }
    }

    /// Samples the first frame and switches `state.screenColor` to
    /// whichever colour dominates the frame's chroma. The user's last
    /// manual choice (read from `state.screenColor` before this call,
    /// which itself was seeded from `EditorPreferences`) is the
    /// fallback when the frame is too neutral to be confident — e.g.
    /// a pre-screen reference plate or a slate.
    ///
    /// Best-effort: any decode failure leaves the screen colour
    /// untouched. The user can flip the picker manually in that case.
    private func autoDetectScreenColor(source: any EditorMediaSource, loadIdentifier: UUID) async {
        do {
            let pixelBuffer = try await source.makeFrame(
                atTime: .zero,
                preferredPixelFormat: kCVPixelFormatType_32BGRA
            )
            guard self.loadIdentifier == loadIdentifier, !Task.isCancelled else { return }
            let detected = ScreenColorAutoDetector.detect(
                firstFrame: pixelBuffer,
                fallback: state.screenColor
            )
            if state.screenColor == .automatic, detected != state.screenColor {
                state.screenColor = detected
            }
        } catch {
            // Decoder couldn't produce a probe frame in BGRA — that's
            // OK, just keep the user's prior choice.
        }
    }

    /// Closes the current clip and returns the editor to the empty
    /// state. Cancels any in-flight analyse / export work.
    func closeClip() {
        phase = .noClipLoaded
        loadIdentifier = UUID()
        cancelInflightWork(cancelModelWarmup: false)
        stopPlayback()
        videoSource = nil
        clipInfo = nil
        latestPreview = nil
        presentedSourceFrame = nil
        matteCache.removeAll()
        restoredAnalysisLeases = []
        analysisStatus = .idle
        exportStatus = .idle
        playheadTime = .zero
        renderBackendDescription = "—"
        lastEngineDescription = "—"
        state.hintPointSet.clear()
        undoManager?.removeAllActions(withTarget: self)
        phase = .noClipLoaded
    }

    // MARK: - Playback transport

    /// Starts or stops playback. Each tick of the playback timer
    /// advances the playhead by one source frame; when it reaches
    /// the end of the clip we either loop back to frame 0 or stop
    /// based on `loopEnabled`.
    func togglePlayback() {
        if isPlaying {
            stopPlayback()
        } else {
            startPlayback()
        }
    }

    private func startPlayback() {
        guard let clipInfo, phase.isReady, !isStillImage, !isPlaying else { return }
        targetPlaybackFPS = max(Double(clipInfo.nominalFrameRate), 0)
        measuredPlaybackFPS = 0
        isPlaying = true
        pendingPreviewTask?.cancel()
        pendingPreviewTask = nil
        playbackTask?.cancel()
        let identifier = UUID()
        playbackRunIdentifier = identifier
        playbackTask = Task { @MainActor [weak self] in
            await self?.runPlaybackLoop(identifier: identifier)
        }
    }

    private func stopPlayback() {
        playbackRunIdentifier = UUID()
        playbackTask?.cancel()
        playbackTask = nil
        isPlaying = false
        measuredPlaybackFPS = 0
    }

    /// Awaits-each-frame playback loop. Each iteration:
    ///
    /// 1. Picks the next frame index (wrapping when `loopEnabled`).
    /// 2. Decodes the next frame without advancing the visible playhead.
    /// 3. **Awaits** `performRender(frame:)` for that frame so the
    ///    user actually sees every frame land — the legacy timer-
    ///    based path fired ticks at the nominal frame rate even
    ///    when the GPU couldn't keep up, which on a short looping
    ///    clip silently dropped most renders mid-flight.
    /// 4. If the render finished faster than the source's per-frame
    ///    interval, sleeps the remainder so playback runs at the
    ///    real frame rate instead of turbo-mode.
    /// 5. Updates `measuredPlaybackFPS` from the wall-clock interval
    ///    so the transport bar's badge can colour itself green
    ///    (≥ 95% of target) or orange (below).
    private func runPlaybackLoop(identifier: UUID) async {
        guard let clipInfo, let source = videoSource else { return }
        var reader: PlaybackFrameReader?
        let clock = ContinuousClock()
        var deadline = clock.now
        let frameRate = max(Double(clipInfo.nominalFrameRate), 0.001)
        let frameIntervalSeconds = 1.0 / frameRate
        // Window of recent samples used to smooth the displayed fps
        // — without smoothing, a single slow frame would slam the
        // badge into the orange band even when the average is fine.
        // Sized to ~1 s of history so the indicator settles within
        // a wall-clock second of any change.
        let fpsSampleCap = max(Int(frameRate.rounded()), 1)
        var fpsSamples: [Double] = []

        while isPlaying && !Task.isCancelled {
            let tickStart = clock.now

            let currentFrame = currentFrameIndex(at: playheadTime)
            let lastFrame = max(totalFrames - 1, 0)
            let nextFrame: Int
            if currentFrame >= lastFrame {
                if loopEnabled {
                    nextFrame = 0
                    reader = nil
                } else {
                    isPlaying = false
                    break
                }
            } else {
                nextFrame = currentFrame + 1
            }

            let target = CMTime(
                seconds: Double(nextFrame) / frameRate,
                preferredTimescale: clipInfo.timescale
            )
            do {
                if reader == nil {
                    reader = try await PlaybackFrameReader(source: source, startTime: target)
                }
                guard let frame = try await reader?.nextFrame() else { break }
                try Task.checkCancellation()
                try await performRender(frame: frame)
            } catch {
                if !Task.isCancelled {
                    handlePreviewFailure(error)
                }
                if playbackRunIdentifier == identifier { isPlaying = false }
                break
            }
            if Task.isCancelled { break }

            deadline += .seconds(frameIntervalSeconds)
            if clock.now < deadline {
                try? await clock.sleep(until: deadline)
            } else {
                // Never race through frames to catch up after a slow render.
                deadline = clock.now
            }
            if Task.isCancelled { break }

            let elapsed = tickStart.duration(to: clock.now).components
            let tickSeconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            let achievedFPS = 1.0 / max(tickSeconds, 0.001)
            fpsSamples.append(achievedFPS)
            while fpsSamples.count > fpsSampleCap {
                fpsSamples.removeFirst()
            }
            measuredPlaybackFPS = fpsSamples.reduce(0, +) / Double(fpsSamples.count)
        }
        guard playbackRunIdentifier == identifier else { return }
        playbackTask = nil
        isPlaying = false
        measuredPlaybackFPS = 0
    }

    /// Awaitable variant of `renderPreview(at:)` used by the
    /// playback loop so each tick can wait for the rendered frame
    /// to actually land before advancing. Throws on render or
    /// decode failure so the caller can stop playback cleanly. Does
    /// not interact with `pendingPreviewTask` — that field exists
    /// to coalesce parameter-edit re-renders, which playback never
    /// fights with because the playback task owns the rendering
    /// schedule end-to-end.
    @MainActor
    private func performRender(frame: ReaderFrame) async throws {
        let frameTime = frame.presentationTime
        let frameIndex = currentFrameIndex(at: frameTime)
        var stateForFrame = state
        if let cached = matteCache[frameIndex] {
            stateForFrame.cachedMatteBlob = cached.inlineBlob
            stateForFrame.cachedFrameReference = cached.reference
            stateForFrame.cachedMatteInferenceResolution = cached.inferenceResolution
            if let reference = cached.reference { AnalysisDiskCache.shared.prefetch(reference) }
        }
        stateForFrame.sourceFrameIndex = frameIndex
        stateForFrame.destinationLongEdgePixels = max(
            Int(renderSize.width.rounded()),
            Int(renderSize.height.rounded())
        )
        let pixelBuffer = frame.pixelBuffer
        let showingOriginal = isShowingOriginal
        let result = try await previewRenderer.render(
            frame: frame, state: stateForFrame, showingOriginal: showingOriginal
        )
        try Task.checkCancellation()
        // Publish timing only when its image is ready. Pausing while the next
        // frame renders must leave comparisons pinned to the displayed frame.
        playheadTime = frameTime
        presentedSourceFrame = frame
        if let next = matteCache[frameIndex + 1]?.reference { AnalysisDiskCache.shared.prefetch(next) }
        self.latestPreview = PreviewFrame(
            texture: result.destinationTexture,
            pixelBuffer: result.destinationPixelBuffer,
            presentationTime: frameTime,
            isLinear: (showingOriginal || result.report.effectiveInferenceResolution == 0) ? stateForFrame.video.inputIsLinear : stateForFrame.outputIsLinear,
            isPremultiplied: showingOriginal || result.report.effectiveInferenceResolution == 0 || stateForFrame.outputMode != .foregroundPlusMatte,
            gamut: StandaloneRenderEngine.workingGamut(for: pixelBuffer)
        )
        self.renderBackendDescription = result.report.backendDescription
        self.lastEngineDescription = result.report.guideSourceDescription
    }

    /// Toggles the loop affordance. Keeps playback running if it
    /// was; lets the user enable it mid-playback so the transport
    /// keeps the playhead from running off the end.
    func toggleLoop() {
        loopEnabled.toggle()
    }

    private func seek(toFrameIndex frameIndex: Int) {
        guard let clipInfo else { return }
        let frameRate = max(Double(clipInfo.nominalFrameRate), 0.001)
        let target = CMTime(
            seconds: Double(frameIndex) / frameRate,
            preferredTimescale: clipInfo.timescale
        )
        playheadTime = target
        renderPreview(at: target)
    }

    // MARK: - Transport

    /// Moves the playhead to a normalised position (0…1) interpreted
    /// as a position within the clip's **frame range**. Earlier
    /// builds mapped to position-within-duration, which on a short
    /// clip (the asset's duration is one frame past the last sample)
    /// meant the user couldn't drag the slider all the way to the
    /// last frame — a 4-frame clip's slider stopped at 0.75, hiding
    /// the final sample behind the right edge.
    ///
    /// Frame-index space: 0 → frame 0, 1 → frame N-1.
    func scrub(toNormalized fraction: Double) {
        guard let clipInfo, phase.isReady, !isStillImage, fraction.isFinite else { return }
        stopPlayback()
        let clamped = min(max(fraction, 0), 1)
        let lastFrameIndex = max(totalFrames - 1, 0)
        let frameRate = max(Double(clipInfo.nominalFrameRate), 0.001)
        let targetFrame = Int((clamped * Double(lastFrameIndex)).rounded())
        let target = CMTime(
            seconds: Double(targetFrame) / frameRate,
            preferredTimescale: clipInfo.timescale
        )
        playheadTime = target
        renderPreview(at: target)
    }

    /// Moves the playhead by an integer number of source frames.
    /// Pauses playback and clamps to actual source samples. Used by the
    /// transport's step buttons.
    func step(byFrames delta: Int) {
        guard let clipInfo, phase.isReady, !isStillImage else { return }
        stopPlayback()
        let frameRate = max(Double(clipInfo.nominalFrameRate), 0.001)
        let currentFrame = Int((playheadTime.seconds * frameRate).rounded())
        let targetFrame = max(0, min(totalFrames - 1, currentFrame + delta))
        let target = CMTime(
            seconds: Double(targetFrame) / frameRate,
            preferredTimescale: clipInfo.timescale
        )
        playheadTime = target
        renderPreview(at: target)
    }

    /// Pauses and seeks to the first source frame.
    func jumpToFirstFrame() { scrub(toNormalized: 0) }

    /// Pauses and seeks to the last sample, never the time just past the clip.
    func jumpToLastFrame() { scrub(toNormalized: 1) }

    // MARK: - Preview rendering

    /// Schedules a preview render for the given source time. Cancels
    /// any pending render so the latest parameter edit always wins.
    func renderPreview(at time: CMTime) {
        guard !isPlaying else { return }
        guard let source = videoSource else { return }
        let frameTime = time
        let frameIndex = currentFrameIndex(at: frameTime)
        var stateForFrame = state
        if let cached = matteCache[frameIndex] {
            stateForFrame.cachedMatteBlob = cached.inlineBlob
            stateForFrame.cachedFrameReference = cached.reference
            stateForFrame.cachedMatteInferenceResolution = cached.inferenceResolution
            if let reference = cached.reference { AnalysisDiskCache.shared.prefetch(reference) }
        }
        stateForFrame.sourceFrameIndex = frameIndex
        stateForFrame.destinationLongEdgePixels = max(
            Int(renderSize.width.rounded()),
            Int(renderSize.height.rounded())
        )
        let previewRenderer = previewRenderer
        let showingOriginal = isShowingOriginal
        let presentedFrame = presentedSourceFrame.flatMap {
            currentFrameIndex(at: $0.presentationTime) == frameIndex ? $0 : nil
        }

        pendingPreviewTask?.cancel()
        pendingPreviewTask = Task { [weak self] in
            guard let self else { return }
            let pixelBuffer: CVPixelBuffer
            do {
                if let presentedFrame {
                    pixelBuffer = presentedFrame.pixelBuffer
                } else {
                    pixelBuffer = try await source.makeFrame(atTime: frameTime)
                }
            } catch {
                if Task.isCancelled { return }
                self.phase = .loadFailed(error.localizedDescription)
                return
            }
            if Task.isCancelled { return }
            do {
                let result = try await previewRenderer.render(
                    frame: ReaderFrame(pixelBuffer: pixelBuffer, presentationTime: frameTime, duration: .invalid),
                    state: stateForFrame, showingOriginal: showingOriginal
                )
                if Task.isCancelled { return }
                self.presentedSourceFrame = ReaderFrame(
                    pixelBuffer: pixelBuffer, presentationTime: frameTime, duration: .invalid
                )
                self.latestPreview = PreviewFrame(
                    texture: result.destinationTexture,
                    pixelBuffer: result.destinationPixelBuffer,
                    presentationTime: frameTime,
                    isLinear: (showingOriginal || result.report.effectiveInferenceResolution == 0) ? stateForFrame.video.inputIsLinear : stateForFrame.outputIsLinear,
                    isPremultiplied: showingOriginal || result.report.effectiveInferenceResolution == 0 || stateForFrame.outputMode != .foregroundPlusMatte,
                    gamut: StandaloneRenderEngine.workingGamut(for: pixelBuffer)
                )
                self.renderBackendDescription = result.report.backendDescription
                self.lastEngineDescription = result.report.guideSourceDescription
            } catch {
                if Task.isCancelled { return }
                self.handlePreviewFailure(error)
            }
        }
    }

    /// Keep Analyse Clip available after disposable-cache loss. Retain the
    /// references so export also fails explicitly until the user analyses again.
    private func handlePreviewFailure(_ error: any Error) {
        if error is AnalysisDiskCacheError {
            latestPreview = nil
            analysisStatus = .failed(error.localizedDescription)
        } else {
            phase = .loadFailed(error.localizedDescription)
        }
    }

    /// Refreshes a paused preview and persists session-level choices. Playback
    /// consumes the next frame with the latest settings. Model warm-up runs
    /// independently of source decoding and preview playback.
    func parameterDidChange() {
        renderPreview(at: playheadTime)
        if warmsModelWhileOpen || analysisStatus.inProgress { beginWarmupForCurrentQuality() }
        EditorPreferences.qualityMode = state.qualityMode
        EditorPreferences.hintMode = state.hintMode
        EditorPreferences.upscaleMethod = state.upscaleMethod
    }

    /// Restores factory parameters in one undoable edit. The state observer
    /// invalidates predictions only when an inference setting changes.
    func resetAllParameters() {
        pendingEditName = "Reset All Parameters"
        defer { pendingEditName = nil }
        state = PluginStateData()
        parameterDidChange()
    }

    /// Same estimate as the analysis preflight and FxPlug inspector.
    var videoMemoryDescription: String {
        let longEdge = max(Int(clipInfo?.renderSize.width ?? 1920), Int(clipInfo?.renderSize.height ?? 1080))
        let resolution = state.qualityMode.resolvedInferenceResolution(forLongEdge: longEdge, deviceRegistryID: renderEngine.device.registryID)
        let frameCount = max(1, Int((clipInfo?.duration.seconds ?? 1) * Double(clipInfo?.nominalFrameRate ?? 1)))
        return state.video.memoryDescription(resolution: resolution, frameCount: frameCount,
                                            deviceBudget: renderEngine.device.recommendedMaxWorkingSetSize)
    }

    /// V2 settings affecting the model invalidate predictions; output controls reuse them.
    func videoParameterDidChange() {
        parameterDidChange()
    }

    /// Assigns the visible source frame to the selected single-frame matte.
    func setCurrentFrameAsHintReference() {
        guard let clipInfo else { return }
        state.video.referenceFrame = max(0, Int((playheadTime.seconds * Double(clipInfo.nominalFrameRate)).rounded()))
        videoParameterDidChange()
    }

    // MARK: - On-screen control (OSC)

    /// Handles a click anywhere on the preview surface. Coordinates
    /// are normalised (0…1) — `(0, 0)` is top-left, `(1, 1)` is
    /// bottom-right of the rendered frame, matching the convention
    /// the FxPlug OSC writes into the `HintPointSet` parameter.
    /// No-op when the tool is `.disabled`.
    func handleOSCClick(atNormalizedPoint point: CGPoint) {
        guard let clipInfo, !isPlaying, !state.video.useAlphaHint,
              let frame = HintFrame(
                  time: playheadTime,
                  duration: CMTime(seconds: 1 / Double(clipInfo.nominalFrameRate), preferredTimescale: clipInfo.timescale)
              ) else { return }
        // A seek may still be decoding. Do not annotate the previous image
        // using the new playhead's timestamp.
        if let latestPreview, !frame.contains(latestPreview.presentationTime) { return }
        let tool = oscTool
        let clampedX = min(max(Double(point.x), 0), 1)
        let clampedY = min(max(Double(point.y), 0), 1)
        var nextSet = state.hintPointSet
        let actionName: String?
        switch tool {
        case .disabled:
            return
        case .foregroundHint:
            nextSet.add(HintPoint(x: clampedX, y: clampedY, kind: .foreground, frame: frame))
            actionName = "Add Foreground Hint"
        case .backgroundHint:
            nextSet.add(HintPoint(x: clampedX, y: clampedY, kind: .background, frame: frame))
            actionName = "Add Background Hint"
        case .ignoreHint:
            nextSet.add(HintPoint(x: clampedX, y: clampedY, kind: .ignore, frame: frame))
            actionName = "Add Ignore Hint"
        case .eraseHint:
            let didRemove = nextSet.removeNearest(toX: clampedX, y: clampedY, tolerance: 0.05, at: playheadTime)
            actionName = didRemove ? "Erase Hint" : nil
        }
        // No-op clicks (erase tool with nothing in tolerance) skip
        // the undo registration so they don't pollute the history
        // with steps the user can't see.
        guard let actionName, nextSet != state.hintPointSet else { return }
        applyHintPointSet(nextSet, actionName: actionName)
    }

    /// Only annotations belonging to the displayed source frame.
    var currentFrameHints: [HintPoint] {
        state.hintPointSet.points(at: playheadTime)
    }

    /// Clears the displayed frame while preserving annotations elsewhere in the clip.
    func clearHintsOnCurrentFrame() {
        guard !currentFrameHints.isEmpty else { return }
        var nextSet = state.hintPointSet
        nextSet.clear(at: playheadTime)
        applyHintPointSet(nextSet, actionName: "Clear Hints on This Frame")
    }

    /// Wipes every placed hint point.
    func clearAllHints() {
        guard !state.hintPointSet.isEmpty else { return }
        applyHintPointSet(HintPointSet(), actionName: "Clear All Hints")
    }

    /// Replaces the active hint set with `newSet` and registers an
    /// undo that restores whatever was there before. Calling
    /// `undoManager.undo()` later runs the closure, which itself
    /// registers a redo via this same code path — that's the
    /// standard `UndoManager` snapshot pattern.
    private func applyHintPointSet(_ newSet: HintPointSet, actionName: String) {
        pendingEditName = actionName
        defer { pendingEditName = nil }
        var editedState = state
        editedState.hintPointSet = newSet
        if !newSet.isEmpty { editedState.hintMode = .manual }
        state = editedState
        // Hints feed the MLX bridge at analysis time. Re-render the
        // preview now so the dots appear immediately; the user can
        // re-analyse to see the matte respond to the new hints.
        parameterDidChange()
    }

    // MARK: - Analysis

    /// Starts the analyse-clip pass. The matte cache is rebuilt from
    /// scratch — the editor never blends partial caches into a result.
    func runAnalysis() {
        guard let source = videoSource else { return }
        stopPlayback()
        cancelAnalysis()
        analysisRunIdentifier += 1
        let runIdentifier = analysisRunIdentifier
        let runner = AnalysisRunner(renderEngine: renderEngine, videoSource: source)
        let stateSnapshot = state
        let startingPlayhead = playheadTime
        analysisStatus = .running(processed: 0, total: totalFrames)
        matteCache.removeAll(keepingCapacity: true)
        beginWarmupForCurrentQuality()

        // Bridge the runner's `@Sendable` event callback to a main-actor
        // event loop via an AsyncStream. This keeps the event sink off of
        // self entirely — only the surrounding for-await loop touches the
        // view model, and that loop is already main-actor-isolated.
        let (eventStream, continuation) = AsyncStream<AnalysisRunnerEvent>.makeStream()
        let runTask = Task(priority: .userInitiated) {
            await runner.run(state: stateSnapshot) { event in
                continuation.yield(event)
            }
            continuation.finish()
        }
        analysisRunnerTask = runTask
        continuation.onTermination = { @Sendable _ in
            runTask.cancel()
        }
        analysisTask = Task { [weak self, runTask, continuation] in
            var shouldRefreshPreview = true
            defer {
                continuation.finish()
                runTask.cancel()
                if let self, self.analysisRunIdentifier == runIdentifier {
                    self.analysisTask = nil
                    self.analysisRunnerTask = nil
                }
            }
            for await event in eventStream {
                if Task.isCancelled {
                    shouldRefreshPreview = false
                    break
                }
                guard let self else {
                    shouldRefreshPreview = false
                    break
                }
                self.handleAnalysisEvent(event, fallbackTotalFrames: self.totalFrames)
            }
            if Task.isCancelled || !shouldRefreshPreview {
                runTask.cancel()
                continuation.finish()
            }
            _ = await runTask.value
            guard shouldRefreshPreview, !Task.isCancelled else { return }
            guard let self, self.analysisRunIdentifier == runIdentifier else { return }
            // After analysis completes, refresh the preview so the
            // current playhead picks up its newly-cached matte.
            self.renderPreview(at: startingPlayhead)
        }
    }

    /// Cancels an in-flight analyse pass. Already-cached frames stay
    /// in the cache so the user can still preview them; the rest of
    /// the clip will re-trigger pass-through.
    func cancelAnalysis() {
        cancelAnalysisTasks()
        if case .running = analysisStatus {
            analysisStatus = .cancelled
        }
    }

    @MainActor
    private func handleAnalysisEvent(
        _ event: AnalysisRunnerEvent,
        fallbackTotalFrames: Int
    ) {
        switch event {
        case .framePrepared(let frameIndex):
            renderBackendDescription = "Preparing frame \(frameIndex + 1) for Time Awareness"
        case .totalFramesResolved(let total):
            self.totalFrames = max(total, 1)
            self.analysisStatus = .running(processed: 0, total: max(total, 1))
        case .frameProcessed(let frameIndex, let engineDescription, let entry):
            self.matteCache[frameIndex] = entry
            self.lastEngineDescription = engineDescription
            let total: Int
            if case .running(_, let resolvedTotal) = analysisStatus {
                total = resolvedTotal
            } else {
                total = fallbackTotalFrames
            }
            self.analysisStatus = .running(processed: matteCache.count, total: total)
            // If the analyser just produced the matte for the frame
            // the user is currently looking at, push a re-render so
            // they see the keyed result the moment it's available
            // — earlier builds left them staring at the source until
            // the entire pass finished.
            if frameIndex == currentFrameIndex(at: playheadTime) {
                renderPreview(at: playheadTime)
            }
        case .completed(let elapsed):
            self.analysisStatus = .completed(
                elapsedSeconds: elapsed,
                totalFrames: max(self.matteCache.count, 1)
            )
        case .failed(let message):
            self.analysisStatus = .failed(message)
        case .cancelled:
            self.analysisStatus = .cancelled
        }
    }

    // MARK: - Export

    /// Starts a ProRes 4444 export. The destination is the URL the
    /// user picked in the save panel; this method assumes that URL is
    /// already accessible to the wrapper app's sandbox.
    func runExport(options: ExportOptions) {
        guard let source = videoSource, phase.isReady, !isStillImage else { return }
        let snapshot = ExportProjectSnapshot(state: state, cachedMattes: matteCache)
        let exporter = ProResExporter(
            renderEngine: renderEngine,
            videoSource: source,
            project: snapshot
        )
        startExport(totalFrames: totalFrames) { continuation in
            await exporter.run(options: options) { event in continuation.yield(event) }
        }
    }

    /// Exports the still at its native resolution with an alpha channel.
    func runExport(options: StillImageExportOptions) {
        guard let source = videoSource, phase.isReady, isStillImage else { return }
        let exporter = StillImageExporter(
            renderEngine: renderEngine, source: source,
            project: ExportProjectSnapshot(state: state, cachedMattes: matteCache)
        )
        startExport(totalFrames: 1) { continuation in
            await exporter.run(options: options) { event in continuation.yield(event) }
        }
    }

    /// Owns progress, cancellation, and lifetime identically for both exporters.
    private func startExport(
        totalFrames totalFramesSnapshot: Int,
        operation: @escaping @Sendable (AsyncStream<ExportRunnerEvent>.Continuation) async -> Void
    ) {
        cancelExport()
        exportRunIdentifier += 1
        let runIdentifier = exportRunIdentifier
        exportStatus = .running(processed: 0, total: totalFramesSnapshot)

        let (eventStream, continuation) = AsyncStream<ExportRunnerEvent>.makeStream()
        let runTask = Task(priority: .userInitiated) {
            await operation(continuation)
            continuation.finish()
        }
        exportRunnerTask = runTask
        continuation.onTermination = { @Sendable _ in
            runTask.cancel()
        }
        exportTask = Task { [weak self, runTask, continuation] in
            var shouldFinishNormally = true
            defer {
                continuation.finish()
                runTask.cancel()
                if let self, self.exportRunIdentifier == runIdentifier {
                    self.exportTask = nil
                    self.exportRunnerTask = nil
                }
            }
            for await event in eventStream {
                if Task.isCancelled {
                    shouldFinishNormally = false
                    break
                }
                guard let self else {
                    shouldFinishNormally = false
                    break
                }
                self.handleExportEvent(event, fallbackTotalFrames: totalFramesSnapshot)
            }
            if Task.isCancelled || !shouldFinishNormally {
                runTask.cancel()
                continuation.finish()
            }
            _ = await runTask.value
            guard shouldFinishNormally, !Task.isCancelled else { return }
        }
    }

    /// Cancels an in-flight export pass.
    func cancelExport() {
        cancelExportTasks()
        if case .running = exportStatus {
            exportStatus = .cancelled
        }
    }

    @MainActor
    private func handleExportEvent(
        _ event: ExportRunnerEvent,
        fallbackTotalFrames: Int
    ) {
        switch event {
        case .started(let total):
            self.exportStatus = .running(processed: 0, total: max(total, 1))
        case .frameWritten(let frameIndex):
            let total: Int
            if case .running(_, let resolvedTotal) = exportStatus {
                total = resolvedTotal
            } else {
                total = fallbackTotalFrames
            }
            self.exportStatus = .running(processed: frameIndex + 1, total: total)
        case .completed(let url):
            self.exportStatus = .completed(url)
        case .failed(let message):
            self.exportStatus = .failed(message)
        case .cancelled:
            self.exportStatus = .cancelled
        }
    }

    // MARK: - Helpers

    /// Called when a standalone editor appears, even before importing media.
    /// FxPlug never calls this; its model remains demand-loaded.
    func prepareModelForEditor() {
        warmsModelWhileOpen = true
        beginWarmupForCurrentQuality()
    }

    private func beginWarmupForCurrentQuality() {
        let longEdge = max(Int(clipInfo?.renderSize.width ?? 1920), Int(clipInfo?.renderSize.height ?? 1080))
        let resolution = state.qualityMode.resolvedInferenceResolution(
            forLongEdge: longEdge, deviceRegistryID: renderEngine.device.registryID
        )
        let screenColor = state.screenColor
        if activeWarmupResolution == resolution, activeWarmupScreenColor == screenColor,
           warmupStatus == .warming(resolution: resolution) || warmupStatus == .ready(resolution: resolution) {
            return
        }
        // V2 shares one model across resolutions and screen colours. Changing
        // either while importing must not cancel the launch-time load.
        activeWarmupResolution = resolution
        activeWarmupScreenColor = screenColor
        do {
            try renderEngine.beginWarmup(forResolution: resolution, screenColor: screenColor)
            warmupStatus = renderEngine.warmupStatus(forResolution: resolution, screenColor: screenColor)
        } catch {
            // Warm-up is best-effort. If it fails the analyse pass
            // surfaces the same error the moment it tries to use MLX.
            return
        }
        // Drive a poll of the registry until the engine is ready or
        // failed so the inspector badge transitions out of "warming"
        // on its own. Without this the user only saw the status
        // refresh when they next clicked Analyse Clip — the value
        // was set once and then went stale.
        startWarmupStatusPolling(forResolution: resolution, screenColor: screenColor)
    }

    /// Polls the shared MLX bridge registry every 400 ms and republishes
    /// the result on `warmupStatus` so the inspector badge tracks the
    /// engine's lifecycle in real time. Stops when the engine is ready,
    /// failed, or the editor closes.
    private func startWarmupStatusPolling(forResolution resolution: Int, screenColor: ScreenColor) {
        warmupPollingTask?.cancel()
        warmupPollingTask = Task { @MainActor [weak self] in
            // First tick is immediate so the badge updates within the
            // same frame that kicked off the warm-up.
            while let self, !Task.isCancelled {
                let latest = self.renderEngine.warmupStatus(
                    forResolution: resolution,
                    screenColor: screenColor
                )
                if latest != self.warmupStatus {
                    self.warmupStatus = latest
                }
                switch latest {
                case .ready, .failed:
                    self.warmupPollingTask = nil
                    return
                case .cold, .warming:
                    break
                }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    /// Cancels work that should not survive editor/window teardown.
    /// The returned task handles let app termination briefly wait for
    /// cooperative cancellation without keeping the view model alive.
    @discardableResult
    func cancelWorkForEditorShutdown() -> [Task<Void, Never>] {
        warmsModelWhileOpen = false
        var tasks = cancelInflightWork()
        if let batchTask = batchExport.cancel() { tasks.append(batchTask) }
        return tasks
    }

    /// Other editor windows may still need the process-wide model during teardown.
    var hasModelDemand: Bool {
        warmsModelWhileOpen || analysisTask != nil || analysisRunnerTask != nil || batchExport.isRunning
    }

    var hasInflightEditorWork: Bool {
        inflightRenderTask != nil
            || pendingPreviewTask != nil
            || warmupPollingTask != nil
            || playbackTask != nil
            || analysisTask != nil
            || analysisRunnerTask != nil
            || exportTask != nil
            || exportRunnerTask != nil
            || batchExport.isRunning
    }

    @discardableResult
    private func cancelInflightWork(cancelModelWarmup: Bool = true) -> [Task<Void, Never>] {
        loadIdentifier = UUID()
        var tasks: [Task<Void, Never>] = []
        if let inflightRenderTask {
            tasks.append(inflightRenderTask)
            inflightRenderTask.cancel()
            self.inflightRenderTask = nil
        }
        if let pendingPreviewTask {
            tasks.append(pendingPreviewTask)
            pendingPreviewTask.cancel()
            self.pendingPreviewTask = nil
        }
        if cancelModelWarmup {
            if let warmupPollingTask { tasks.append(warmupPollingTask) }
            tasks.append(contentsOf: cancelActiveWarmup())
        }
        tasks.append(contentsOf: cancelAnalysisTasks())
        tasks.append(contentsOf: cancelExportTasks())
        if let playbackTask {
            tasks.append(playbackTask)
        }
        stopPlayback()
        return tasks
    }

    @discardableResult
    private func cancelAnalysisTasks() -> [Task<Void, Never>] {
        analysisRunIdentifier += 1
        let tasks = [analysisTask, analysisRunnerTask].compactMap { $0 }
        analysisTask?.cancel()
        analysisRunnerTask?.cancel()
        analysisTask = nil
        analysisRunnerTask = nil
        return tasks
    }

    @discardableResult
    private func cancelExportTasks() -> [Task<Void, Never>] {
        exportRunIdentifier += 1
        let tasks = [exportTask, exportRunnerTask].compactMap { $0 }
        exportTask?.cancel()
        exportRunnerTask?.cancel()
        exportTask = nil
        exportRunnerTask = nil
        return tasks
    }

    private func cancelActiveWarmup() -> [Task<Void, Never>] {
        var tasks: [Task<Void, Never>] = []
        warmupPollingTask?.cancel()
        warmupPollingTask = nil
        if let activeWarmupResolution, let activeWarmupScreenColor {
            if !EditorWorkRegistry.shared.hasModelDemand(excluding: self),
               let warmupTask = renderEngine.cancelWarmup(
                forResolution: activeWarmupResolution,
                screenColor: activeWarmupScreenColor
            ) {
                tasks.append(warmupTask)
            }
            self.activeWarmupResolution = nil
            self.activeWarmupScreenColor = nil
        }
        if case .warming = warmupStatus {
            warmupStatus = .cold
        }
        return tasks
    }

    private func currentFrameIndex(at time: CMTime) -> Int {
        guard let clipInfo else { return 0 }
        let fps = max(Double(clipInfo.nominalFrameRate), 0.001)
        return Int((time.seconds * fps).rounded())
    }
}

/// Light value type holding the bytes the preview surface currently
/// shows. Holding the source pixel buffer keeps the IOSurface (and
/// therefore the texture's underlying memory) alive until the next
/// frame replaces this value.
struct PreviewFrame {
    let texture: any MTLTexture
    let pixelBuffer: CVPixelBuffer
    let presentationTime: CMTime
    var isLinear = false
    var isPremultiplied = true
    var gamut: WorkingColorGamut = .rec709
}

/// Tracks live standalone editor view models so app termination can
/// cancel their GPU/MLX work before process teardown starts releasing
/// shared Metal state.
@MainActor
final class EditorWorkRegistry {
    static let shared = EditorWorkRegistry()

    private var entries: [WeakEditorViewModel] = []

    private init() {}

    func register(_ viewModel: EditorViewModel) {
        prune()
        guard !entries.contains(where: { $0.viewModel === viewModel }) else { return }
        entries.append(WeakEditorViewModel(viewModel))
    }

    func unregister(_ viewModel: EditorViewModel) {
        entries.removeAll { entry in
            guard let registered = entry.viewModel else { return true }
            return registered === viewModel
        }
    }

    @discardableResult
    func cancelAllWorkForAppTermination() -> [Task<Void, Never>] {
        prune()
        return entries.flatMap { entry in
            entry.viewModel?.cancelWorkForEditorShutdown() ?? []
        }
    }

    /// A closing editor must not cancel the shared load another window is using.
    func hasModelDemand(excluding viewModel: EditorViewModel) -> Bool {
        entries.contains { entry in
            guard let other = entry.viewModel, other !== viewModel else { return false }
            return other.hasModelDemand
        }
    }

    var hasInflightEditorWork: Bool {
        prune()
        return entries.contains { entry in
            entry.viewModel?.hasInflightEditorWork == true
        }
    }

    private func prune() {
        entries.removeAll { $0.viewModel == nil }
    }
}

private struct WeakEditorViewModel {
    weak var viewModel: EditorViewModel?

    init(_ viewModel: EditorViewModel) {
        self.viewModel = viewModel
    }
}

/// Disk-backed persistence for the custom backdrop colour and
/// imported image. Sits next to the view model rather than in a
/// dedicated file because it has exactly one consumer; if a
/// second consumer ever appears, lift it into its own file.
enum BackdropPreferences {
    static let customColorKey = "CorridorKey.PreviewBackdrop.CustomColor"
    static let imageBookmarkKey = "CorridorKey.PreviewBackdrop.ImageBookmark"
    static let selectedKey = "CorridorKey.PreviewBackdrop.Selected"

    static func loadCustomColor() -> BackdropColor? {
        guard let data = UserDefaults.standard.data(forKey: customColorKey) else {
            return nil
        }
        return try? JSONDecoder().decode(BackdropColor.self, from: data)
    }

    static func saveCustomColor(_ color: BackdropColor) {
        guard let data = try? JSONEncoder().encode(color) else { return }
        UserDefaults.standard.set(data, forKey: customColorKey)
    }

    static func loadImageBookmark() -> Data? {
        UserDefaults.standard.data(forKey: imageBookmarkKey)
    }

    static func saveImageBookmark(_ data: Data) {
        UserDefaults.standard.set(data, forKey: imageBookmarkKey)
    }

    static func clearImageBookmark() {
        UserDefaults.standard.removeObject(forKey: imageBookmarkKey)
    }

    /// Returns the user's last-picked backdrop, or `nil` for first
    /// launch / unrecognised legacy values. The view model maps `nil`
    /// to its declared default (the checkerboard) — keeping the
    /// fallback colocated with the view model means changing the
    /// factory default lives in one place, not two.
    static func loadSelected() -> PreviewBackdrop? {
        guard let raw = UserDefaults.standard.string(forKey: selectedKey) else {
            return nil
        }
        return PreviewBackdrop(persistenceIdentifier: raw)
    }

    static func saveSelected(_ backdrop: PreviewBackdrop) {
        UserDefaults.standard.set(backdrop.persistenceIdentifier, forKey: selectedKey)
    }
}
