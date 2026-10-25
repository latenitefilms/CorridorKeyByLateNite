//
//  CorridorKeyToolboxPlugIn+Parameters.swift
//  CorridorKey by LateNite
//
//  Defines the entire inspector layout for the plug-in. Analyse / Reset /
//  version live in the custom-UI header at the top, then the sliders match
//  the CorridorKey OFX panel so editors moving between Resolve and Final
//  Cut Pro stay oriented. Enum and toggle controls are explicitly marked
//  non-animatable — animating "Screen Colour" or "Output" flashes between
//  unrelated looks and pollutes the curve editor.
//

import Foundation
import AppKit
import CoreMedia

extension CorridorKeyToolboxPlugIn {

    /// Registers every control FxPlug should draw in Final Cut Pro's inspector.
    /// Called once by FxPlug for each new instance.
    @objc(addParametersWithError:)
    func addParameters() throws {
        guard let create = apiManager.api(for: (any FxParameterCreationAPI_v5).self) as? any FxParameterCreationAPI_v5 else {
            throw NSError(
                domain: FxPlugErrorDomain,
                code: kFxError_APIUnavailable,
                userInfo: [NSLocalizedDescriptionKey: "CorridorKey by LateNite could not attach to the FxPlug parameter API."]
            )
        }

        try addHeaderParameter(create: create)
        try addSettingsGroup(create: create)
        addVideoGroups(create: create)
        try addInteriorDetailGroup(create: create)
        try addMatteGroup(create: create)
        try addEdgeAndSpillGroup(create: create)
        try addEdgeRefinementGroup(create: create)
        try addTemporalStabilityGroup(create: create)
        PluginLog.notice("Parameters registered with Final Cut Pro.")
    }

    // MARK: - Custom parameter serialisation

    /// Tells FxPlug which Foundation classes may appear inside our header
    /// custom parameter so the host can safely decode it through
    /// `NSSecureCoding`. The analysis dictionary is a tree of Foundation
    /// dictionary / string / number / data nodes. Mutable variants are
    /// whitelisted because the host may hand mutable Foundation containers
    /// back even when we write immutable values.
    @objc(classesForCustomParameterID:)
    func classes(forCustomParameterID parameterID: UInt32) -> Set<AnyHashable> {
        switch parameterID {
        case ParameterIdentifier.headerSummary:
            let classes: [AnyClass] = [
                NSDictionary.self,
                NSMutableDictionary.self,
                NSString.self,
                NSNumber.self,
                NSData.self,
                NSMutableData.self
            ]
            let set = NSSet(array: classes)
            return (set as? Set<AnyHashable>) ?? []
        default:
            return []
        }
    }

    // MARK: - Inspector header + hidden cache

    /// Custom-UI placeholder that `createViewForParameterID` swaps for the
    /// SwiftUI header (icon, version, Analyse / Reset buttons, status).
    private func addHeaderParameter(create: any FxParameterCreationAPI_v5) throws {
        create.addCustomParameter(
            withName: "",
            parameterID: ParameterIdentifier.headerSummary,
            defaultValue: NSDictionary(),
            parameterFlags: CorridorKeyParameterFlags.headerCustomUI.fxFlags
        )
    }

    // MARK: - Visible groups


