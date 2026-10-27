import CoreMedia
import Testing
@testable import CorridorKeyToolboxLogic

@Suite("Manual hint viewer hit testing")
struct HintHitTestingTests {
    @Test("The first hint can be placed without existing points")
    func emptyImageReceivesClicks() {
        let target = HintHitTesting.target(at: SIMD2(0.25, 0.75),
                                          hints: [], allowsManualHints: true)
        #expect(target == .canvas)
        #expect(target.hostPartIdentifier > 0)
        #expect(Int32(exactly: target.hostPartIdentifier) != nil)
        #expect(target.hostPartIdentifier != HintHitTarget.point(index: 0).hostPartIdentifier)
    }

    @Test("The empty image is left to the host when manual hints are unavailable")
    func disabledCanvasDoesNotConsumeClicks() {
        let target = HintHitTesting.target(at: SIMD2(0.25, 0.75),
                                          hints: [HintPoint(x: 0.25, y: 0.75, kind: .foreground)],
                                          allowsManualHints: false)
        #expect(target == .none)
        #expect(target.hostPartIdentifier == 0)
    }

    @Test("Letterboxing and invalid coordinates never create hints", arguments: [
        SIMD2(-0.01, 0.5), SIMD2(1.01, 0.5), SIMD2(0.5, -0.01), SIMD2(0.5, 1.01),
        SIMD2(Double.nan, 0.5), SIMD2(0.5, Double.infinity)
    ])
    func outsideImageDoesNotConsumeClicks(position: SIMD2<Double>) {
        #expect(HintHitTesting.target(at: position,
                                     hints: [], allowsManualHints: true) == .none)
    }

    @Test("Image edges remain editable", arguments: [SIMD2(0.0, 0.0), SIMD2(1.0, 1.0)])
    func imageEdgesReceiveClicks(position: SIMD2<Double>) {
        #expect(HintHitTesting.target(at: position,
                                     hints: [], allowsManualHints: true) == .canvas)
    }

    @Test("The nearest point keeps its Metal highlight index")
    func nearestPoint() {
        let hints = [HintPoint(x: 0.48, y: 0.5, kind: .background),
                     HintPoint(x: 0.51, y: 0.5, kind: .foreground)]
        let target = HintHitTesting.target(at: SIMD2(0.51, 0.5),
                                          hints: hints, allowsManualHints: true)
        #expect(target == .point(index: 1))
        #expect(target.hostPartIdentifier == 2)
    }

    @Test("Hints on another frame do not block placing the first point on this frame")
    func frameSpecificTargets() throws {
        let frame = try #require(HintFrame(time: .zero, duration: CMTime(value: 1, timescale: 24)))
        let hints = HintPointSet(points: [HintPoint(x: 0.5, y: 0.5, kind: .foreground, frame: frame)])
        let target = HintHitTesting.target(at: SIMD2(0.5, 0.5),
                                          hints: hints.points(at: CMTime(value: 1, timescale: 24)),
                                          allowsManualHints: true)
        #expect(target == .canvas)
    }
}
