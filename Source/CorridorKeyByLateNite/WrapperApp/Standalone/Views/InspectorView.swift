//
//  InspectorView.swift
//  CorridorKey by LateNite — Standalone Editor
//
//  Mirrors the Final Cut Pro inspector layout for the standalone
//  editor: Controls → Analysis Details → Settings → Alpha Hint → Manual Hint → Time Awareness → Temporal Stability →
//  Interior Detail → Matte → Edge & Spill → Edge Refinement. Each group is a sibling `View`
//  struct so SwiftUI invalidates only the group whose data changed.
//
//  Sliders bind to the editor's `PluginStateData` directly via
//  `@Bindable`; flicking a value triggers `parameterDidChange()` on
//  the view model so the preview re-renders.
//

import SwiftUI

struct InspectorView: View {
    @Bindable var viewModel: EditorViewModel

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                InspectorGroupSeparator(isFirst: true)
                CorridorKeyBrandingView()
                InspectorGroupSeparator()
                AnalysisControlsGroup(viewModel: viewModel)
                InspectorGroupSeparator()
                StandaloneAnalysisDetails(viewModel: viewModel)
                InspectorGroupSeparator()
                SettingsGroup(viewModel: viewModel)
                InspectorGroupSeparator()
                VideoAlphaHintGroup(viewModel: viewModel)
                InspectorGroupSeparator()
                ManualHintGroup(viewModel: viewModel)
                InspectorGroupSeparator()
                VideoTimeAwarenessGroup(viewModel: viewModel)
                InspectorGroupSeparator()
                TemporalStabilityGroup(viewModel: viewModel)
                InspectorGroupSeparator()
                InteriorDetailGroup(viewModel: viewModel)
                InspectorGroupSeparator()
                MatteGroup(viewModel: viewModel)
                InspectorGroupSeparator()
                EdgeAndSpillGroup(viewModel: viewModel)
                InspectorGroupSeparator()
                EdgeRefinementGroup(viewModel: viewModel)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .background(.regularMaterial)
        .scrollIndicators(.hidden)
    }
}

/// Visual separator between inspector groups. Inset slightly so it
/// reads as a section divider rather than a full-width edge.
private struct InspectorGroupSeparator: View {
    var isFirst: Bool = false

    var body: some View {
        Divider()
            .padding(.top, isFirst ? 8 : 18)
            .padding(.bottom, isFirst ? 14 : 18)
    }
}

// MARK: - Analyse / status group

private struct AnalysisControlsGroup: View {
    let viewModel: EditorViewModel

    var body: some View {
        InspectorGroup(title: "Controls") {
            InspectorButtonRow {
                Button("Analyse Clip", systemImage: "wand.and.stars", action: viewModel.runAnalysis)
                    .buttonStyle(.borderedProminent)
                    .disabled(!viewModel.phase.isReady || viewModel.analysisStatus.inProgress)
                if viewModel.analysisStatus.inProgress {
                    Button("Stop", systemImage: "stop.fill", action: viewModel.cancelAnalysis)
                }
            }
            InspectorButtonRow {
                Button("Reset All", systemImage: "arrow.counterclockwise", action: viewModel.resetAllParameters)
                    .disabled(viewModel.analysisStatus.inProgress)
                    .help("Reset all keying parameters and subject hints to their factory defaults.")
                Button("Reset Analysis", systemImage: "trash", action: viewModel.resetAnalysis)
                    .disabled(viewModel.analysisStatus.inProgress)
            }
        }
    }
}

/// The same visible diagnostic fields as the FxPlug inspector.
private struct StandaloneAnalysisDetails: View {
    let viewModel: EditorViewModel

    var body: some View {
        InspectorGroup(title: "Analysis Details") {
            AnalysisProgressLabel(status: viewModel.analysisStatus, totalFrames: viewModel.totalFrames)
            AnalysisDetailsView(snapshot: viewModel.inspectorSnapshot,
                                memoryEstimate: viewModel.videoMemoryEstimate, showsTiming: false)
        }
    }
}

private struct AnalysisProgressLabel: View {
    let status: EditorAnalysisStatus
    let totalFrames: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if status.inProgress {
                ProgressView(value: progressValue)
            }