    /// V2 controls use one set of labels and defaults in both hosts.
    private func addVideoGroups(create: any FxParameterCreationAPI_v5) {
        let defaults = VideoInferenceSettings()
        let flags = CorridorKeyParameterFlags.nonAnimatableChoice.fxFlags
        create.startParameterSubGroup("Time Awareness", parameterID: ParameterIdentifier.timeAwarenessGroup, parameterFlags: CorridorKeyParameterFlags.default.fxFlags)
        create.addPopupMenu(withName: VideoInferenceSettings.Labels.timeAwareness, parameterID: ParameterIdentifier.timeAwareness, defaultValue: UInt32(defaults.timeAwareness.rawValue), menuEntries: TimeAwareness.allCases.map(\.displayName), parameterFlags: flags)
        create.addToggleButton(withName: VideoInferenceSettings.Labels.lowGPUMemory, parameterID: ParameterIdentifier.lowGPUMemory, defaultValue: defaults.lowGPUMemory, parameterFlags: flags)
        create.endParameterSubGroup()
        create.startParameterSubGroup("Alpha Hint", parameterID: ParameterIdentifier.alphaHintGroup, parameterFlags: CorridorKeyParameterFlags.default.fxFlags)
        create.addToggleButton(withName: VideoInferenceSettings.Labels.useAlphaHint, parameterID: ParameterIdentifier.useAlphaHint, defaultValue: defaults.useAlphaHint, parameterFlags: flags)
        create.addPopupMenu(withName: VideoInferenceSettings.Labels.hintFrames, parameterID: ParameterIdentifier.hintFrames, defaultValue: UInt32(defaults.hintFrames.rawValue), menuEntries: AlphaHintFrames.allCases.map(\.displayName), parameterFlags: flags)
        create.addIntSlider(withName: VideoInferenceSettings.Labels.referenceFrame, parameterID: ParameterIdentifier.referenceFrame, defaultValue: 0, parameterMin: 0, parameterMax: Int32.max, sliderMin: 0, sliderMax: 1000, delta: 1, parameterFlags: flags)
        create.addFloatSlider(withName: VideoInferenceSettings.Labels.alphaHintStrength, parameterID: ParameterIdentifier.alphaHintStrength, defaultValue: defaults.alphaHintStrength, parameterMin: 0, parameterMax: 1, sliderMin: 0, sliderMax: 1, delta: 0.01, parameterFlags: flags)
        create.addFloatSlider(withName: VideoInferenceSettings.Labels.internalHintStrength, parameterID: ParameterIdentifier.internalHintStrength, defaultValue: defaults.internalHintStrength, parameterMin: 0, parameterMax: 1, sliderMin: 0, sliderMax: 1, delta: 0.01, parameterFlags: flags)
        create.endParameterSubGroup()
    }

