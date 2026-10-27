/// A viewer hit target, independent of FxPlug so event routing can be tested headlessly.
enum HintHitTarget: Equatable, Sendable {
    case none
    case point(index: Int)
    case canvas

    /// FxPlug reserves zero for no hit. Point IDs match the Metal marker slots.
    var hostPartIdentifier: Int {
        switch self {
        case .none: 0
        case .point(let index): index + 1
        // A positive target makes empty image space receive mouse events without
        // highlighting a marker. It also fits the shader's signed 32-bit field.
        case .canvas: Int(Int32.max)
        }
    }
}

/// Resolves normalized image positions while leaving letterboxing to the host.
enum HintHitTesting {
    /// Matches the standalone editor's nearest-point erase tolerance.
    static let pointRadius = 0.05
    /// Includes image edges and rejects coordinates outside the image or nonfinite values.
    static func contains(_ position: SIMD2<Double>) -> Bool {
        position.x.isFinite && position.y.isFinite
            && (0...1).contains(position.x) && (0...1).contains(position.y)
    }

    /// Prioritizes existing hints, then empty image space.
    /// The canvas is interactive only while manual hints are enabled.
    static func target(
        at position: SIMD2<Double>,
        hints: [HintPoint],
        allowsManualHints: Bool
    ) -> HintHitTarget {
        guard contains(position) else { return .none }
        guard allowsManualHints else { return .none }
        var target = HintHitTarget.canvas
        var nearestDistanceSquared = pointRadius * pointRadius
        for (index, point) in hints.enumerated() {
            let delta = SIMD2(point.x, point.y) - position
            let distanceSquared = delta.x * delta.x + delta.y * delta.y
            if distanceSquared <= nearestDistanceSquared {
                nearestDistanceSquared = distanceSquared
                target = .point(index: index)
            }
        }
        return target
    }
}
