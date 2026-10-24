//
//  MediaSource.swift
//  CorridorKey by LateNite — Standalone Editor
//

import Foundation
import AVFoundation
import CoreVideo
import UniformTypeIdentifiers
import ImageIO

/// Distinguishes a still from a timed video without inventing playback for it.
enum MediaSourceKind: Sendable {
    case video
    case stillImage
}

/// Metadata shared by videos and stills for preview, analysis, and export.
struct MediaSourceInfo: Sendable {
    /// Whether the source has a playback timeline.
    var kind: MediaSourceKind = .video
    let url: URL
    /// Source-pixel resolution after applying any `preferredTransform`
    /// rotation. The renderer always sees the clip the right way up.
    let renderSize: CGSize
    /// Video frame rate, or one logical frame per second for a still's hint range.
    let nominalFrameRate: Float
    /// Video duration, or the one-frame hint interval for a still.
    let duration: CMTime
    /// Native pixel format of the source track's first sample. Used to
    /// pick a matching destination pixel format on export — e.g. emit
    /// ProRes 4444 at 16 bpc when the source is HDR / float.
    let nativePixelFormat: OSType
    /// Time scale of the source track. Used to build CMTimes that align
    /// to the source frame grid (so scrubbing snaps to whole frames).
    let timescale: CMTimeScale
    /// AV Foundation track identifier for the video. Cached so
    /// downstream readers reference the same track.
    let videoTrackID: CMPersistentTrackID
    /// Preferred transform of the source track (rotation matrix).
    /// Applied automatically by `AVAssetImageGenerator` and the export
    /// reader when `appliesPreferredTrackTransform` is true.
    let preferredTransform: CGAffineTransform
    /// Source colour-space metadata read from the track's format
    /// description. `nil` when the source omits the extension (most
    /// SDR Rec.709 clips do — the exporter falls back to BT.709 in
    /// that case). When present these fields are passed through
    /// verbatim to the export writer so HDR / wide-gamut sources
    /// keep their tags rather than being silently re-tagged BT.709.
    let colorPrimaries: String?
    let transferFunction: String?
    let yCbCrMatrix: String?
    /// Original still-image RGB profile, used when converting pipeline pixels for export.
    /// Non-RGB sources export as sRGB after colour-managed decoding.
    var imageColorSpace: CGColorSpace? = nil
}

/// Read-only, Metal-compatible frames consumed by the shared keying pipeline.
/// Callers must not mutate returned pixel buffers.
protocol EditorMediaSource: Sendable {
    var info: MediaSourceInfo { get }
    func makeFrame(atTime time: CMTime, preferredPixelFormat: OSType) async throws -> CVPixelBuffer
    func makeFrameReader(startTime: CMTime, preferredPixelFormat: OSType) async throws -> any MediaFrameReader
}

/// A sequential reader owned by one analysis or export task.
protocol MediaFrameReader: Sendable {
    func nextFrame() throws -> ReaderFrame?
    func cancel()
}

extension EditorMediaSource {
    /// Decodes a frame at the pipeline's half-float precision.
    func makeFrame(atTime time: CMTime) async throws -> CVPixelBuffer {
        try await makeFrame(atTime: time, preferredPixelFormat: kCVPixelFormatType_64RGBAHalf)
    }

    /// Opens a half-float reader for analysis or export.
    func makeFrameReader(startTime: CMTime = .zero) async throws -> any MediaFrameReader {
        try await makeFrameReader(startTime: startTime, preferredPixelFormat: kCVPixelFormatType_64RGBAHalf)
    }

    /// Snaps `time` to the nearest source frame and clamps to the
    /// last valid frame index. The asset's duration is one frame
    /// past the last frame's presentation time (because each frame
    /// covers one frame-duration interval), so a naïve nearest-
    /// frame mapping at `duration` would return frame N for an
    /// N-frame clip and surface as "5/4 f" in the transport bar.
    /// Capping to `totalFrameCount() - 1` here keeps every
    /// downstream display lined up with the actual frame range.
    func nearestFrameTime(to time: CMTime) -> CMTime {
        guard info.kind == .video else { return .zero }
        let fps = max(Double(info.nominalFrameRate), 0.001)
        let lastFrameIndex = max(0, totalFrameCount() - 1)
        let rawFrameIndex = (time.seconds * fps).rounded()
        let clampedFrameIndex = max(0, min(Double(lastFrameIndex), rawFrameIndex))
        return CMTime(seconds: clampedFrameIndex / fps, preferredTimescale: info.timescale)
    }

    /// Returns the total whole-frame count in the clip. The transport
    /// uses this to size the scrubber.
    func totalFrameCount() -> Int {
        guard info.kind == .video else { return 1 }
        let fps = Double(info.nominalFrameRate)
        guard fps > 0 else { return 1 }
        return max(1, Int((info.duration.seconds * fps).rounded()))
    }
}

/// Selects a decoder for both file-picker and drag-and-drop imports.
enum MediaSourceLoader {
    /// Image IO's supported formats, filtered to images so the picker matches the decoder.
    static var supportedImageTypes: [UTType] {
        (CGImageSourceCopyTypeIdentifiers() as? [String] ?? []).compactMap { identifier in
            guard let type = UTType(identifier), type.conforms(to: .image) else { return nil }
            return type
        }
    }

    /// Video and still formats available in the Import Media picker.
    static var supportedContentTypes: [UTType] { [.movie, .video] + supportedImageTypes }

    /// Resolves content type while sandbox access is active; each source owns its read lifetime.
    static func load(url: URL) async throws -> any EditorMediaSource {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer { if didStartAccessing { url.stopAccessingSecurityScopedResource() } }
        try Task.checkCancellation()
        let contentType = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: url.pathExtension)
        if contentType?.conforms(to: .image) == true {
            return try await StillImageSource(url: url)
        }
        return try await VideoSource(url: url)
    }
}