            switch status {
            case .idle:
                AnalysisRequiredLabel()
            case .running(let processed, let total):
                Text("Analysing frame \(processed) of \(total)…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .completed(let elapsed, let frames):
                Text("Analysed \(frames) \(frames == 1 ? "frame" : "frames") in \(AnalysisDurationFormatter.format(seconds: elapsed)).")
                    .font(.callout)
                    .foregroundStyle(.green)
            case .failed(let message):
                Text("Analysis failed: \(message)")
                    .font(.callout)
                    .foregroundStyle(.red)
            case .cancelled:
                Text("Analysis cancelled.")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var progressValue: Double {
        switch status {
        case .idle, .failed, .cancelled:
            return 0
        case .running(let processed, let total):
            return Double(processed) / Double(max(total, 1))
        case .completed:
            return 1
        }
    }
}

// MARK: - Setting group

private struct SettingsGroup: View {
    @Bindable var viewModel: EditorViewModel

    var body: some View {
        InspectorGroup(title: "Settings") {
            EnumPicker(
                title: ParameterRanges.qualityModeName,
                selection: $viewModel.state.qualityMode,
                defaultValue: ParameterRanges.Defaults.qualityMode,
                onChange: viewModel.parameterDidChange
            )
            EnumPicker(
                title: ParameterRanges.hintModeName,
                selection: $viewModel.state.hintMode,
                defaultValue: ParameterRanges.Defaults.hintMode,
                onChange: viewModel.parameterDidChange
            )
            .disabled(viewModel.state.video.useAlphaHint)
            Text(HintMode.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
            EnumPicker(
                title: ParameterRanges.screenColorName,
                selection: $viewModel.state.screenColor,
                defaultValue: ParameterRanges.Defaults.screenColor,
                onChange: viewModel.parameterDidChange
            )
            if viewModel.state.screenColor == .custom {
                ColorPicker("Custom Screen Colour", selection: Binding(
                    get: { Color(.sRGB, red: viewModel.state.video.customScreenColor.x,
                                 green: viewModel.state.video.customScreenColor.y, blue: viewModel.state.video.customScreenColor.z) },
                    set: { color in
                        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                              let components = color.cgColor?.converted(to: space, intent: .relativeColorimetric, options: nil)?.components,
                              components.count >= 3 else { return }
                        viewModel.state.video.customScreenColor = SIMD3(Double(components[0]), Double(components[1]), Double(components[2]))
                        viewModel.videoParameterDidChange()
                    }), supportsOpacity: false)
            }
            EnumPicker(
                title: ParameterRanges.upscaleMethodName,
                selection: $viewModel.state.upscaleMethod,
                defaultValue: ParameterRanges.Defaults.upscaleMethod,
                onChange: viewModel.parameterDidChange
            )
            EnumPicker(
                title: ParameterRanges.outputModeName,
                selection: $viewModel.state.outputMode,
                defaultValue: ParameterRanges.Defaults.outputMode,
                onChange: viewModel.parameterDidChange
            )
            ParameterToggle(title: VideoInferenceSettings.Labels.inputIsLinear,
                            isOn: $viewModel.state.video.inputIsLinear, defaultValue: false,
                            onChange: viewModel.videoParameterDidChange)
            ParameterToggle(title: VideoInferenceSettings.Labels.linearizeOutput,
                            isOn: $viewModel.state.video.linearizeOutput, defaultValue: false,
                            onChange: viewModel.videoParameterDidChange)
            ParameterToggle(title: VideoInferenceSettings.Labels.keepOriginalInSolidAreas,
                            isOn: $viewModel.state.video.keepOriginalInSolidAreas, defaultValue: false,
                            onChange: viewModel.videoParameterDidChange)

            if viewModel.state.hintMode == .manual || !viewModel.state.hintPointSet.isEmpty {
                Text(ManualHintGuidance.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if viewModel.state.hintPointSet.hasLegacyPoints {
                Text(ManualHintGuidance.legacyExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        }
    }
}

private struct VideoTimeAwarenessGroup: View {
    @Bindable var viewModel: EditorViewModel

    var body: some View {
        InspectorGroup(title: VideoInferenceSettings.Labels.timeAwareness) {
            EnumPicker(title: VideoInferenceSettings.Labels.timeAwareness,
                       selection: $viewModel.state.video.timeAwareness, defaultValue: .off,
                       onChange: viewModel.videoParameterDidChange)
            ParameterToggle(title: VideoInferenceSettings.Labels.lowGPUMemory,
                            isOn: $viewModel.state.video.lowGPUMemory, defaultValue: VideoInferenceSettings().lowGPUMemory,
                            onChange: viewModel.videoParameterDidChange)
            Text("Applied during Analyse Clip. " + viewModel.videoMemoryDescription)
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct VideoAlphaHintGroup: View {
    @Bindable var viewModel: EditorViewModel

    var body: some View {
        InspectorGroup(title: "Alpha Hint") {
            AlphaHintPicker(asset: $viewModel.state.video.alphaHintAsset,
                            onChange: viewModel.videoParameterDidChange,
                            setCurrentReference: viewModel.setCurrentFrameAsHintReference)
            ParameterToggle(title: VideoInferenceSettings.Labels.useAlphaHint,
                            isOn: $viewModel.state.video.useAlphaHint, defaultValue: false,
                            onChange: viewModel.videoParameterDidChange)
            EnumPicker(title: VideoInferenceSettings.Labels.hintFrames,
                       selection: $viewModel.state.video.hintFrames, defaultValue: .allFrames,
                       onChange: viewModel.videoParameterDidChange)
            ParameterIntSlider(range: .init(name: VideoInferenceSettings.Labels.referenceFrame,
                                           defaultValue: 0, parameterMin: 0, parameterMax: Int(Int32.max),
                                           sliderMin: 0, sliderMax: max(0, viewModel.totalFrames - 1), step: 1),
                               value: $viewModel.state.video.referenceFrame,
                               onChange: viewModel.videoParameterDidChange,
                onEditingChanged: viewModel.parameterEditingChanged)
                .disabled(viewModel.state.video.hintFrames != .singleFrame)
            ParameterFloatSlider(range: .init(name: VideoInferenceSettings.Labels.alphaHintStrength,
                                             defaultValue: 0.75, parameterMin: 0, parameterMax: 1,
                                             sliderMin: 0, sliderMax: 1, step: 0.01),
                                 value: $viewModel.state.video.alphaHintStrength,
                                 onChange: viewModel.videoParameterDidChange,
                onEditingChanged: viewModel.parameterEditingChanged)
            ParameterFloatSlider(range: .init(name: VideoInferenceSettings.Labels.internalHintStrength,
                                             defaultValue: 0.95, parameterMin: 0, parameterMax: 1,
                                             sliderMin: 0, sliderMax: 1, step: 0.01),
                                 value: $viewModel.state.video.internalHintStrength,
                                 onChange: viewModel.videoParameterDidChange,
                onEditingChanged: viewModel.parameterEditingChanged)
        }
    }
}

/// Mirrors the FxPlug Manual Hint section and shares the transport bar's selection.
private struct ManualHintGroup: View {
    @Bindable var viewModel: EditorViewModel

    var body: some View {
        InspectorGroup(title: "Manual Hint") {
            SubjectHintToolMenu(
                selection: $viewModel.oscTool,
                clearCurrentFrame: viewModel.clearHintsOnCurrentFrame,
                clearAllFrames: viewModel.clearAllHints,
                hasCurrentFrameHints: !viewModel.currentFrameHints.isEmpty,
                hasAnyHints: !viewModel.state.hintPointSet.isEmpty
            )
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(viewModel.analysisStatus.inProgress || viewModel.state.video.useAlphaHint)
            Text("Turn off Use Alpha Hint, then choose a tool from Subject and click in the viewer. Points apply to the current frame. Choose Analyse Clip to update the result.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct InteriorDetailGroup: View {
    @Bindable var viewModel: EditorViewModel

    var body: some View {
        InspectorGroup(title: "Interior Detail") {
            ParameterToggle(
                title: ParameterRanges.sourcePassthroughName,
                isOn: $viewModel.state.sourcePassthroughEnabled,
                defaultValue: ParameterRanges.Defaults.sourcePassthroughEnabled,
                onChange: viewModel.parameterDidChange
            )
            ParameterFloatSlider(
                range: ParameterRanges.passthroughErode,
                value: $viewModel.state.passthroughErodeNormalized,
                onChange: viewModel.parameterDidChange,
                onEditingChanged: viewModel.parameterEditingChanged
            )
            ParameterFloatSlider(
                range: ParameterRanges.passthroughBlur,
                value: $viewModel.state.passthroughBlurNormalized,
                onChange: viewModel.parameterDidChange,
                onEditingChanged: viewModel.parameterEditingChanged
            )
        }
    }
}

private struct MatteGroup: View {
    @Bindable var viewModel: EditorViewModel

    var body: some View {
        InspectorGroup(title: "Matte") {
            ParameterFloatSlider(
                range: ParameterRanges.alphaBlackPoint,
                value: $viewModel.state.alphaBlackPoint,
                onChange: viewModel.parameterDidChange,
                onEditingChanged: viewModel.parameterEditingChanged
            )
            ParameterFloatSlider(
                range: ParameterRanges.alphaWhitePoint,
                value: $viewModel.state.alphaWhitePoint,
                onChange: viewModel.parameterDidChange,
                onEditingChanged: viewModel.parameterEditingChanged
            )
            ParameterFloatSlider(
                range: ParameterRanges.alphaErode,
                value: $viewModel.state.alphaErodeNormalized,
                onChange: viewModel.parameterDidChange,
                onEditingChanged: viewModel.parameterEditingChanged
            )
            ParameterFloatSlider(
                range: ParameterRanges.alphaSoftness,
                value: $viewModel.state.alphaSoftnessNormalized,
                onChange: viewModel.parameterDidChange,
                onEditingChanged: viewModel.parameterEditingChanged
            )
            ParameterFloatSlider(
                range: ParameterRanges.alphaGamma,
                value: $viewModel.state.alphaGamma,
                onChange: viewModel.parameterDidChange,
                onEditingChanged: viewModel.parameterEditingChanged
            )
            ParameterToggle(
                title: ParameterRanges.autoDespeckleName,
                isOn: $viewModel.state.autoDespeckleEnabled,
                defaultValue: ParameterRanges.Defaults.autoDespeckleEnabled,
                onChange: viewModel.parameterDidChange
            )
            ParameterIntSlider(
                range: ParameterRanges.despeckleSize,
                value: $viewModel.state.despeckleSize,
                onChange: viewModel.parameterDidChange,
                onEditingChanged: viewModel.parameterEditingChanged
            )
            .disabled(!viewModel.state.autoDespeckleEnabled)
            ParameterFloatSlider(
                range: ParameterRanges.refinerStrength,
                value: $viewModel.state.refinerStrength,
                onChange: viewModel.parameterDidChange,
                onEditingChanged: viewModel.parameterEditingChanged
            )
        }
    }
}

private struct EdgeAndSpillGroup: View {
    @Bindable var viewModel: EditorViewModel

    var body: some View {
        InspectorGroup(title: "Edge & Spill") {
            ParameterFloatSlider(
                range: ParameterRanges.despillStrength,
                value: $viewModel.state.despillStrength,
                onChange: viewModel.parameterDidChange,
                onEditingChanged: viewModel.parameterEditingChanged
            )
            EnumPicker(
                title: ParameterRanges.spillMethodName,
                selection: $viewModel.state.spillMethod,
                defaultValue: ParameterRanges.Defaults.spillMethod,
                onChange: viewModel.parameterDidChange
            )
        }
    }
}

private struct EdgeRefinementGroup: View {
    @Bindable var viewModel: EditorViewModel

    var body: some View {
        InspectorGroup(title: "Edge Refinement") {
            ParameterToggle(
                title: ParameterRanges.lightWrapName,
                isOn: $viewModel.state.lightWrapEnabled,
                defaultValue: ParameterRanges.Defaults.lightWrapEnabled,
                onChange: viewModel.parameterDidChange
            )
            ParameterFloatSlider(
                range: ParameterRanges.lightWrapStrength,
                value: $viewModel.state.lightWrapStrength,
                onChange: viewModel.parameterDidChange,
                onEditingChanged: viewModel.parameterEditingChanged
            )
            .disabled(!viewModel.state.lightWrapEnabled)
            ParameterFloatSlider(
                range: ParameterRanges.lightWrapRadius,
                value: $viewModel.state.lightWrapRadius,
                onChange: viewModel.parameterDidChange,
                onEditingChanged: viewModel.parameterEditingChanged
            )
            .disabled(!viewModel.state.lightWrapEnabled)

            ParameterToggle(
                title: ParameterRanges.edgeDecontaminateName,
                isOn: $viewModel.state.edgeDecontaminateEnabled,
                defaultValue: ParameterRanges.Defaults.edgeDecontaminateEnabled,
                onChange: viewModel.parameterDidChange
            )
            ParameterFloatSlider(
                range: ParameterRanges.edgeDecontaminateStrength,
                value: $viewModel.state.edgeDecontaminateStrength,
                onChange: viewModel.parameterDidChange,
                onEditingChanged: viewModel.parameterEditingChanged
            )
            .disabled(!viewModel.state.edgeDecontaminateEnabled)
        }
    }
}

private struct TemporalStabilityGroup: View {
    @Bindable var viewModel: EditorViewModel

    var body: some View {
        InspectorGroup(title: "Temporal Stability") {
            Text("Optional smoothing after the v2 key. It can soften detail or leave trails on moving edges. Start with it off. Try Time Awareness first for flicker.")
                .font(.caption).foregroundStyle(.secondary)
            ParameterToggle(
                title: ParameterRanges.temporalStabilityName,
                isOn: $viewModel.state.temporalStabilityEnabled,
                defaultValue: ParameterRanges.Defaults.temporalStabilityEnabled,
                onChange: viewModel.parameterDidChange
            )
            ParameterFloatSlider(
                range: ParameterRanges.temporalStabilityStrength,
                value: $viewModel.state.temporalStabilityStrength,
                onChange: viewModel.parameterDidChange,
                onEditingChanged: viewModel.parameterEditingChanged
            )
            .disabled(!viewModel.state.temporalStabilityEnabled)
        }
    }
}

// MARK: - Reusable controls

/// Visual wrapper around an inspector group: the Final Cut Pro
/// inspector uses subtle dividers and bold section headers; we mirror
/// that here with a `DisclosureGroup`-style affordance.
struct InspectorGroup<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
            content
        }
        .padding(.bottom, 4)
    }
}

struct ParameterFloatSlider: View {
    let range: FloatParameterRange
    @Binding var value: Double
    var onChange: () -> Void = {}
    var onEditingChanged: (Bool) -> Void = { _ in }

    /// True when the current value sits within half a step of the
    /// factory default. Used to show / hide the reset affordance — a
    /// "Reset to Default" button on a parameter that's already at its
    /// default would be visual noise.
    private var isAtDefault: Bool {
        abs(value - range.defaultValue) < (range.step / 2)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(range.name)
                    .font(.callout)
                Spacer()
                TextField(range.name, value: Binding(
                    get: { value },
                    set: { candidate in
                        guard candidate.isFinite else { return }
                        value = min(range.parameterMax, max(range.parameterMin, candidate))
                    }
                ), format: .number.precision(.fractionLength(0...2)))
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.plain)
                    .accessibilityLabel(range.name)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                ResetToDefaultButton(
                    isVisible: !isAtDefault,
                    helpText: "Reset \(range.name) to \(formatDefault(range.defaultValue))"
                ) {
                    value = range.defaultValue
                    onChange()
                }
            }
            Slider(
                value: Binding(
                    get: { min(range.sliderMax, max(range.sliderMin, value)) },
                    set: { value = $0 }
                ),
                in: range.sliderMin...range.sliderMax,
                step: range.step,
                onEditingChanged: onEditingChanged
            )
            .onChange(of: value) {
                onChange()
            }
        }
    }

    private func formatDefault(_ defaultValue: Double) -> String {
        defaultValue.formatted(.number.precision(.fractionLength(2)))
    }
}

struct ParameterIntSlider: View {
    let range: IntParameterRange
    @Binding var value: Int
    var onChange: () -> Void = {}
    var onEditingChanged: (Bool) -> Void = { _ in }

    private var isAtDefault: Bool { value == range.defaultValue }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(range.name)
                    .font(.callout)
                Spacer()
                TextField(range.name, value: Binding(
                    get: { value },
                    set: { value = min(range.parameterMax, max(range.parameterMin, $0)) }
                ), format: .number)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.plain)
                    .accessibilityLabel(range.name)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                ResetToDefaultButton(
                    isVisible: !isAtDefault,
                    helpText: "Reset \(range.name) to \(range.defaultValue)"
                ) {
                    value = range.defaultValue
                    onChange()
                }
            }
            Group {
                if range.sliderMin < range.sliderMax {
                    Slider(
                        value: Binding(
                            get: { Double(min(range.sliderMax, max(range.sliderMin, value))) },
                            set: { value = Int($0.rounded()) }
                        ),
                        in: Double(range.sliderMin)...Double(range.sliderMax),
                        step: Double(range.step),
                        onEditingChanged: onEditingChanged
                    )
                } else {
                    // A stepped Slider traps on a zero-width range, even when
                    // disabled. Keep an inert track for empty/single-frame media
                    // without expanding the parameter's valid frame range.
                    Slider(value: .constant(0), in: 0...1)
                        .disabled(true)
                }
            }
            .onChange(of: value) {
                onChange()
            }
        }
    }
}

struct ParameterToggle: View {
    let title: String
    @Binding var isOn: Bool
    let defaultValue: Bool
    var onChange: () -> Void = {}

    var body: some View {
        HStack {
            Toggle(title, isOn: $isOn)
                .onChange(of: isOn) {
                    onChange()
                }
            ResetToDefaultButton(
                isVisible: isOn != defaultValue,
                helpText: "Reset \(title) to \(defaultValue ? "On" : "Off")"
            ) {
                isOn = defaultValue
                onChange()
            }
        }
    }
}

/// Generic enum picker. Works on any `RawRepresentable` enum that is
/// `CaseIterable` and exposes a `displayName: String`. Used for every
/// popup parameter.
struct EnumPicker<EnumType: CaseIterable & Identifiable & Hashable>: View
    where EnumType.AllCases: RandomAccessCollection {

    let title: String
    @Binding var selection: EnumType
    let defaultValue: EnumType
    var onChange: () -> Void = {}

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.callout)
            Spacer()
            Picker(title, selection: $selection) {
                ForEach(Array(EnumType.allCases)) { option in
                    Text(displayName(for: option))
                        .tag(option)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 180, alignment: .trailing)
            .onChange(of: selection) {
                onChange()
            }
            ResetToDefaultButton(
                isVisible: selection != defaultValue,
                helpText: "Reset \(title) to \(displayName(for: defaultValue))"
            ) {
                selection = defaultValue
                onChange()
            }
        }
    }

    private func displayName(for option: EnumType) -> String {
        if let displayable = option as? any DisplayNamed {
            return displayable.displayName
        }
        return String(describing: option)
    }
}

/// Inline circular-arrow button that resets a single parameter to its
/// factory default. Hidden via `.opacity(0)` rather than removed from
/// the layout so the row's `HStack` doesn't reflow when a value is
/// nudged off-default — the arrow just fades in next to the value
/// readout. Sized down to `.mini` so it doesn't crowd the slider rail.
private struct ResetToDefaultButton: View {
    let isVisible: Bool
    let helpText: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.counterclockwise")
                .imageScale(.small)
        }
        .buttonStyle(.borderless)
        .controlSize(.mini)
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .help(helpText)
        .accessibilityLabel(isVisible ? helpText : "")
        .accessibilityHidden(!isVisible)
    }
}

