import AppKit
import SwiftUI

/// The two inspectors use the same help button and popover for manual points.
struct ManualHintHelpButton: View {
    var showsFinalCutProInstructions = false
    @State private var showingHelp = false

    var body: some View {
        Button("About Manual Hint", systemImage: "questionmark.circle") { showingHelp = true }
            .popover(isPresented: $showingHelp) {
                ManualHintHelpView(showsFinalCutProInstructions: showsFinalCutProInstructions)
            }
    }
}

/// Explains tool selection, frame scope and analysis without expanding the inspector.
struct ManualHintHelpView: View {
    var showsFinalCutProInstructions = false

    var body: some View {
        InspectorHelpPopover(title: "Manual Hint", systemImage: "hand.point.up.left") {
            InspectorHelpSection(
                title: "Choose a tool",
                message: "Turn off Use Alpha Hint, then choose a tool from Subject. Click the subject or background in the viewer to place a point."
            )
            if showsFinalCutProInstructions {
                InspectorHelpSection(
                    title: "In Final Cut Pro",
                    message: "Select CorridorKey by LateNite in the Video inspector to make its viewer controls active."
                )
            }
            InspectorHelpSection(
                title: "Edit points on this frame",
                message: "Points apply to the current frame. Choose \(OnScreenControlTool.eraseHint.menuDisplayName) and click near a point to remove it. The Subject menu also lets you clear hints on this frame or all frames."
            )
            Divider()
            InspectorHelpSection(
                title: "Update the key",
                message: "Adding a point selects Apple Vision + Manual Points automatically. Choose Off to stop marking, then Analyse Clip to update the result."
            )
        }
    }
}

/// A consistent content-sized layout for inspector help in both hosts.
struct InspectorHelpPopover<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: systemImage).font(.headline)
            content()
        }
        .padding()
        .frame(width: 340, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Keeps each help topic together while leaving space between paragraphs.
struct InspectorHelpSection: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading) {
            Text(title).bold()
            Text(message).foregroundStyle(.secondary)
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Shared Subject menu. Final Cut Pro uses explicit tools without claiming its shortcuts.
struct SubjectHintToolMenu: View {
    @Binding var selection: OnScreenControlTool
    let clearCurrentFrame: () -> Void
    let clearAllFrames: () -> Void
    var hasCurrentFrameHints = true
    var hasAnyHints = true
    var usesKeyboardShortcuts = false

    var body: some View {
        Menu {
            ForEach(OnScreenControlTool.allCases) { tool in
                Button(tool.menuDisplayName, systemImage: tool.systemImage) {
                    selection = tool
                }
                .keyboardShortcut(usesKeyboardShortcuts ? shortcut(for: tool) : nil)
            }
            Divider()
            Button("Clear Hints on This Frame", systemImage: "eraser", action: clearCurrentFrame)
                .disabled(!hasCurrentFrameHints)
            Button("Clear All Hints", systemImage: "trash", action: clearAllFrames)
                .disabled(!hasAnyHints)
                .keyboardShortcut(usesKeyboardShortcuts ? KeyboardShortcut(.delete, modifiers: [.command, .shift]) : nil)
        } label: {
            Text("\(Image(systemName: selection.menuImage))   \(selection.menuTitle)")
        }
        .accessibilityLabel(selection.menuTitle)
        .help(ManualHintGuidance.explanation)
    }

