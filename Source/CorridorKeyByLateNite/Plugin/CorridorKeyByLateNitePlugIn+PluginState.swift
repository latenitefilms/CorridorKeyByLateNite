//
//  CorridorKeyToolboxPlugIn+PluginState.swift
//  CorridorKey by LateNite
//
//  Reads every parameter into a single value-type snapshot that the renderer
//  and analyser can consume without touching the FxPlug API again. FxPlug
//  requires us to return a fresh NSData each call because the host may issue
//  calls from multiple threads.
//

import Foundation
import CoreMedia


extension CorridorKeyToolboxPlugIn {


    /// Captures native v2 parameters and the sandboxed hint asset for either analysis or rendering.
    func videoSettings(using retrieval: any FxParameterRetrievalAPI_v6, at time: CMTime,
                       headerStorage: HeaderCustomParameterStorage.Snapshot? = nil) -> VideoInferenceSettings {
        var value = VideoInferenceSettings()
        value.inputIsLinear = boolValue(retrieval: retrieval, parameterID: ParameterIdentifier.inputIsLinear, time: time, default: value.inputIsLinear)
        value.linearizeOutput = boolValue(retrieval: retrieval, parameterID: ParameterIdentifier.linearizeOutput, time: time, default: value.linearizeOutput)
        value.keepOriginalInSolidAreas = boolValue(retrieval: retrieval, parameterID: ParameterIdentifier.keepOriginalInSolidAreas, time: time, default: value.keepOriginalInSolidAreas)
        value.timeAwareness = popupValue(retrieval: retrieval, parameterID: ParameterIdentifier.timeAwareness, time: time, default: value.timeAwareness)
        value.lowGPUMemory = boolValue(retrieval: retrieval, parameterID: ParameterIdentifier.lowGPUMemory, time: time, default: value.lowGPUMemory)
        value.useAlphaHint = boolValue(retrieval: retrieval, parameterID: ParameterIdentifier.useAlphaHint, time: time, default: value.useAlphaHint)
        value.hintFrames = popupValue(retrieval: retrieval, parameterID: ParameterIdentifier.hintFrames, time: time, default: value.hintFrames)
        value.referenceFrame = intValue(retrieval: retrieval, parameterID: ParameterIdentifier.referenceFrame, time: time, default: value.referenceFrame)
        value.alphaHintStrength = floatValue(retrieval: retrieval, parameterID: ParameterIdentifier.alphaHintStrength, time: time, default: value.alphaHintStrength)
        value.internalHintStrength = floatValue(retrieval: retrieval, parameterID: ParameterIdentifier.internalHintStrength, time: time, default: value.internalHintStrength)
        if let dictionary = HeaderCustomParameterStorage.dictionaryValue(for: HeaderStorageKey.alphaHintAsset, using: retrieval, storage: headerStorage),
           let data = dictionary["asset"] as? Data {
            value.alphaHintAsset = try? PropertyListDecoder().decode(AlphaHintAsset.self, from: data)
        }
        var red = value.customScreenColor.x
        var green = value.customScreenColor.y
        var blue = value.customScreenColor.z
        retrieval.getRedValue(&red, greenValue: &green, blueValue: &blue,
                              fromParameter: ParameterIdentifier.customScreenColor, at: time)
        value.customScreenColor = SIMD3(red, green, blue)
        return value
    }

