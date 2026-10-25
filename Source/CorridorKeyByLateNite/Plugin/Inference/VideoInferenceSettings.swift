import Foundation

/// Persisted v2 model controls, shared by the editor and the FxPlug effect.
/// Post-processing controls remain separate so changing them can reuse analysis.
public struct VideoInferenceSettings: Codable, Equatable, Sendable {
    /// Wording shared by native FxPlug controls and SwiftUI.
    public enum Labels {
        public static let inputIsLinear = "Input is Linear"
        public static let linearizeOutput = "Linearize Output"
        public static let keepOriginalInSolidAreas = "Keep Original in Solid Areas"
        public static let timeAwareness = "Time Awareness"
        public static let lowGPUMemory = "Low GPU Memory"
        public static let useAlphaHint = "Use Alpha Hint"
        public static let hintFrames = "Hint Frames"
        public static let referenceFrame = "Reference Frame"
        public static let alphaHintStrength = "Alpha Hint Strength"
        public static let internalHintStrength = "Internal Hint Strength"
    }
    /// Number of frames jointly evaluated by the spatiotemporal network.
    public var timeAwareness: TimeAwareness = .off
    /// Keep intermediate features on disk instead of retaining a window in GPU memory.
    public var lowGPUMemory = true
    /// Source RGB is already scene linear; no display transfer is decoded.
    public var inputIsLinear = false
    /// Write scene-linear foreground RGB. Alpha is never gamma transformed.
    public var linearizeOutput = false
    /// Restore full-resolution source pixels wherever the refined matte exceeds 0.95.
    public var keepOriginalInSolidAreas = false
    /// Enable the selected external matte without discarding its file selection.
    public var useAlphaHint = false
    /// Whether the selected asset supplies every frame or a single reference image.
    public var hintFrames: AlphaHintFrames = .allFrames
    /// Zero-based source frame to which a single hint image belongs.
    public var referenceFrame = 0
    /// Confidence assigned to a supplied external or generated alpha hint.
    public var alphaHintStrength = 0.75
    /// Confidence assigned to overlapping windows' predicted auxiliary hints.
    public var internalHintStrength = 0.95
    /// Sandboxed file selection. The bookmark travels with saved effect settings.
    public var alphaHintAsset: AlphaHintAsset?
    /// RGB reference used when Screen Colour is Custom, shared with native FxPlug.
    public var customScreenColor = SIMD3<Double>(0.08, 0.84, 0.08)

    /// Creates the common factory defaults.
    public init() {}

    /// Settings which change network predictions, excluding output-only controls.
    public var analysisIdentity: Self {
        var identity = self
        identity.lowGPUMemory = true
        identity.linearizeOutput = false
        identity.keepOriginalInSolidAreas = false
        if !identity.useAlphaHint { identity.alphaHintAsset = nil }
        return identity
    }

    /// Conservative FP32 working-set estimate for this backend, including
    /// query-chunk attention. The device budget is not the system's free RAM.
    public func estimatedGPUBytes(resolution: Int, frameCount: Int) -> UInt64 {
        let pixels = UInt64(max(1, min(2048, resolution))) * UInt64(max(1, min(2048, resolution)))
        let frames = UInt64(timeAwareness.effectiveFrameCount(for: frameCount))
        let tokens = pixels / 4096 * frames
        // Reserve model/foundation working memory separately from the temporal
        // window. Calibrated above the measured 512/T80 peak (7.4 GiB), rather
        // than counting only the visible input and attention tensors.
        return (4 << 30) + pixels * 256 + pixels * frames * 160 + min(tokens, 2048) * tokens * 16 * 4
    }

    /// Shared inspector wording distinguishes estimated demand from device capacity.
    public func memoryDescription(resolution: Int, frameCount: Int, deviceBudget: UInt64) -> String {
        let estimate = estimatedGPUBytes(resolution: resolution, frameCount: frameCount)
        return "Estimated GPU memory: \(estimate.formatted(.byteCount(style: .memory))). Device budget: \(deviceBudget.formatted(.byteCount(style: .memory)))."
            + (estimate > deviceBudget ? " Lower Time Awareness or Quality." : "")
    }

    /// Rejects inconsistent hints before either host begins a costly analysis pass.
    public func validate(frameCount: Int) throws {
        guard frameCount > 0,
              alphaHintStrength.isFinite, (0...1).contains(alphaHintStrength),
              internalHintStrength.isFinite, (0...1).contains(internalHintStrength) else {
            throw VideoInferenceSettingsError.invalidControls
        }
        if useAlphaHint {
            guard alphaHintAsset != nil else { throw VideoInferenceSettingsError.missingHint }
            if hintFrames == .singleFrame {
                guard timeAwareness != .off || frameCount == 1 else {
                    throw VideoInferenceSettingsError.singleHintNeedsTimeAwareness
                }
                guard (0..<frameCount).contains(referenceFrame) else {
                    throw VideoInferenceSettingsError.referenceOutsideClip
                }
            }
        }
    }
}

/// Stable popup indices. Frame counts are deliberately separate from saved raw values.
public enum TimeAwareness: Int, Codable, CaseIterable, Sendable {
    case off, two, four, eight, twentyFour, fortyEight, eighty