/// Marker protocol so `EnumPicker` can pull a localised display name
/// from any of our parameter enums without having to special-case them
/// individually. Each enum gets a one-line conformance below.
protocol DisplayNamed {
    var displayName: String { get }
}

extension ScreenColor: DisplayNamed, Identifiable { public var id: Int { rawValue } }
extension QualityMode: DisplayNamed, Identifiable { public var id: Int { rawValue } }
extension OutputMode: DisplayNamed, Identifiable { public var id: Int { rawValue } }
extension SpillMethod: DisplayNamed, Identifiable { public var id: Int { rawValue } }
extension UpscaleMethod: DisplayNamed, Identifiable { public var id: Int { rawValue } }
extension HintMode: DisplayNamed, Identifiable { public var id: Int { rawValue } }
extension TimeAwareness: DisplayNamed, Identifiable { public var id: Int { rawValue } }
extension AlphaHintFrames: DisplayNamed, Identifiable { public var id: Int { rawValue } }

/// Formats an elapsed duration in seconds as a human-readable string
/// for the analysis-completed badge. Replaces the earlier "187.7 s"
/// rendering with phrases like "3 minutes and 8 seconds" — easier to
/// scan when the user comes back to a clip and wants to know how
/// long the analysis pass took.
enum AnalysisDurationFormatter {
    static func format(seconds: Double) -> String {
        let totalSeconds = max(Int(seconds.rounded()), 0)
        if totalSeconds < 60 {
            return "\(totalSeconds) \(totalSeconds == 1 ? "second" : "seconds")"
        }
        let minutes = totalSeconds / 60
        let remainder = totalSeconds % 60
        let minutesText = "\(minutes) \(minutes == 1 ? "minute" : "minutes")"
        if remainder == 0 {
            return minutesText
        }
        let secondsText = "\(remainder) \(remainder == 1 ? "second" : "seconds")"
        return "\(minutesText) and \(secondsText)"
    }
}
