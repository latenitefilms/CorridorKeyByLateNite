//
//  EditorView.swift
//  CorridorKey by LateNite — Standalone Editor
//
//  Top-level scene for the standalone editor window. The layout is a
//  vertical stack: preview surface → divider → transport bar. The
//  parameters inspector lives in the trailing-side `.inspector`
//  pane that AppKit-style macOS apps use for property panels.
//
//  We deliberately do not use `NavigationSplitView` here — the editor
//  has no leading sidebar. Final Cut Pro's keyer inspector layout
//  drops the sidebar entirely and dedicates the trailing column to
//  parameter controls; this mirrors that.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct EditorView: View {
    @State private var viewModel: EditorViewModel
    @State private var isImporting = false
    @State private var isExporting = false
    @State private var isBatchExporting = false
    @State private var loadFailureMessage: String?
    @State private var isDropTargeted = false
    @State private var isImportingBackdropImage = false
    @State private var backdropImportError: String?
    @FocusState private var previewHasFocus: Bool
    /// SwiftUI hands us the hosting `NSWindow`'s `UndoManager` here.
    /// The editor pipes it into `EditorViewModel` so hint-point
    /// edits register undo/redo against the manager Cmd-Z is
    /// already wired to dispatch through.
    @Environment(\.undoManager) private var undoManager

    /// `EditorViewModel` requires a `StandaloneRenderEngine` constructed
    /// at view-creation time so we can fail fast if Metal isn't
    /// available. The view crashes on init when that's the case;
    /// callers should not present this view on machines without a
    /// working GPU. (Apple Silicon Macs always have one.)
    init() {
        do {
            let engine = try StandaloneRenderEngine()
            self._viewModel = State(wrappedValue: EditorViewModel(renderEngine: engine))
        } catch {
            fatalError("CorridorKey by LateNite could not initialise its render engine: \(error.localizedDescription)")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Keep the focus target alive as the viewer changes from empty
            // to loading to ready, so focus cannot fall into the inspector.
            ZStack {
                previewArea
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .focusable(interactions: .edit)
            .focusEffectDisabled()
            .focused($previewHasFocus)

            Divider()

            TransportBar(
                viewModel: viewModel,
                onImport: { isImporting = true },
                onBatchImport: presentBatchExport,
                onClose: viewModel.closeClip,
                onExport: { isExporting = true },
                onPickBackdropImage: { isImportingBackdropImage = true }
            )
        }
        .navigationTitle(toolbarTitle)
        .focusedSceneValue(viewModel)
        .onKeyPress(.space, phases: [.down, .repeat]) { press in
            guard viewModel.phase.isReady, !viewModel.isStillImage,
                  !isImporting, !isExporting, !isBatchExporting, !isImportingBackdropImage,
                  press.modifiers.isEmpty else { return .ignored }
            if press.phase == .down { viewModel.togglePlayback() }
            return .handled
        }
        .onAppear { viewModel.prepareModelForEditor() }
        .dropDestination(for: URL.self) { urls, _ in
            guard !viewModel.batchExport.isRunning, !urls.isEmpty else { return false }
            handleImportedURLs(urls)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .inspector(isPresented: .constant(true)) {
            InspectorView(viewModel: viewModel)
                .inspectorColumnWidth(min: 300, ideal: 340, max: 400)
        }
        // Include both panes in the default-focus region. Keep automatic
        // priority so deliberate navigation to an inspector field still works.
        .defaultFocus($previewHasFocus, true)
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: MediaSourceLoader.supportedContentTypes,
            allowsMultipleSelection: true
        ) { result in
            handleImportResult(result)
        }
        .sheet(isPresented: $isExporting) {
            ExportSheet(viewModel: viewModel) {
                isExporting = false
            }
        }
        .sheet(isPresented: $isBatchExporting) {
            BatchExportSheet(model: viewModel.batchExport, state: viewModel.state)
        }
        .onChange(of: viewModel.phase) { previousPhase, phase in
            if case .loadingClip = previousPhase, case .ready = phase {
                previewHasFocus = true
            }
            if case .loadFailed(let message) = phase {
                loadFailureMessage = message
            }
        }
        .onChange(of: undoManager, initial: true) { _, manager in
            viewModel.undoManager = manager
        }
        .onDisappear {
            viewModel.cancelWorkForEditorShutdown()
        }
        .alert(
            "Couldn't load media",
            isPresented: Binding(
                get: { loadFailureMessage != nil },
                set: { if !$0 { loadFailureMessage = nil } }
            ),
            actions: {
                Button("OK", role: .cancel) { loadFailureMessage = nil }
            },
            message: {
                Text(loadFailureMessage ?? "Unknown error.")
            }
        )
    }

    @ViewBuilder
    private var previewArea: some View {
        switch viewModel.phase {
        case .noClipLoaded:
            EditorEmptyState(
                isDropTargeted: $isDropTargeted,
                onPickFile: { isImporting = true }
            )
        case .loadingClip(let url):
            VStack(spacing: 12) {
                ProgressView()
                Text("Opening \(url.lastPathComponent)…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
        case .ready, .loadFailed:
            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()
                MetalPreviewView(
                    device: viewModel.renderEngine.device,
                    frame: viewModel.latestPreview,
                    aspectFitSize: viewModel.renderSize,
                    backdrop: viewModel.previewBackdrop,
                    customColor: viewModel.customBackdropColor,
                    customImageTexture: viewModel.customBackdropTexture
                )
                .fileImporter(
                    isPresented: $isImportingBackdropImage,
                    allowedContentTypes: [.image, .png, .jpeg, .heic, .tiff],
                    allowsMultipleSelection: false
                ) { result in
                    handleBackdropImageImport(result)
                }
                .alert(
                    "Couldn't import image",
                    isPresented: Binding(
                        get: { backdropImportError != nil },
                        set: { if !$0 { backdropImportError = nil } }
                    ),
                    actions: {
                        Button("OK", role: .cancel) { backdropImportError = nil }
                    },
                    message: {
                        Text(backdropImportError ?? "Unknown error.")
                    }
                )
                OnScreenControlOverlay(
                    viewModel: viewModel,
                    renderSize: viewModel.renderSize
                )
                if viewModel.latestPreview == nil {
                    Text("Rendering preview…")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Triggers the backdrop-image picker. Lifted out of `EditorView`'s
    /// inline closures so the new `BackdropButton` in the transport
    /// bar can call it without re-implementing the import / clear
    /// state machine.
    func startBackdropImageImport() {
        isImportingBackdropImage = true
    }

    private var toolbarTitle: String {
        switch viewModel.phase {
        case .noClipLoaded: return "CorridorKey by LateNite"
        case .loadingClip: return "Loading…"
        case .ready:
            guard let url = viewModel.clipInfo?.url else { return "CorridorKey by LateNite" }
            return url.deletingPathExtension().lastPathComponent
        case .loadFailed: return "Couldn't load media"
        }
    }

    // MARK: - File handling

    private func handleImportResult(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            handleImportedURLs(urls)
        case .failure(let error):
            loadFailureMessage = error.localizedDescription
        }
    }

    private func handleImportedURLs(_ urls: [URL]) {
        if urls.count > 1 {
            viewModel.batchExport.add(urls)
            presentBatchExport()
        } else if let url = urls.first {
            loadClip(at: url)
        }
    }

    private func presentBatchExport() {
        Task {
            viewModel.cancelAnalysis()
            viewModel.cancelExport()
            for task in viewModel.cancelWorkForEditorShutdown() { await task.value }
            if case .loadingClip = viewModel.phase { viewModel.closeClip() }
            isBatchExporting = true
        }
    }

    private func loadClip(at url: URL) {
        Task {
            await viewModel.loadClip(at: url)
        }
    }

    private func handleBackdropImageImport(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            Task {
                do {
                    try await viewModel.importBackdropImage(from: url)
                } catch {
                    backdropImportError = error.localizedDescription
                }
            }
        case .failure(let error):
            backdropImportError = error.localizedDescription
        }
    }
}

/// Drag-and-drop / import placeholder shown when the editor has no
/// clip loaded. Mirrors the empty-state pattern used in macOS apps
/// like Photos and Final Cut Pro's import sheet.
private struct EditorEmptyState: View {
    @Binding var isDropTargeted: Bool
    let onPickFile: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "photo.on.rectangle")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Drop a video or still image to begin. Drop multiple videos to batch export.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("Supports ProRes, HEVC, H.264, PNG, TIFF, JPEG, HEIC, and more.")
                    .multilineTextAlignment(.center)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                Button("Import Media…", systemImage: "square.and.arrow.down", action: onPickFile)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.top, 8)
            }
            .padding()
            .padding(40)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(
                        isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 6])
                    )
                    .padding(28)
            )
        }
    }
}