    /// Maximum number of frames evaluated together, including the current frame.
    public var frameCount: Int { [1, 2, 4, 8, 24, 48, 80][rawValue] }
    /// Shared inspector wording.
    public var displayName: String { self == .off ? "Off" : "\(frameCount) Frames" }

    /// The smallest exported profile covering a short sequence. A still never
    /// allocates an eighty-frame network merely because that clip setting was saved.
    public func effectiveFrameCount(for sequenceCount: Int) -> Int {
        let requested = max(1, min(frameCount, sequenceCount))
        return Self.allCases.first(where: { $0.frameCount >= requested })?.frameCount ?? frameCount
    }
}

/// Timing interpretation of an external alpha hint.
public enum AlphaHintFrames: Int, Codable, CaseIterable, Sendable {
    case allFrames, singleFrame
    /// Shared inspector wording.
    public var displayName: String { self == .allFrames ? "All Frames" : "Single Frame" }
}

/// Persistent permission to read an external hint, without embedding media in project state.
public struct AlphaHintAsset: Codable, Equatable, Sendable {
    /// Display name shown in both inspectors.
    public let name: String
    /// Security-scoped bookmark created while the file importer grants access.
    public let bookmark: Data
    /// New identity for each explicit selection, including reselecting an edited file.
    public let identity: UUID

    /// Captures the user's file selection for later analysis in the sandbox.
    public init(url: URL) throws {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        name = url.lastPathComponent
        bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                        includingResourceValuesForKeys: nil, relativeTo: nil)
        identity = UUID()
    }

    /// Resolves a saved selection. Callers retain access for their reader's lifetime.
    public func resolvedURL() throws -> URL {
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale else { throw VideoInferenceSettingsError.staleHint }
        return url
    }
}

/// Actionable validation failures common to both hosts.
public enum VideoInferenceSettingsError: LocalizedError {
    case invalidControls, missingHint, singleHintNeedsTimeAwareness, referenceOutsideClip, staleHint
    case hintSequenceMismatch, hintDimensionsMismatch

    public var errorDescription: String? {
        switch self {
        case .invalidControls: "The clip or alpha hint strengths are invalid."
        case .missingHint: "Choose an Alpha Hint file before enabling Use Alpha Hint."
        case .singleHintNeedsTimeAwareness: "Single Frame alpha hints need Time Awareness to propagate through the clip."
        case .referenceOutsideClip: "Reference Frame must be a frame within this clip."
        case .staleHint: "The Alpha Hint file has moved or its permission has expired. Choose it again."
        case .hintSequenceMismatch: "Choose a matching hint movie or image-sequence folder for All Frames, or one image for Single Frame. Movies must match the clip's duration and frame rate; sequences must match its frame count."
        case .hintDimensionsMismatch: "The Alpha Hint dimensions must match the source clip."
        }
    }
}

/// Aspect-preserving fit inside a model profile. Padding is reflected, then cropped
/// before predictions enter the cache, so neither portraits nor widescreen plates stretch.
public struct InferenceGeometry: Equatable, Sendable {
    public let resolution: Int
    public let contentWidth: Int
    public let contentHeight: Int
    public var offsetX: Int { (resolution - contentWidth) / 2 }
    public var offsetY: Int { (resolution - contentHeight) / 2 }

    /// Fits the source's longest edge to the selected network resolution.
    public init(sourceWidth: Int, sourceHeight: Int, resolution: Int) {
        self.resolution = max(1, resolution)
        let scale = Double(self.resolution) / Double(max(1, max(sourceWidth, sourceHeight)))
        contentWidth = max(1, min(self.resolution, Int((Double(sourceWidth) * scale).rounded())))
        contentHeight = max(1, min(self.resolution, Int((Double(sourceHeight) * scale).rounded())))
    }
}

/// Overlapping stage-one windows with the upstream cosine taper. Batons, rather
/// than finished mattes, are weighted and normalized before stage-two refinement.
public struct TemporalWindow: Equatable, Sendable {
    public let start: Int
    public let count: Int
    public let weights: [Float]

    /// Windows always cover the final frame, including clips shorter than a profile.
    /// Short windows repeat their last frame only at the model input boundary.
    public static func plan(frameCount: Int, window: Int) -> [Self] {
        guard frameCount > 0, window > 0 else { return [] }
        let length = min(window, frameCount)
        let stride = max(1, window / 2)
        let lastStart = frameCount - length
        let starts = Array(Set(Swift.stride(from: 0, through: lastStart, by: stride)).union([lastStart])).sorted()
        let overlap = window - stride
        return starts.enumerated().map { index, start in
            var weights = [Float](repeating: 1, count: length)
            if overlap > 0, length > 1 {
                let ramp = (0..<min(length, overlap)).map {
                    Float((1 - cos(Double($0 + 1) * .pi / Double(overlap + 1))) * 0.5)
                }
                if index > 0 {
                    for offset in ramp.indices { weights[offset] = ramp[offset] }
                }
                if index < starts.count - 1 {
                    for offset in ramp.indices { weights[length - 1 - offset] = ramp[offset] }
                }
            }
            return Self(start: start, count: length, weights: weights)
        }
    }
}