    private func addSettingsGroup(create: any FxParameterCreationAPI_v5) throws {
        create.startParameterSubGroup(
            "Settings",
            parameterID: ParameterIdentifier.settingsGroup,
            parameterFlags: CorridorKeyParameterFlags.default.fxFlags
        )

        create.addPopupMenu(
            withName: "Quality",
            parameterID: ParameterIdentifier.qualityMode,
            defaultValue: UInt32(QualityMode.automatic.rawValue),
            menuEntries: QualityMode.allCases.map(\.displayName),
            parameterFlags: CorridorKeyParameterFlags.nonAnimatableChoice.fxFlags
        )

        create.addPopupMenu(
            withName: "Screen Colour",
            parameterID: ParameterIdentifier.screenColor,
            defaultValue: UInt32(ScreenColor.automatic.rawValue),
            menuEntries: ScreenColor.allCases.map(\.displayName),
            parameterFlags: CorridorKeyParameterFlags.nonAnimatableChoice.fxFlags
        )
        create.addColorParameter(withName: "Custom Screen Colour", parameterID: ParameterIdentifier.customScreenColor,
            defaultRed: 0.08, defaultGreen: 0.84, defaultBlue: 0.08,
            parameterFlags: CorridorKeyParameterFlags.nonAnimatableChoice.fxFlags)


        create.addPopupMenu(
            withName: "Upscale Method",
            parameterID: ParameterIdentifier.upscaleMethod,
            defaultValue: UInt32(UpscaleMethod.lanczos.rawValue),
            menuEntries: UpscaleMethod.allCases.map(\.displayName),
            parameterFlags: CorridorKeyParameterFlags.nonAnimatableChoice.fxFlags
        )

        create.addPopupMenu(
            withName: "Output",
            parameterID: ParameterIdentifier.outputMode,
            defaultValue: UInt32(OutputMode.processed.rawValue),
            menuEntries: OutputMode.allCases.map(\.displayName),
            parameterFlags: CorridorKeyParameterFlags.nonAnimatableChoice.fxFlags
        )

        // Generated guidance is optional; the v2 model can key without it.
        create.addPopupMenu(
            withName: HintMode.controlName,
            parameterID: ParameterIdentifier.hintMode,
            defaultValue: UInt32(PluginStateData().hintMode.rawValue),
            menuEntries: HintMode.allCases.map(\.displayName),
            parameterFlags: CorridorKeyParameterFlags.nonAnimatableChoice.fxFlags
        )

        create.addToggleButton(withName: VideoInferenceSettings.Labels.inputIsLinear, parameterID: ParameterIdentifier.inputIsLinear, defaultValue: VideoInferenceSettings().inputIsLinear, parameterFlags: CorridorKeyParameterFlags.nonAnimatableChoice.fxFlags)
        create.addToggleButton(withName: VideoInferenceSettings.Labels.linearizeOutput, parameterID: ParameterIdentifier.linearizeOutput, defaultValue: VideoInferenceSettings().linearizeOutput, parameterFlags: CorridorKeyParameterFlags.nonAnimatableChoice.fxFlags)
        create.addToggleButton(withName: VideoInferenceSettings.Labels.keepOriginalInSolidAreas, parameterID: ParameterIdentifier.keepOriginalInSolidAreas, defaultValue: VideoInferenceSettings().keepOriginalInSolidAreas, parameterFlags: CorridorKeyParameterFlags.nonAnimatableChoice.fxFlags)

        // Subject Marker: a draggable on-screen point that lets the
        // user mark the centre of the foreground subject. Provides
        // both a clear OSC affordance (the user can see where the
        // marker is and drag it) and a stable Point parameter that
        // FCP wires the OSC to natively. Defaults to centre (0.5,
        // 0.5) in object-normalised coords. Hidden by default so
        // the marker only appears when the user explicitly asks for
        // the draggable on-canvas affordance.
        create.addToggleButton(
            withName: "Show Subject Marker",
            parameterID: ParameterIdentifier.showSubjectMarker,
            defaultValue: false,
            parameterFlags: CorridorKeyParameterFlags.nonAnimatableChoice.fxFlags
        )
        create.addPointParameter(
            withName: "Subject Position",
            parameterID: ParameterIdentifier.subjectPosition,
            defaultX: 0.5,
            defaultY: 0.5,
            parameterFlags: CorridorKeyParameterFlags.default.fxFlags
        )

        create.endParameterSubGroup()
    }

    private func addInteriorDetailGroup(create: any FxParameterCreationAPI_v5) throws {
        create.startParameterSubGroup(
            "Interior Detail",
            parameterID: ParameterIdentifier.interiorGroup,
            parameterFlags: CorridorKeyParameterFlags.default.fxFlags
        )

        create.addToggleButton(
            withName: "Source Passthrough",
            parameterID: ParameterIdentifier.sourcePassthrough,
            defaultValue: false,
            parameterFlags: CorridorKeyParameterFlags.nonAnimatableChoice.fxFlags
        )

        create.addFloatSlider(
            withName: "Edge Erode",
            parameterID: ParameterIdentifier.passthroughErode,
            defaultValue: 3,
            parameterMin: 0,
            parameterMax: 100,
            sliderMin: 0,
            sliderMax: 40,
            delta: 1,
            parameterFlags: CorridorKeyParameterFlags.default.fxFlags
        )

        create.addFloatSlider(
            withName: "Edge Blur",
            parameterID: ParameterIdentifier.passthroughBlur,
            defaultValue: 7,
            parameterMin: 0,
            parameterMax: 100,
            sliderMin: 0,
            sliderMax: 40,
            delta: 1,
            parameterFlags: CorridorKeyParameterFlags.default.fxFlags
        )

        create.endParameterSubGroup()
    }

