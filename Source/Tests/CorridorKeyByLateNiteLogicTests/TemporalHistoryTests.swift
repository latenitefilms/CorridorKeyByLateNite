import Testing
@testable import CorridorKeyToolboxLogic

@Suite("Temporal analysis history")
struct TemporalHistoryTests {
    private let configuration = TemporalBlender.Configuration(strength: 0.5, motionThreshold: 0.05)
    private let source: [Float] = [0.3, 0.4, 0.5, 1]

    @Test("Consecutive frames accumulate blended alpha")
    func accumulates() {
        var history = TemporalBlender.History()
        var alpha: [Float] = [0.2]
        #expect(!history.apply(alpha: &alpha, source: source, width: 1, height: 1,
                               frameIndex: 0, configuration: configuration))
        alpha = [0.8]
        #expect(history.apply(alpha: &alpha, source: source, width: 1, height: 1,
                              frameIndex: 1, configuration: configuration))
        #expect(abs(alpha[0] - 0.5) < 1e-6)
        alpha = [0.9]
        history.apply(alpha: &alpha, source: source, width: 1, height: 1,
                      frameIndex: 2, configuration: configuration)
        #expect(abs(alpha[0] - 0.7) < 1e-6)
    }

    @Test("Gaps, disabled blending and missing source reset history", arguments: [0, 1, 2])
    func resets(reason: Int) {
        var history = TemporalBlender.History()
        var alpha: [Float] = [0.2]
        history.apply(alpha: &alpha, source: source, width: 1, height: 1,
                      frameIndex: 0, configuration: configuration)
        alpha = [0.8]
        let currentConfiguration = reason == 1
            ? TemporalBlender.Configuration(strength: 0, motionThreshold: 0.05) : configuration
        #expect(!history.apply(alpha: &alpha, source: reason == 2 ? nil : source, width: 1, height: 1,
                               frameIndex: reason == 0 ? 3 : 1, configuration: currentConfiguration))
        #expect(alpha == [0.8])
        if reason != 0 {
            alpha = [0.9]
            #expect(!history.apply(alpha: &alpha, source: source, width: 1, height: 1,
                                   frameIndex: 2, configuration: configuration))
        }
    }

    @Test("Changed dimensions with the same pixel count cannot blend stale rows")
    func dimensionChange() {
        var history = TemporalBlender.History()
        var alpha: [Float] = [0.2, 0.2]
        history.apply(alpha: &alpha, source: source + source, width: 2, height: 1,
                      frameIndex: 0, configuration: configuration)
        alpha = [0.8, 0.8]
        #expect(!history.apply(alpha: &alpha, source: source + source, width: 1, height: 2,
                               frameIndex: 1, configuration: configuration))
        #expect(alpha == [0.8, 0.8])
    }
}