    private func shortcut(for tool: OnScreenControlTool) -> KeyboardShortcut {
        let key: KeyEquivalent = switch tool {
        case .disabled: "o"
        case .foregroundHint: "f"
        case .backgroundHint: "b"
        case .ignoreHint: "i"
        case .eraseHint: "e"
        }
        return KeyboardShortcut(key, modifiers: [.command, .shift])
    }
}

/// Product identity shared by the standalone and FxPlug inspectors.
@MainActor
struct CorridorKeyBrandingView: View {
    var body: some View {
        HStack {
            Image(nsImage: CorridorKeyInspectorAssets.applicationIcon())
                .resizable()
                .interpolation(.high)
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading) {
                Text("CorridorKey by LateNite").font(.headline)
                Text("v\(CorridorKeyInspectorAssets.versionString()) (Build \(CorridorKeyInspectorAssets.buildString()))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

/// Keeps related actions on one line. Narrow inspectors can scroll the row
/// horizontally without truncating titles or reserving additional height.
struct InspectorButtonRow<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, content: content)
                .fixedSize()
            ScrollView(.horizontal) {
                HStack(alignment: .firstTextBaseline, content: content)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .labelStyle(.titleAndIcon)
    }
}

/// Draws attention to the next step when a clip has no analysed cache.
struct AnalysisRequiredLabel: View {
    var body: some View {
        Label("Press Analyse Clip to build the matte cache.", systemImage: "info.circle")
            .font(.callout)
            .bold()
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Live diagnostic fields shared by both inspectors. Unknown values remain
/// explicit, so loading a model or completing analysis never hides a field.
struct AnalysisDetailsView: View {
    let snapshot: CorridorKeyAnalysisSnapshot
    let memoryEstimate: VideoMemoryEstimate?
    /// Only FxPlug currently measures render time and estimates analysis completion.
    let showsTiming: Bool

    var body: some View {
        VStack(alignment: .leading) {
            AnalysisDetailRow(title: "Backend", systemImage: "cpu", value: snapshot.renderBackendDescription)
            AnalysisDetailRow(title: "Cached Mattes", systemImage: "square.stack.3d.up", value: "\(snapshot.analyzedFrameCount) / \(snapshot.totalFrameCount)")
                .help(AnalysisDiskCache.storageExplanation)
            AnalysisDetailRow(title: "Neural Model", systemImage: "brain", value: snapshot.neuralModelDescription)
                .help("Analysed playback uses the cache and does not need the neural model to be loaded.")
            AnalysisDetailRow(title: "Inference Resolution", systemImage: "viewfinder", value: snapshot.inferenceResolution > 0 ? "\(snapshot.inferenceResolution) px" : "—")
            if showsTiming {
                AnalysisDetailRow(title: "Time Remaining", systemImage: "hourglass", value: snapshot.remainingTimeDescription)
                AnalysisDetailRow(title: "Last Render", systemImage: "stopwatch", value: snapshot.lastRenderMilliseconds.map {
                    "\($0.formatted(.number.precision(.fractionLength(1)))) ms"
                } ?? "—")
            }
            AnalysisDetailRow(title: "Source Resolution", systemImage: "rectangle", value: snapshot.sourceResolutionDescription)
            AnalysisDetailRow(title: "Source Frame Rate", systemImage: "film", value: snapshot.sourceFrameRate.map {
                "\($0.formatted(.number.precision(.fractionLength(0...3)))) fps"
            } ?? "—")
            AnalysisDetailRow(title: "Manual Hints", systemImage: "hand.point.up.left", value: snapshot.hintPointCount.formatted())
                .help(HintMode.explanation)
            AnalysisDetailRow(title: "Estimated GPU Memory", systemImage: "memorychip",
                              value: memoryEstimate?.estimatedBytes.formatted(.byteCount(style: .memory)) ?? "—")
            AnalysisDetailRow(title: "Device Budget", systemImage: "desktopcomputer",
                              value: memoryEstimate?.deviceBudgetBytes.formatted(.byteCount(style: .memory)) ?? "—")
            if memoryEstimate?.exceedsDeviceBudget == true {
                Label("Lower Time Awareness or Quality.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.callout)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Matches the label/value alignment of Final Cut Pro's native parameters.
private struct AnalysisDetailRow: View {
    let title: String
    let systemImage: String
    let value: String

    var body: some View {
        LabeledContent {
            Text(value)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        } label: {
            Label(title, systemImage: systemImage)
        }
    }
}

/// Returns the wrapper app icon bundled alongside the FxPlug service. Walks
/// up from the main bundle to find the owning `.app`, matching the lookup
/// Final Cut Pro uses so we get the same artwork the Finder would show.
@MainActor
enum CorridorKeyInspectorAssets {
    static func containingApplicationURL() -> URL? {
        var current = Bundle.main.bundleURL
        while current.path != "/" {
            if current.pathExtension == "app" {
                return current
            }
            current = current.deletingLastPathComponent()
        }
        return nil
    }

    static func containingApplicationBundle() -> Bundle? {
        guard let url = containingApplicationURL() else { return nil }
        return Bundle(url: url)
    }

    static func applicationIcon() -> NSImage {
        if let url = containingApplicationURL() {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    }

    static func versionString() -> String {
        let bundle = containingApplicationBundle() ?? .main
        return (bundle.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }

    static func buildString() -> String {
        let bundle = containingApplicationBundle() ?? .main
        return (bundle.infoDictionary?["CFBundleVersion"] as? String) ?? "1"
    }
}
