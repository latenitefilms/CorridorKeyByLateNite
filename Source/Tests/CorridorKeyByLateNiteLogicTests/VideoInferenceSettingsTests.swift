import Foundation
import Testing
@testable import CorridorKeyToolboxLogic

@Suite("V2 video settings and temporal scheduling")
struct VideoInferenceSettingsTests {
    @Test("Short clips avoid oversized temporal profiles and memory estimates grow with demand")
    func memoryPreflight() {
        #expect(TimeAwareness.eighty.effectiveFrameCount(for: 1) == 1)
        #expect(TimeAwareness.eighty.effectiveFrameCount(for: 3) == 4)
        #expect(TimeAwareness.four.effectiveFrameCount(for: 100) == 4)
        var settings = VideoInferenceSettings()
        let still = settings.estimatedGPUBytes(resolution: 512, frameCount: 1)
        settings.timeAwareness = .eighty
        #expect(settings.estimatedGPUBytes(resolution: 512, frameCount: 1) == still)
        #expect(settings.estimatedGPUBytes(resolution: 512, frameCount: 80) > still)
        // The long-profile smoke test measured 7,950,392,564 active MLX bytes.
        // Preflight must include working memory beyond the input tensors.
        #expect(settings.estimatedGPUBytes(resolution: 512, frameCount: 80) > 7_950_392_564)
        #expect(settings.memoryDescription(resolution: 2048, frameCount: 80, deviceBudget: 8 << 30).contains("Lower Time Awareness"))
        var state = PluginStateData()
        state.video.linearizeOutput = true
        state.outputMode = .matteOnly
        #expect(!state.outputIsLinear)
        state.outputMode = .foregroundOnly
        #expect(state.outputIsLinear)
        let original = state.analysisHintConfiguration
        state.temporalStabilityEnabled.toggle()
        #expect(state.analysisHintConfiguration != original)
    }

    @Test("Aspect fit preserves portraits, panoramas and square inputs")
    func aspectFit() {
        let landscape = InferenceGeometry(sourceWidth: 1920, sourceHeight: 1080, resolution: 1024)
        #expect(landscape.contentWidth == 1024)
        #expect(landscape.contentHeight == 576)
        #expect(landscape.offsetY == 224)
        let portrait = InferenceGeometry(sourceWidth: 1080, sourceHeight: 1920, resolution: 1024)
        #expect(portrait.contentWidth == 576)
        #expect(portrait.offsetX == 224)
        let panorama = InferenceGeometry(sourceWidth: 8192, sourceHeight: 128, resolution: 512)
        #expect(panorama.contentHeight == 8)
        #expect(InferenceGeometry(sourceWidth: 512, sourceHeight: 512, resolution: 512).offsetX == 0)
    }

    @Test("Hann windows cover every source frame with positive accumulated weight")
    func temporalCoverage() {
        for count in [1, 2, 3, 7, 24, 81, 103] {
            for option in TimeAwareness.allCases {
                let plan = TemporalWindow.plan(frameCount: count, window: option.frameCount)
                var sums = [Float](repeating: 0, count: count)
                for window in plan {
                    #expect(window.start >= 0 && window.start + window.count <= count)
                    for (offset, weight) in window.weights.enumerated() { sums[window.start + offset] += weight }
                }
                #expect(sums.allSatisfy { $0 > 0 && $0.isFinite })
                #expect(plan.last.map { $0.start + $0.count } == count)
            }
        }
        #expect(TemporalWindow.plan(frameCount: 0, window: 4).isEmpty)
        let windows = TemporalWindow.plan(frameCount: 6, window: 4)
        #expect(windows[0].weights == [1, 1, 0.75, 0.25])
        #expect(windows[1].weights == [0.25, 0.75, 1, 1])
    }

    @Test("Only model settings invalidate cached predictions")
    func analysisIdentity() throws {
        var settings = VideoInferenceSettings()
        let original = settings.analysisIdentity
        settings.linearizeOutput = true
        settings.keepOriginalInSolidAreas = true
        settings.lowGPUMemory = false
        #expect(settings.analysisIdentity == original)
        settings.hintFrames = .singleFrame
        settings.referenceFrame = 12
        settings.internalHintStrength = 0.4
        #expect(settings.analysisIdentity == original)
        settings.timeAwareness = .four
        #expect(settings.analysisIdentity != original)
        var state = PluginStateData()
        state.video = settings
        let restored = PluginStateData.decoded(from: try state.encodedForHost())
        #expect(restored.video == settings)
        let legacy = try PropertyListEncoder().encode(["alphaGamma": 1.0])
        #expect(try PropertyListDecoder().decode(PluginStateData.self, from: legacy).video == VideoInferenceSettings())
    }

    @Test("Motion template defaults match the shared initial settings")
    func motionTemplateDefaults() throws {
        let source = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = source.appending(path: "CorridorKeyByLateNite/WrapperApp/Resources/Motion Template/CorridorKey by LateNite/CorridorKey by LateNite.moef")
        let template = try String(contentsOf: url, encoding: .utf8)
        let state = PluginStateData()
        for (label, identifier, value) in [
            (HintMode.controlName, 1007, state.hintMode.rawValue),
            ("Low GPU Memory", 9005, state.video.lowGPUMemory ? 1 : 0),
            ("Auto Despeckle", 3006, state.autoDespeckleEnabled ? 1 : 0),
            ("Light Wrap", 8001, state.lightWrapEnabled ? 1 : 0),
            ("Reduce Edge Flicker", 8006, state.temporalStabilityEnabled ? 1 : 0)
        ] {
            #expect(template.contains("name=\"\(label)\" id=\"\(identifier)\" flags=\"12901679120\" default=\"\(value)\" value=\"\(value)\""))
        }
        var saved = state
        saved.hintMode = .appleVision
        saved.temporalStabilityEnabled = true
        saved.lightWrapEnabled = true
        saved.autoDespeckleEnabled = true
        #expect(PluginStateData.decoded(from: try saved.encodedForHost()) == saved)
    }

    @Test("Invalid confidence and missing files fail before GPU work")
    func validation() throws {
        var settings = VideoInferenceSettings()
        try settings.validate(frameCount: 12)
        #expect(throws: VideoInferenceSettingsError.self) { try settings.validate(frameCount: 0) }
        settings.alphaHintStrength = .nan
        #expect(throws: VideoInferenceSettingsError.self) { try settings.validate(frameCount: 12) }
        settings.alphaHintStrength = 0.75
        settings.useAlphaHint = true
        #expect(throws: VideoInferenceSettingsError.self) { try settings.validate(frameCount: 12) }
    }
}