    private func addMatteGroup(create: any FxParameterCreationAPI_v5) throws {
        create.startParameterSubGroup(
            "Matte",
            parameterID: ParameterIdentifier.matteGroup,
            parameterFlags: CorridorKeyParameterFlags.default.fxFlags
        )

        create.addFloatSlider(
            withName: "Black Point",
            parameterID: ParameterIdentifier.alphaBlackPoint,
            defaultValue: 0,
            parameterMin: 0,
            parameterMax: 1,
            sliderMin: 0,
            sliderMax: 1,
            delta: 0.01,
            parameterFlags: CorridorKeyParameterFlags.default.fxFlags
        )

        create.addFloatSlider(
            withName: "White Point",
            parameterID: ParameterIdentifier.alphaWhitePoint,
            defaultValue: 1,
            parameterMin: 0,
            parameterMax: 1,
            sliderMin: 0,
            sliderMax: 1,
            delta: 0.01,
            parameterFlags: CorridorKeyParameterFlags.default.fxFlags
        )

        create.addFloatSlider(
            withName: "Matte Erode",
            parameterID: ParameterIdentifier.alphaErode,
            defaultValue: 0,
            parameterMin: -10,
            parameterMax: 10,
            sliderMin: -10,
            sliderMax: 10,
            delta: 0.1,
            parameterFlags: CorridorKeyParameterFlags.default.fxFlags
        )

        create.addFloatSlider(
            withName: "Softness",
            parameterID: ParameterIdentifier.alphaSoftness,
            defaultValue: 0,
            parameterMin: 0,
            parameterMax: 5,
            sliderMin: 0,
            sliderMax: 5,
            delta: 0.1,
            parameterFlags: CorridorKeyParameterFlags.default.fxFlags
        )

        create.addFloatSlider(
            withName: "Gamma",
            parameterID: ParameterIdentifier.alphaGamma,
            defaultValue: 1,
            parameterMin: 0.1,
            parameterMax: 10,
            sliderMin: 0.1,
            sliderMax: 4,
            delta: 0.05,
            parameterFlags: CorridorKeyParameterFlags.default.fxFlags
        )

        // Connected-component cleanup is opt-in; small foreground details
        // can otherwise be mistaken for isolated background specks.
        create.addToggleButton(
            withName: "Auto Despeckle",
            parameterID: ParameterIdentifier.autoDespeckle,
            defaultValue: PluginStateData().autoDespeckleEnabled,
            parameterFlags: CorridorKeyParameterFlags.nonAnimatableChoice.fxFlags
        )

        create.addIntSlider(
            withName: "Despeckle Size",
            parameterID: ParameterIdentifier.despeckleSize,
            defaultValue: 100,
            parameterMin: 5,
            parameterMax: 2000,
            sliderMin: 5,
            sliderMax: 1000,
            delta: 5,
            parameterFlags: CorridorKeyParameterFlags.nonAnimatableChoice.fxFlags
        )

        create.addFloatSlider(
            withName: "Refiner Strength",
            parameterID: ParameterIdentifier.refinerStrength,
            defaultValue: 1.0,
            parameterMin: 0,
            parameterMax: 2,
            sliderMin: 0,
            sliderMax: 2,
            delta: 0.05,
            parameterFlags: CorridorKeyParameterFlags.default.fxFlags
        )

        create.endParameterSubGroup()
    }

