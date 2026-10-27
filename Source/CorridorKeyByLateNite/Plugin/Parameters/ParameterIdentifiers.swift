//
//  ParameterIdentifiers.swift
//  CorridorKey by LateNite
//
//  Every parameter surfaced to Final Cut Pro has a stable numeric identifier.
//  FxPlug requires identifiers to stay in the range 1...9998 for the lifetime
//  of the plug-in — renaming is fine but renumbering will strand user
//  documents, so new parameters must always be appended with a fresh id.
//

import Foundation

enum ParameterIdentifier {
    /// Custom-UI parameter that hosts the app icon and version. Drawn as a SwiftUI
    /// `NSHostingView` returned from `createViewForParameterID`. The Motion
    /// Template publishes this parameter, so it also owns the nested
    /// persistence dictionary for analysis data and subject points.
    static let headerSummary: UInt32 = 50

    /// Presentation-only row inside Alpha Hint. Persisted assets remain on
    /// headerSummary so existing libraries keep their selections.
    static let alphaHintControls: UInt32 = 9012

    /// Presentation-only analysis actions. Saved analysis and hints
    /// stay on headerSummary so existing libraries retain their data.
    static let analysisControls: UInt32 = 9013

    /// Presentation-only diagnostics. Analysis remains persisted on headerSummary.
    static let analysisDetails: UInt32 = 9014

    /// Subject tools and per-frame guidance in the Manual Hint section.
    static let manualHintControls: UInt32 = 9015

    // Subgroups
    static let settingsGroup: UInt32 = 100
    static let interiorGroup: UInt32 = 110
    static let matteGroup: UInt32 = 120
    static let edgeSpillGroup: UInt32 = 130
    static let edgeRefinementGroup: UInt32 = 140
    static let temporalStabilityGroup: UInt32 = 150
    static let timeAwarenessGroup: UInt32 = 160
    static let alphaHintGroup: UInt32 = 170
    static let controlsGroup: UInt32 = 180
    static let analysisDetailsGroup: UInt32 = 190
    static let manualHintGroup: UInt32 = 200

    // V2 additions. Existing identifiers are never renumbered.
    static let inputIsLinear: UInt32 = 9001
    static let linearizeOutput: UInt32 = 9002
    static let keepOriginalInSolidAreas: UInt32 = 9003
    static let timeAwareness: UInt32 = 9004
    static let lowGPUMemory: UInt32 = 9005
    static let useAlphaHint: UInt32 = 9006
    static let hintFrames: UInt32 = 9007
    static let referenceFrame: UInt32 = 9008
    static let alphaHintStrength: UInt32 = 9009
    static let internalHintStrength: UInt32 = 9010

    // Settings
    static let customScreenColor: UInt32 = 9011
    static let screenColor: UInt32 = 1001
    static let qualityMode: UInt32 = 1002

    /// Picks how the upstream alpha hint is generated. The user
    /// picks one of three modes (Automatic / Apple Vision / Manual)
    /// — see `HintMode` for the per-case behaviour.
    static let hintMode: UInt32 = 1007

    // Interior Detail
    static let sourcePassthrough: UInt32 = 2001
    static let passthroughErode: UInt32 = 2002
    static let passthroughBlur: UInt32 = 2003

    // Matte refinement
    static let alphaBlackPoint: UInt32 = 3001
    static let alphaWhitePoint: UInt32 = 3002
    static let alphaErode: UInt32 = 3003
    static let alphaSoftness: UInt32 = 3004
    static let alphaGamma: UInt32 = 3005
    static let autoDespeckle: UInt32 = 3006
    static let despeckleSize: UInt32 = 3007
    
    /// Refiner strength — blends the neural refined alpha with a blurred
    /// "coarse" stand-in. 1.0 = model refined pass-through; <1.0 softens;
    /// >1.0 extrapolates toward harder edges (clamped).
    static let refinerStrength: UInt32 = 3008

    // Edge and spill
    static let despillStrength: UInt32 = 4001
    static let spillMethod: UInt32 = 4002

    // Output (lives in the Settings group)
    static let outputMode: UInt32 = 5001

    // Performance (also in the Settings group)
    static let upscaleMethod: UInt32 = 6002

    // Edge refinement (Phase 4 additions — light wrap + edge decontamination).
    static let lightWrapEnabled: UInt32 = 8001
    static let lightWrapStrength: UInt32 = 8002
    static let lightWrapRadius: UInt32 = 8003
    static let edgeDecontaminateEnabled: UInt32 = 8004
    static let edgeDecontaminateStrength: UInt32 = 8005

    /// Temporal stability (Phase 1 — alpha EMA with motion gating). Runs
    /// during the Analyse Clip pass and replaces each frame's matte with a
    /// weighted blend against the previous frame's matte on pixels whose
    /// source RGB has barely changed. Reduces edge flicker without
    /// smearing real motion.
    static let temporalStabilityEnabled: UInt32 = 8006
    static let temporalStabilityStrength: UInt32 = 8007
}

enum HeaderStorageKey {
    static let schemaVersion = "schemaVersion"
    static let analysisData = "analysisData"
    static let subjectPoints = "subjectPoints"
    static let alphaHintAsset = "alphaHintAsset"
    static let subjectTool = "subjectTool"
}

/// Convenience wrapper that makes the raw `kFxParameterFlag_*` constants feel at
/// home in modern Swift. Flags are combined with bitwise OR just like their C
/// counterparts.
struct CorridorKeyParameterFlags: OptionSet, Sendable {
    let rawValue: UInt32
    init(rawValue: UInt32) { self.rawValue = rawValue }

    static let `default` = CorridorKeyParameterFlags(rawValue: UInt32(kFxParameterFlag_DEFAULT))
    static let hidden = CorridorKeyParameterFlags(rawValue: UInt32(kFxParameterFlag_HIDDEN))
    static let disabled = CorridorKeyParameterFlags(rawValue: UInt32(kFxParameterFlag_DISABLED))
    static let notAnimatable = CorridorKeyParameterFlags(rawValue: UInt32(kFxParameterFlag_NOT_ANIMATABLE))
    static let collapsed = CorridorKeyParameterFlags(rawValue: UInt32(kFxParameterFlag_COLLAPSED))
    static let ignoreMinMax = CorridorKeyParameterFlags(rawValue: UInt32(kFxParameterFlag_IGNORE_MINMAX))
    static let customUI = CorridorKeyParameterFlags(rawValue: UInt32(kFxParameterFlag_CUSTOM_UI))
    static let useFullViewWidth = CorridorKeyParameterFlags(rawValue: UInt32(kFxParameterFlag_USE_FULL_VIEW_WIDTH))
    static let curveEditorHidden = CorridorKeyParameterFlags(rawValue: UInt32(kFxParameterFlag_CURVE_EDITOR_HIDDEN))

    /// Flag combo we apply to every enum/toggle parameter in the inspector.
    /// Animating screen colour or output mode makes no visual sense and
    /// clutters the curve editor, so we keep these controls static.
    static let nonAnimatableChoice: CorridorKeyParameterFlags = [.default, .notAnimatable, .curveEditorHidden]

    /// Flag combo for the custom-UI inspector header parameter.
    static let headerCustomUI: CorridorKeyParameterFlags = [
        .default,
        .customUI,
        .notAnimatable,
        .curveEditorHidden,
        .useFullViewWidth
    ]

    var fxFlags: FxParameterFlags { FxParameterFlags(rawValue) }
}
