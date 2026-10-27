//
//  HintPointSet.swift
//  CorridorKey by LateNite
//
//  Value type for the user-placed foreground / background hint points
//  the on-screen control writes into a custom parameter and the
//  renderer rasterises into the MLX bridge's 4th input channel.
//
//  The set is stored inside the same published header custom parameter as
//  the Analysis Data blob, which is why it round-trips through `NSDictionary`
//  (FxPlug custom-parameter contract).
//

import Foundation
import CoreGraphics
import CoreMedia

/// Source-frame identity shared by the editor, OSC, analysis and diagnostics.
/// A half-frame tolerance accommodates equivalent timestamps with different
/// timescales without holding or interpolating annotations onto adjacent frames.
public struct HintFrame: Hashable, Sendable, Codable {
    private let seconds: Double
    private let durationSeconds: Double
    private let epoch: Int64

    /// Creates a frame identity only for finite source times and positive durations.
    public init?(time: CMTime, duration: CMTime) {
        guard time.isNumeric, duration.isNumeric,
              time.seconds.isFinite, duration.seconds.isFinite,
              duration.seconds > 0 else { return nil }
        seconds = time.seconds
        durationSeconds = duration.seconds
        epoch = time.epoch
    }

    /// Whether a source timestamp addresses this annotated frame.
    public func contains(_ time: CMTime) -> Bool {
        guard time.isNumeric, time.epoch == epoch else { return false }
        let delta = time.seconds - seconds
        return delta >= -durationSeconds / 2 && delta < durationSeconds / 2
    }
}

/// Identical guidance in the standalone and Final Cut Pro inspectors.
public enum ManualHintGuidance {
    /// Describes the local influence and analysis workflow without promising tracking.
    public static let explanation = "Apple Vision supplies the starting matte. Foreground selects a detected subject. Mark more subjects to keep them too. Background removes a small area. Ignore (red cross) excludes a detected object, or removes a small area if no object is found. Ignore wins when the same object is also marked Foreground. Erase removes a point. Points apply only to the displayed frame and do not track. Unmarked frames use Apple Vision. Choose Alpha Hint (Diagnostic) to inspect the guide, then Analyse Clip to update the result."
    /// Explains how to migrate annotations whose original frame was never recorded.
    public static let legacyExplanation = "Hints saved in earlier versions apply to every frame. Clear them and add new hints to make them frame-specific."
}

/// Foreground and Ignore select or exclude Vision instances. Background and
/// unmatched points make local corrections. Stable integers preserve saved hints.
public enum HintPointKind: Int, Sendable, Codable {
    case foreground = 0
    case background = 1
    /// Excludes the detected Vision instance, with a local correction as fallback.
    case ignore = 2
}

/// One user-placed hint point. Coordinates are in object-normalized
/// space (0…1 across the input image) so they remain valid when the
/// user changes the canvas size or applies
/// a transform on top of CorridorKey by LateNite.
public struct HintPoint: Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double
    public var kind: HintPointKind
    public var radiusNormalized: Double
    /// `nil` preserves the clip-wide behaviour of hints saved before frame support.
    public var frame: HintFrame?

    public init(x: Double, y: Double, kind: HintPointKind, radiusNormalized: Double = 0.04, frame: HintFrame? = nil) {
        self.x = x
        self.y = y
        self.kind = kind
        self.radiusNormalized = radiusNormalized
        self.frame = frame
    }
}

/// Serializable set of hint points the OSC writes into the FxPlug
/// header-storage payload and the renderer reads back at analysis time.
/// Codable so unit tests can round-trip without FxPlug.
public struct HintPointSet: Hashable, Sendable, Codable {
    private static let blobKey = "blob"

    public var points: [HintPoint]

    public init(points: [HintPoint] = []) {
        self.points = points
    }

    public var isEmpty: Bool { points.isEmpty }

    /// Older projects retain their original global hints until explicitly cleared.
    public var hasLegacyPoints: Bool { points.contains { $0.frame == nil } }

    /// Annotations for this source frame, in placement order. No temporal propagation.
    public func points(at time: CMTime) -> [HintPoint] {
        points.filter { $0.frame?.contains(time) ?? true }
    }

    /// Persists to the host as a binary plist so we can embed it
    /// inside a custom-parameter NSDictionary alongside other custom
    /// payloads. Plist binary keeps the encoded blob compact and
    /// avoids JSON's percent-escaping bloat for long sequences.
    public func encodedForHost() throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(self)
    }

    public static func decoded(from data: Data?) -> HintPointSet {
        guard let data, !data.isEmpty else { return HintPointSet() }
        do {
            return try PropertyListDecoder().decode(HintPointSet.self, from: data)
        } catch {
            return HintPointSet()
        }
    }

    /// Round-trips through the FxPlug custom-parameter NSDictionary
    /// contract. The dictionary has one key, "blob", whose value is
    /// the binary plist payload above. Future revisions can layer in
    /// extra keys (e.g. a schema version) without breaking older
    /// builds, which simply ignore unknown keys.
    public func asParameterDictionary() -> NSDictionary {
        let dict = NSMutableDictionary()
        if let blob = try? encodedForHost() {
            dict[NSString(string: Self.blobKey)] = blob as NSData
        }
        return dict.copy() as? NSDictionary ?? NSDictionary()
    }

    public static func fromParameterDictionary(_ dictionary: NSDictionary?) -> HintPointSet {
        guard let dictionary else {
            return HintPointSet()
        }
        let nsBlobKey = NSString(string: Self.blobKey)
        if let blob = dictionary[nsBlobKey] as? Data {
            return decoded(from: blob)
        }
        if let blob = dictionary[nsBlobKey] as? NSData {
            return decoded(from: Data(referencing: blob))
        }
        guard let blob = dictionary[Self.blobKey] as? Data else {
            return HintPointSet()
        }
        return decoded(from: blob)
    }

    // MARK: - Editing helpers

    public mutating func add(_ point: HintPoint) {
        points.append(point)
    }

    /// Removes the point closest to `(x, y)` if any sit within
    /// `tolerance` (in object-normalized units). Returns `true` when
    /// a point was removed, so the caller can decide whether to
    /// trigger a re-render. The OSC uses this for shift-click delete
    /// and right-click delete.
    @discardableResult
    public mutating func removeNearest(toX x: Double, y: Double, tolerance: Double, at time: CMTime? = nil) -> Bool {
        guard !points.isEmpty else { return false }
        var nearestIndex: Int? = nil
        var nearestDistanceSquared = tolerance * tolerance
        for (index, point) in points.enumerated() {
            if let time, let frame = point.frame, !frame.contains(time) { continue }
            let dx = point.x - x
            let dy = point.y - y
            let distanceSquared = dx * dx + dy * dy
            if distanceSquared <= nearestDistanceSquared {
                nearestDistanceSquared = distanceSquared
                nearestIndex = index
            }
        }
        if let nearestIndex {
            points.remove(at: nearestIndex)
            return true
        }
        return false
    }

    public mutating func clear() {
        points.removeAll(keepingCapacity: false)
    }

    /// Removes only annotations visible at this time, including any legacy global hints.
    public mutating func clear(at time: CMTime) {
        points.removeAll { $0.frame?.contains(time) ?? true }
    }
}