    @objc(pluginState:atTime:quality:error:)
    func pluginState(
        _ pluginState: AutoreleasingUnsafeMutablePointer<NSData>?,
        at renderTime: CMTime,
        quality qualityLevel: UInt
    ) throws {
        guard let retrieval = apiManager.api(for: (any FxParameterRetrievalAPI_v6).self) as? any FxParameterRetrievalAPI_v6 else {
            throw NSError(
                domain: FxPlugErrorDomain,
                code: kFxError_APIUnavailable,
                userInfo: [NSLocalizedDescriptionKey: "CorridorKey by LateNite could not read parameter values."]
            )
        }

        var state = PluginStateData()
        let headerStorage = HeaderCustomParameterStorage.storageDictionary(using: retrieval)
        state.renderQualityLevel = Int(qualityLevel)
        state.video = videoSettings(using: retrieval, at: renderTime, headerStorage: headerStorage)
        if let gamutAPI = apiManager.api(for: (any FxColorGamutAPI_v2).self) as? any FxColorGamutAPI_v2 {
            state.workingColorGamut = ColorGamutMatrix.gamut(fromColorPrimariesRaw: UInt(gamutAPI.colorPrimaries()))
        }
        if let timing = apiManager.api(for: (any FxTimingAPI_v4).self) as? any FxTimingAPI_v4 {
            var duration = CMTime.invalid
            var start = CMTime.invalid
            timing.frameDuration(&duration)
            timing.startTimeOfInput(toFilter: &start)
            let position = CMTimeSubtract(renderTime, start).seconds / duration.seconds
            if position.isFinite, position >= 0, position <= Double(Int32.max) { state.sourceFrameIndex = Int(position.rounded()) }
        }

        // Key setup
        state.screenColor = popupValue(
            retrieval: retrieval,
            parameterID: ParameterIdentifier.screenColor,
            time: renderTime,
            default: .green
        )
        state.qualityMode = popupValue(
            retrieval: retrieval,
            parameterID: ParameterIdentifier.qualityMode,
            time: renderTime,
            default: .automatic
        )
        // Explicit host values win; missing controls use the shared factory defaults.
        state.hintMode = popupValue(
            retrieval: retrieval,
            parameterID: ParameterIdentifier.hintMode,
            time: renderTime,
            default: PluginStateData().hintMode
        )
        // Interior. Defaults below mirror `PluginStateData()`'s
        // designated initialiser exactly so the FxPlug and the
        // Standalone Editor land on the same matte when nothing
        // overrides. Additional edge colour correction is opt-in.
        state.sourcePassthroughEnabled = boolValue(
            retrieval: retrieval,
            parameterID: ParameterIdentifier.sourcePassthrough,
            time: renderTime,
            default: false
        )
        state.passthroughErodeNormalized = floatValue(
            retrieval: retrieval,
            parameterID: ParameterIdentifier.passthroughErode,
            time: renderTime,
            default: 3
        )
        state.passthroughBlurNormalized = floatValue(
            retrieval: retrieval,
            parameterID: ParameterIdentifier.passthroughBlur,
            time: renderTime,
            default: 7
        )

        // Matte
        state.alphaBlackPoint = floatValue(
            retrieval: retrieval,
            parameterID: ParameterIdentifier.alphaBlackPoint,
            time: renderTime,
            default: 0
        )
        state.alphaWhitePoint = floatValue(
            retrieval: retrieval,
            parameterID: ParameterIdentifier.alphaWhitePoint,
            time: renderTime,
            default: 1
        )
        state.alphaErodeNormalized = floatValue(
            retrieval: retrieval,
            parameterID: ParameterIdentifier.alphaErode,
            time: renderTime,
            default: 0
        )
        state.alphaSoftnessNormalized = floatValue(
            retrieval: retrieval,
            parameterID: ParameterIdentifier.alphaSoftness,
            time: renderTime,
            default: 0
        )
        state.alphaGamma = floatValue(
            retrieval: retrieval,
            parameterID: ParameterIdentifier.alphaGamma,
            time: renderTime,
            default: 1
        )
        state.autoDespeckleEnabled = boolValue(
            retrieval: retrieval,
            parameterID: ParameterIdentifier.autoDespeckle,
            time: renderTime,
            default: PluginStateData().autoDespeckleEnabled
        )
        state.despeckleSize = intValue(
            retrieval: retrieval,
            parameterID: ParameterIdentifier.despeckleSize,
            time: renderTime,
            default: 100
        )
        state.refinerStrength = floatValue(
            retrieval: retrieval,
            parameterID: ParameterIdentifier.refinerStrength,
            time: renderTime,
            default: 1.0
        )

        // Edge refinement (Phase 4).
        state.lightWrapEnabled = boolValue(
            retrieval: retrieval,
            parameterID: ParameterIdentifier.lightWrapEnabled,
            time: renderTime,
            default: PluginStateData().lightWrapEnabled
        )
        state.lightWrapStrength = floatValue(
            retrieval: retrieval,
            parameterID: ParameterIdentifier.lightWrapStrength,
            time: renderTime,
            default: 0.25
        )
        state.lightWrapRadius = floatValue(
            retrieval: retrieval,
            parameterID: ParameterIdentifier.lightWrapRadius,
            time: renderTime,
            default: 10
        )
        state.edgeDecontaminateEnabled = boolValue(
            retrieval: retrieval,
            parameterID: ParameterIdentifier.edgeDecontaminateEnabled,
            time: renderTime,
            default: false
        )
        state.edgeDecontaminateStrength = floatValue(
            retrieval: retrieval,
            parameterID: ParameterIdentifier.edgeDecontaminateStrength,
            time: renderTime,
            default: 0.5
        )

        // Temporal stability (Phase 1).
        state.temporalStabilityEnabled = boolValue(
            retrieval: retrieval,
            parameterID: ParameterIdentifier.temporalStabilityEnabled,
            time: renderTime,
            default: PluginStateData().temporalStabilityEnabled
        )
        state.temporalStabilityStrength = floatValue(
            retrieval: retrieval,
            parameterID: ParameterIdentifier.temporalStabilityStrength,
            time: renderTime,
            default: 0.5
        )

        // Edge & spill
        state.despillStrength = floatValue(
            retrieval: retrieval,
            parameterID: ParameterIdentifier.despillStrength,
            time: renderTime,
            default: 0
        )
        state.spillMethod = popupValue(
            retrieval: retrieval,
            parameterID: ParameterIdentifier.spillMethod,
            time: renderTime,
            default: .ultra
        )

        // Output and performance
        state.outputMode = popupValue(
            retrieval: retrieval,
            parameterID: ParameterIdentifier.outputMode,
            time: renderTime,
            default: .processed
        )
        state.upscaleMethod = popupValue(
            retrieval: retrieval,
            parameterID: ParameterIdentifier.upscaleMethod,
            time: renderTime,
            default: .lanczos
        )

        // Load the user's OSC-placed hint dots from the published header
        // storage dictionary so they round-trip through the `.moef` wrapper.
        state.hintPointSet = loadHintPointSet(using: retrieval, headerStorage: headerStorage)

        // If FxAnalyzer has cached a matte for this frame, pack the
        // compressed blob and its inference resolution into the state so the
        // render callback can skip MLX entirely. Screen colour must match the
        // analysis run — mismatches invalidate the cache for that frame.
        if let analysis = loadAnalysisData(using: retrieval, headerStorage: headerStorage),
           let cachedMatte = analysis.cachedMatte(
                at: renderTime,
                screenColorRaw: state.screenColor.rawValue,
                qualityModeRaw: state.qualityMode.rawValue,
                hintConfiguration: state.analysisHintConfiguration
           ) {
            state.cachedMatteBlob = cachedMatte.blob
            state.cachedFrameReference = cachedMatte.reference
            state.cachedMatteInferenceResolution = cachedMatte.inferenceResolution
        }

        let nsData = try state.encodedForHost()
        pluginState?.pointee = nsData
    }