    private func addEdgeAndSpillGroup(create: any FxParameterCreationAPI_v5) throws {
        create.startParameterSubGroup(
            "Edge & Spill",
            parameterID: ParameterIdentifier.edgeSpillGroup,
            parameterFlags: CorridorKeyParameterFlags.default.fxFlags
        )

        // Strength starts at zero, matching the v2 manual. The method
        // defaults to Ultra (Chroma Project) — its YCbCr-projection
        // path removes the soft chroma fringe the older Average /
        // Double Limit kernels leave on hair and feathered edges,
        // without the over-bright mids Screen Subtract introduces
        // on translucent fabric. Average / Double Limit / Neutral /
        // Screen Subtract remain in the popup for users whose
        // footage responds better to the legacy approaches.
        // Despill Strength runs 0–5 so users can push past full
        // model-trained cleanup on problem shots (heavy chroma
        // reflection on hair, dense motion-blur edges). The default
        // stays at 0.5 so existing libraries open identically; only
        // users who pull the slider above 1 get the aggressive over-
        // correction. Above 1 the new spill-alpha attenuation kernel
        // also pulls the matte's alpha toward zero in spill regions,
        // so over-pushed colour ends up hidden behind transparency
        // rather than showing as a garish anti-screen tint.
        create.addFloatSlider(
            withName: "Despill Strength",
            parameterID: ParameterIdentifier.despillStrength,
            defaultValue: 0,
            parameterMin: 0,
            parameterMax: 5,
            sliderMin: 0,
            sliderMax: 5,
            delta: 0.01,
            parameterFlags: CorridorKeyParameterFlags.default.fxFlags
        )

        create.addPopupMenu(
            withName: "Spill Method",
            parameterID: ParameterIdentifier.spillMethod,
            defaultValue: UInt32(SpillMethod.ultra.rawValue),
            menuEntries: SpillMethod.allCases.map(\.displayName),
            parameterFlags: CorridorKeyParameterFlags.nonAnimatableChoice.fxFlags
        )

        create.endParameterSubGroup()
    }

    /// Phase 4 additions: light wrap and edge colour decontamination.
    /// Both default to enabled in v1.0 so a fresh effect produces a
    /// comp-ready edge — wrap inherits a touch of background colour
    /// to kill the pasted-on look, decontaminate kills the residual
    /// chroma fringe along feathered edges. Saved projects from
    /// builds before v1.0 keep their stored values via
    /// `PluginStateData`'s `decodeIfPresent` defaults so loading an
    /// old library doesn't silently flip the look.
    private func addEdgeRefinementGroup(create: any FxParameterCreationAPI_v5) throws {
        create.startParameterSubGroup(
            "Edge Refinement",
            parameterID: ParameterIdentifier.edgeRefinementGroup,
            parameterFlags: CorridorKeyParameterFlags.default.fxFlags
        )

        create.addToggleButton(
            withName: "Light Wrap",
            parameterID: ParameterIdentifier.lightWrapEnabled,
            defaultValue: PluginStateData().lightWrapEnabled,
            parameterFlags: CorridorKeyParameterFlags.nonAnimatableChoice.fxFlags
        )

        create.addFloatSlider(
            withName: "Wrap Strength",
            parameterID: ParameterIdentifier.lightWrapStrength,
            defaultValue: 0.25,
            parameterMin: 0,
            parameterMax: 1,
            sliderMin: 0,
            sliderMax: 1,
            delta: 0.01,
            parameterFlags: CorridorKeyParameterFlags.default.fxFlags
        )

        create.addFloatSlider(
            withName: "Wrap Radius",
            parameterID: ParameterIdentifier.lightWrapRadius,
            defaultValue: 10,
            parameterMin: 0,
            parameterMax: 50,
            sliderMin: 0,
            sliderMax: 50,
            delta: 0.5,
            parameterFlags: CorridorKeyParameterFlags.default.fxFlags
        )

        create.addToggleButton(
            withName: "Edge Decontaminate",
            parameterID: ParameterIdentifier.edgeDecontaminateEnabled,
            defaultValue: false,
            parameterFlags: CorridorKeyParameterFlags.nonAnimatableChoice.fxFlags
        )

        create.addFloatSlider(
            withName: "Decontam. Strength",
            parameterID: ParameterIdentifier.edgeDecontaminateStrength,
            defaultValue: 0.5,
            parameterMin: 0,
            parameterMax: 1,
            sliderMin: 0,
            sliderMax: 1,
            delta: 0.01,
            parameterFlags: CorridorKeyParameterFlags.default.fxFlags
        )

        create.endParameterSubGroup()
    }

