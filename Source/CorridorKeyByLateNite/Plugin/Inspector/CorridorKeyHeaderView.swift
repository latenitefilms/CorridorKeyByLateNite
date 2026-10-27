import SwiftUI

/// Analysis and cancellation share a row above the reset actions.
@MainActor
struct CorridorKeyControlsView: View {
    let bridge: CorridorKeyInspectorBridge

    var body: some View {
        VStack(alignment: .leading) {
            InspectorButtonRow {
                Button("Analyse Clip", systemImage: "wand.and.stars", action: bridge.triggerAnalysis)
                    .buttonStyle(.borderedProminent)
                    .disabled(bridge.snapshot.isWorking)
                if case .warming = bridge.snapshot.warmup {
                    Button("Cancel", systemImage: "xmark.circle", action: bridge.cancelWarmup)
                        .help("Cancel model loading")
                }
            }
            InspectorButtonRow {
                Button("Reset All", systemImage: "arrow.counterclockwise", action: bridge.resetAllParameters)
                    .disabled(bridge.snapshot.isWorking)
                    .help("Reset all keying parameters, animation and subject hints to their factory defaults.")
                Button("Reset Analysis", systemImage: "trash", action: bridge.resetAnalysis)
                    .disabled(bridge.snapshot.isWorking)
            }
        }
    }
}
/// Analysis status and diagnostics remain visible in their own native section.
@MainActor
struct CorridorKeyAnalysisDetailsView: View {
    let bridge: CorridorKeyInspectorBridge

    var body: some View {
        VStack(alignment: .leading) {
            CorridorKeyAnalysisProgress(snapshot: bridge.snapshot)
            AnalysisDetailsView(snapshot: bridge.snapshot, memoryEstimate: bridge.videoMemoryEstimate,
                                showsTiming: true)
            if let message = bridge.hintSelectionError {
                Text(message).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
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
                AnalysisRequiredLabel()
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

/// Manual tools and their reset actions live together, away from imported Alpha Hints.
@MainActor
struct CorridorKeyManualHintView: View {
    let bridge: CorridorKeyInspectorBridge

    var body: some View {
        VStack(alignment: .leading) {
            SubjectHintToolMenu(
                selection: Binding(get: { bridge.subjectTool }, set: { bridge.selectSubjectTool($0) }),
                clearCurrentFrame: { bridge.clearHints(onCurrentFrame: true) },
                clearAllFrames: { bridge.clearHints(onCurrentFrame: false) },
                hasAnyHints: bridge.snapshot.hintPointCount > 0
            )
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(bridge.snapshot.isWorking || bridge.usesAlphaHint || bridge.hintStorageUnavailable)
            CorridorKeyManualHintGuide()
            if bridge.hintStorageUnavailable {
                Text("Final Cut Pro could not read the saved hints and analysis. Choose Reset All to clear this effect’s saved data, or remove and reapply the updated effect.")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if bridge.hasLegacyHints {
                Text(ManualHintGuidance.legacyExplanation)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message = bridge.hintSelectionError {
                Text(message).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Explains the same explicit Subject workflow as the standalone editor.
private struct CorridorKeyManualHintGuide: View {
    var body: some View {
        VStack(alignment: .leading) {
            Text("Turn off Use Alpha Hint, then choose a tool from Subject. Select CorridorKey by LateNite in the Video inspector and click the subject or background in the viewer. Adding a point selects Apple Vision + Manual Points automatically.")
                .foregroundStyle(.secondary)
            Text("Points apply to the current frame. Choose Off to stop marking, then Analyse Clip to update the result.")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
    }
}
