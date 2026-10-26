import SwiftUI

/// Compact analysis controls; diagnostics open separately from the host's fixed row.
@MainActor
struct CorridorKeyHeaderView: View {
    let bridge: CorridorKeyInspectorBridge
    @State private var showingDetails = false

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Image(nsImage: CorridorKeyInspectorAssets.applicationIcon())
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading) {
                    Text("CorridorKey by LateNite").font(.headline)
                    Text("v\(CorridorKeyInspectorAssets.versionString()) (Build \(CorridorKeyInspectorAssets.buildString()))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            CorridorKeyAnalysisControls(bridge: bridge)
            CorridorKeyAnalysisProgress(snapshot: bridge.snapshot)
            if let message = bridge.hintSelectionError {
                Text(message).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Analysis Details", systemImage: "info.circle") { showingDetails = true }
                .buttonStyle(.borderless)
                .popover(isPresented: $showingDetails) {
                    CorridorKeyAnalysisDetails(bridge: bridge)
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Keeps primary actions visible even in a narrow inspector.
private struct CorridorKeyAnalysisControls: View {
    let bridge: CorridorKeyInspectorBridge

    var body: some View {
        VStack(alignment: .leading) {
            ViewThatFits(in: .horizontal) {
                HStack { CorridorKeyPrimaryAnalysisButtons(bridge: bridge) }
                VStack(alignment: .leading) { CorridorKeyPrimaryAnalysisButtons(bridge: bridge) }
            }
            .disabled(bridge.snapshot.isWorking)
            HStack {
                Button("Reset Analysis", systemImage: "trash", action: bridge.resetAnalysis)
                    .disabled(bridge.snapshot.isWorking)
                Menu("Subject Hints", systemImage: "person.crop.circle") {
                    Button("Clear Hints on This Frame", systemImage: "eraser") {
                        bridge.clearHints(onCurrentFrame: true)
                    }
                    Button("Clear All Hints", systemImage: "trash") {
                        bridge.clearHints(onCurrentFrame: false)
                    }
                }
                .labelStyle(.iconOnly)
                .disabled(bridge.snapshot.isWorking)
                .help(ManualHintGuidance.explanation
                      + "\nClick for foreground, Shift-click for background, Command-click to ignore, Option-click to erase."
                      + (bridge.hasLegacyHints ? "\n" + ManualHintGuidance.legacyExplanation : ""))
                if case .warming = bridge.snapshot.warmup {
                    Button("Cancel", systemImage: "xmark.circle", action: bridge.cancelWarmup)
                        .labelStyle(.iconOnly)
                        .help("Cancel model loading")
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

private struct CorridorKeyPrimaryAnalysisButtons: View {
    let bridge: CorridorKeyInspectorBridge

    var body: some View {
        Button("Analyse Clip", systemImage: "wand.and.stars", action: bridge.triggerAnalysis)
            .buttonStyle(.borderedProminent)
        Button("Reset All", systemImage: "arrow.counterclockwise", action: bridge.resetAllParameters)
            .help("Reset all keying parameters, animation and subject hints to their factory defaults.")
    }
}

/// Progress appears during analysis; its result remains visible afterwards.
private struct CorridorKeyAnalysisProgress: View {
    let snapshot: CorridorKeyAnalysisSnapshot

    var body: some View {
        VStack(alignment: .leading) {
            if snapshot.isWorking {
                ProgressView(value: snapshot.progress).progressViewStyle(.linear)
            }
            switch snapshot.state {
            case .notAnalysed:
                Label("Choose Analyse Clip to key this clip.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            case .requested:
                Label("Analysis queued…", systemImage: "clock")
            case .running:
                Label("Analysing frame \(snapshot.analyzedFrameCount) of \(snapshot.totalFrameCount)…", systemImage: "wand.and.stars")
            case .completed:
                Label("Analysed \(snapshot.analyzedFrameCount) \(snapshot.analyzedFrameCount == 1 ? "frame" : "frames").", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            case .interrupted:
                Label("Analysis interrupted.", systemImage: "exclamationmark.octagon")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

/// Wrapping, scrollable diagnostics accommodate long errors without truncation.
private struct CorridorKeyAnalysisDetails: View {
    let bridge: CorridorKeyInspectorBridge

    var body: some View {
        ScrollView {
            VStack(alignment: .leading) {
                Text("Analysis Details").font(.headline)
                Text("Backend: \(bridge.snapshot.renderBackendDescription)")
                Text("Cached mattes: \(bridge.snapshot.analyzedFrameCount) / \(bridge.snapshot.totalFrameCount)")
                switch bridge.snapshot.warmup {
                case .cold:
                    Text("Neural Model: Not Loaded")
                    Text("Analysed playback uses the cache and does not need the neural model to be loaded.")
                        .foregroundStyle(.secondary)
                case .warming(let resolution):
                    Text("Neural Model: Loading (\(resolution)px)…")
                case .ready(let resolution):
                    Text("Neural Model: Ready (\(resolution)px)")
                case .failed(let message):
                    Text("Neural Model Failed: \(message)").foregroundStyle(.red)
                }
                if let width = bridge.snapshot.sourceWidth, let height = bridge.snapshot.sourceHeight {
                    Text("Source Resolution: \(width) × \(height)")
                }
                if let rate = bridge.snapshot.sourceFrameRate {
                    Text("Source Frame Rate: \(rate.formatted(.number.precision(.fractionLength(0...3))))fps")
                }
                if let milliseconds = bridge.snapshot.lastRenderMilliseconds {
                    Text("Last Render: \(milliseconds.formatted(.number.precision(.fractionLength(1)))) ms")
                }
                Text(bridge.videoMemoryDescription)
                Text(AnalysisDiskCache.storageExplanation).foregroundStyle(.secondary)
                Divider()
                Text(HintMode.controlName).font(.headline)
                Text(HintMode.explanation)
                if let message = bridge.hintSelectionError {
                    Text(message).foregroundStyle(.red)
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .padding()
        }
        .frame(width: 360, height: 420)
    }
}

/// File selection sits beside the native Alpha Hint parameters in both hosts.
@MainActor
struct CorridorKeyAlphaHintView: View {
    @Bindable var bridge: CorridorKeyInspectorBridge

    var body: some View {
        VStack(alignment: .leading) {
            AlphaHintPicker(asset: $bridge.alphaHintAsset,
                            onChange: bridge.saveAlphaHintAsset,
                            setCurrentReference: bridge.setCurrentFrameAsHintReference)
                .disabled(bridge.snapshot.isWorking)
            if let message = bridge.hintSelectionError {
                Text(message).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