    /// Optional motion-gated blend, baked into analysis. Off by default to
    /// preserve v2 detail and avoid trails where the motion gate misses an edge.
    private func addTemporalStabilityGroup(create: any FxParameterCreationAPI_v5) throws {
        create.startParameterSubGroup(
            "Temporal Stability",
            parameterID: ParameterIdentifier.temporalStabilityGroup,
            parameterFlags: CorridorKeyParameterFlags.default.fxFlags
        )

        create.addToggleButton(
            withName: "Reduce Edge Flicker",
            parameterID: ParameterIdentifier.temporalStabilityEnabled,
            defaultValue: PluginStateData().temporalStabilityEnabled,
            parameterFlags: CorridorKeyParameterFlags.nonAnimatableChoice.fxFlags
        )

        create.addFloatSlider(
            withName: "Stability Strength",
            parameterID: ParameterIdentifier.temporalStabilityStrength,
            defaultValue: 0.5,
            parameterMin: 0,
            parameterMax: 1,
            sliderMin: 0,
            sliderMax: 1,
            delta: 0.01,
            parameterFlags: CorridorKeyParameterFlags.default.fxFlags
        )

        create.endParameterSubGroup()
    }

    // MARK: - Parameter change notifications

    /// Final Cut Pro invokes this method when the user edits a control. We
    /// use it to keep the inspector UI consistent — when the user toggles
    /// Light Wrap or Edge Decontaminate off, the sub-sliders get disabled
    /// so the panel clearly communicates which knobs are live.
    @objc(parameterChanged:atTime:error:)
    func parameterChanged(_ paramID: UInt32, atTime time: CMTime) throws {
        updateDependentParameterEnablement(at: time)
    }

    /// Reads each Phase 4 toggle and disables / enables its sub-sliders
    /// accordingly. Safe to call any time; no-ops when the parameter APIs
    /// aren't available (e.g. during initial add-parameters).
    private func updateDependentParameterEnablement(at time: CMTime) {
        guard
            let retrieval = apiManager.api(for: (any FxParameterRetrievalAPI_v6).self) as? any FxParameterRetrievalAPI_v6,
            let setter = apiManager.api(for: (any FxParameterSettingAPI_v5).self) as? any FxParameterSettingAPI_v5
        else { return }

        // Missing host values use the same defaults as the editor and template.
        let lightWrapOn = readBool(retrieval: retrieval, parameterID: ParameterIdentifier.lightWrapEnabled, at: time, default: PluginStateData().lightWrapEnabled)
        let decontamOn = readBool(retrieval: retrieval, parameterID: ParameterIdentifier.edgeDecontaminateEnabled, at: time, default: false)
        let temporalOn = readBool(retrieval: retrieval, parameterID: ParameterIdentifier.temporalStabilityEnabled, at: time, default: PluginStateData().temporalStabilityEnabled)

        setEnabled(setter: setter, parameterID: ParameterIdentifier.lightWrapStrength, enabled: lightWrapOn)
        setEnabled(setter: setter, parameterID: ParameterIdentifier.lightWrapRadius, enabled: lightWrapOn)
        setEnabled(setter: setter, parameterID: ParameterIdentifier.edgeDecontaminateStrength, enabled: decontamOn)
        setEnabled(setter: setter, parameterID: ParameterIdentifier.temporalStabilityStrength, enabled: temporalOn)
    }

    private func readBool(
        retrieval: any FxParameterRetrievalAPI_v6,
        parameterID: UInt32,
        at time: CMTime,
        default defaultValue: Bool
    ) -> Bool {
        var value = ObjCBool(defaultValue)
        retrieval.getBoolValue(&value, fromParameter: parameterID, at: time)
        return value.boolValue
    }

    private func setEnabled(
        setter: any FxParameterSettingAPI_v5,
        parameterID: UInt32,
        enabled: Bool
    ) {
        let flags: CorridorKeyParameterFlags = enabled ? .default : [.default, .disabled]
        _ = setter.setParameterFlags(flags.fxFlags, toParameter: parameterID)
    }
}