    // MARK: - Retrieval helpers

    /// Reads a choice parameter, falling back to the supplied default if the
    /// host signals an error or returns an index outside of the known range.
    private func popupValue<Enum: RawRepresentable>(
        retrieval: any FxParameterRetrievalAPI_v6,
        parameterID: UInt32,
        time: CMTime,
        default defaultValue: Enum
    ) -> Enum where Enum.RawValue == Int {
        var raw: Int32 = 0
        guard retrieval.getIntValue(&raw, fromParameter: parameterID, at: time) else {
            return defaultValue
        }
        return Enum(rawValue: Int(raw)) ?? defaultValue
    }

    private func floatValue(
        retrieval: any FxParameterRetrievalAPI_v6,
        parameterID: UInt32,
        time: CMTime,
        default defaultValue: Double
    ) -> Double {
        var value: Double = defaultValue
        retrieval.getFloatValue(&value, fromParameter: parameterID, at: time)
        return value
    }

    private func intValue(
        retrieval: any FxParameterRetrievalAPI_v6,
        parameterID: UInt32,
        time: CMTime,
        default defaultValue: Int
    ) -> Int {
        var value: Int32 = Int32(defaultValue)
        retrieval.getIntValue(&value, fromParameter: parameterID, at: time)
        return Int(value)
    }

    private func boolValue(
        retrieval: any FxParameterRetrievalAPI_v6,
        parameterID: UInt32,
        time: CMTime,
        default defaultValue: Bool
    ) -> Bool {
        var value: ObjCBool = ObjCBool(defaultValue)
        retrieval.getBoolValue(&value, fromParameter: parameterID, at: time)
        return value.boolValue
    }

    /// Decodes the Subject Points payload stored inside the published header
    /// custom parameter. Returns an empty set when it has never been written
    /// (the typical case until the user clicks the canvas with the OSC active).
    func loadHintPointSet(
        using retrieval: any FxParameterRetrievalAPI_v6,
        headerStorage: HeaderCustomParameterStorage.Snapshot? = nil
    ) -> HintPointSet {
        let dictionary = HeaderCustomParameterStorage.dictionaryValue(
            for: HeaderStorageKey.subjectPoints,
            using: retrieval,
            storage: headerStorage
        )
        return HintPointSet.fromParameterDictionary(dictionary)
    }
}
