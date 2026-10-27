//
//  VideoSource.swift
//  CorridorKey by LateNite — Standalone Editor
//
//  Wraps an `AVURLAsset` so the standalone editor can:
//
//  * Inspect the clip's natural size, frame rate, duration, and
//    transform (used to build the right preview / output dimensions).
//  * Pull a specific frame into a Metal-compatible `CVPixelBuffer` via
//    the same `AVAssetReader` decode path used for analysis and export.
//  * Stream every frame in display order via an `AsyncThrowingStream`
//    of `(presentationTime, pixelBuffer)` (used for the export pass).
//
//  Both code paths request the same pixel format — the renderer's
//  preferred RGBA16Float — so the GPU stages do not need to handle
//  format-conversion edge cases on the hot path. Anything the host
//  cannot decode at that format falls back to BGRA8Unorm and the
//  pipeline applies the matching shader path.
//

import Foundation
import AVFoundation
import CoreImage
import CoreVideo
import CoreMedia

enum VideoSourceError: Error, CustomStringConvertible {
    case noVideoTrack(URL)
    case readerSetupFailed(any Error)
    case readerOutputUnavailable
    case sampleBufferUnavailable
    case pixelBufferUnavailable

    var description: String {
        switch self {
        case .noVideoTrack(let url):
            return "CorridorKey by LateNite couldn't find a video track in \(url.lastPathComponent)."
        case .readerSetupFailed(let error):
            return "CorridorKey by LateNite couldn't open the clip for reading: \(error.localizedDescription)"
        case .readerOutputUnavailable:
            return "CorridorKey by LateNite couldn't attach a video output to the clip reader."
        case .sampleBufferUnavailable:
            return "CorridorKey by LateNite couldn't read the next sample buffer from the clip."
        case .pixelBufferUnavailable:
            return "CorridorKey by LateNite decoded a sample but no pixel data came with it."
        }
    }
}

/// Loads metadata for a clip and exposes scrub + stream APIs over its
/// pixel data. Holds onto the `AVURLAsset` for the lifetime of the
/// editor session so reader objects can be recreated cheaply.
///
/// Marked `@unchecked Sendable` because `AVURLAsset` is documented as
/// thread-safe and the rest of this class's state is immutable after
/// `init`. Using a regular class instead of an actor lets pipeline
/// hand-offs (e.g. handing a freshly-decoded `CVPixelBuffer` to the
/// main actor) avoid Swift 6's non-Sendable-CoreFoundation friction.
///
/// **Sandbox handling.** Files chosen via `NSOpenPanel` /
/// `.fileImporter` come back as security-scoped URLs. The wrapper app
/// is sandboxed, so opening the underlying file requires bracketing
/// access with `startAccessingSecurityScopedResource()` /
/// `stopAccessingSecurityScopedResource()`. We start the access in
/// `init` and hold it for the lifetime of this `VideoSource` so all
/// downstream `AVURLAsset` reads — frame generation, frame readers,
/// metadata loading — succeed even though the user only granted
/// access once at the file picker. URLs that aren't security-scoped
/// (e.g. files inside `~/Movies` accessed via the
/// `movies.read-write` entitlement) return `false` from
/// `startAccessing…`; we still record that and skip the matching
/// `stop…` call so we never unbalance the access count.
final class VideoSource: EditorMediaSource, @unchecked Sendable {

    let info: MediaSourceInfo
    private let asset: AVURLAsset
    private let url: URL
    private let didStartAccessing: Bool

    /// Loads the clip at `url` asynchronously, populating `info`. Throws
    /// if the asset has no video track or AV Foundation can't decode
    /// the headers.
    init(url: URL) async throws {
        // Security-scoped access must be acquired BEFORE handing the
        // URL to AVURLAsset — the asset reads the underlying file to
        // parse headers, and the sandbox refuses without an active
        // bracket. Returns `false` for non-security-scoped URLs (e.g.
        // a file inside `~/Movies` accessed via the entitlement) so
        // we know not to call `stop…` later.
        self.url = url
        self.didStartAccessing = url.startAccessingSecurityScopedResource()
        let options: [String: Any] = [
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ]
        let asset = AVURLAsset(url: url, options: options)
        self.asset = asset
        do {
            self.info = try await Self.loadInfo(for: asset, url: url)
        } catch {
            // Failed before assigning to `self.info` — release the
            // access bracket immediately because `deinit` won't fire
            // for a partially-initialised instance.
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
            throw error
        }
    }

    deinit {
        if didStartAccessing {
            url.stopAccessingSecurityScopedResource()
        }
    }

    private static func loadInfo(
        for asset: AVURLAsset,
        url: URL
    ) async throws -> MediaSourceInfo {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = tracks.first else {
            throw VideoSourceError.noVideoTrack(url)
        }
        // Swift 6 strict concurrency: `AVAssetTrack` is not `Sendable`,
        // so we can't `async let` its loaders concurrently — that would
        // imply sending the track across actor boundaries. Sequence the
        // loads instead. Header parsing dominates the wall time anyway,
        // and the second-and-later calls are served from the asset's
        // internal property cache so the perf cost is negligible.
        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
        let formatDescriptions = try await videoTrack.load(.formatDescriptions)
        let duration = try await asset.load(.duration)
        let timescale = try await videoTrack.load(.naturalTimeScale)
        // `trackID` is a synchronous, non-loadable property on
        // `AVAssetTrack`. Reading it directly here avoids the
        // `AVAsyncProperty` lookup which doesn't expose this field.
        let trackID = videoTrack.trackID

        // Apply the preferred transform to natural size so renderSize
        // already accounts for portrait clips. VideoFrameReader applies
        // this transform after decoding for both scrubbing and streaming,
        // so the reported dimensions and decoded pixel buffers agree.
        // The renderer always receives the clip in display orientation.
        let rotated = naturalSize.applying(preferredTransform)
        let renderSize = CGSize(width: abs(rotated.width), height: abs(rotated.height))

        // First format description's pixel format hints at the source
        // bit depth. Used by ExportSession to pick a matching output
        // pixel format for ProRes.
        let nativePixelFormat: OSType
        var colorPrimaries: String?
        var transferFunction: String?
        var yCbCrMatrix: String?
        if let first = formatDescriptions.first {
            nativePixelFormat = CMFormatDescriptionGetMediaSubType(first)
            // Format-description extensions carry the colour tags every
            // mainstream codec writes. Reading them here lets the
            // exporter forward HDR / Rec.2020 / DCI-P3 sources with
            // their original primaries instead of silently
            // re-tagging everything BT.709 SDR.
            (colorPrimaries, transferFunction, yCbCrMatrix) = Self.readColorTags(from: first)
        } else {
            nativePixelFormat = kCVPixelFormatType_64RGBAHalf
        }

        return MediaSourceInfo(
            url: url,
            renderSize: renderSize,
            nominalFrameRate: nominalFrameRate,
            duration: duration,
            nativePixelFormat: nativePixelFormat,
            timescale: timescale,
            videoTrackID: trackID,
            preferredTransform: preferredTransform,
            colorPrimaries: colorPrimaries,
            transferFunction: transferFunction,
            yCbCrMatrix: yCbCrMatrix
        )
    }

    /// Pulls the standard colour-space extensions off a format
    /// description. AV Foundation stores them as `CFString` values
    /// keyed by the constants in `CMFormatDescription.h`. Returning
    /// the bridged Swift `String` keeps the exporter's settings
    /// dictionary plain — it can pass them straight through to
    /// `AVVideoColorPropertiesKey`.
    private static func readColorTags(
        from formatDescription: CMFormatDescription
    ) -> (primaries: String?, transfer: String?, matrix: String?) {
        let extensions = CMFormatDescriptionGetExtensions(formatDescription) as? [CFString: Any] ?? [:]
        let primaries = (extensions[kCMFormatDescriptionExtension_ColorPrimaries] as? String)
        let transfer = (extensions[kCMFormatDescriptionExtension_TransferFunction] as? String)
        let matrix = (extensions[kCMFormatDescriptionExtension_YCbCrMatrix] as? String)
        return (primaries, transfer, matrix)
    }

    /// Pulls a single frame at `time` as a Metal-compatible
    /// `CVPixelBuffer`. Used to drive the preview while the user is
    /// scrubbing or analysing — both want random access.
    ///
    /// `preferredPixelFormat` controls the requested decode format. The
    /// renderer is happy with RGBA16Float (default) or BGRA8Unorm; the
    /// reader may downgrade if the source can't produce the
    /// requested format.
    func makeFrame(
        atTime time: CMTime,
        preferredPixelFormat: OSType = kCVPixelFormatType_64RGBAHalf
    ) async throws -> CVPixelBuffer {
        try Task.checkCancellation()
        let reader = try await makeFrameReader(startTime: time, preferredPixelFormat: preferredPixelFormat)
        defer { reader.cancel() }
        try Task.checkCancellation()
        guard let frame = try reader.nextFrame() else { throw VideoSourceError.pixelBufferUnavailable }
        return frame.pixelBuffer
    }

    /// Builds an `AVAssetReader` that streams every frame of the clip
    /// in display order. Returned reader is started; callers pull
    /// sample buffers off `output` and convert them via `pixelBuffer`.
    /// Use this for the export pass — it is markedly faster than
    /// repeated `AVAssetImageGenerator` calls.
    func makeFrameReader(
        startTime: CMTime = .zero,
        preferredPixelFormat: OSType = kCVPixelFormatType_64RGBAHalf
    ) async throws -> any MediaFrameReader {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw VideoSourceError.readerSetupFailed(error)
        }
        reader.timeRange = CMTimeRange(start: startTime, end: info.duration)
        let videoTracks: [AVAssetTrack]
        do {
            videoTracks = try await asset.loadTracks(withMediaType: .video)
        } catch {
            throw VideoSourceError.readerSetupFailed(error)
        }
        guard let videoTrack = videoTracks.first else {
            throw VideoSourceError.noVideoTrack(info.url)
        }
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: preferredPixelFormat,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw VideoSourceError.readerOutputUnavailable
        }
        reader.add(output)
        try Task.checkCancellation()
        guard reader.startReading() else {
            throw VideoSourceError.readerSetupFailed(
                reader.error ?? VideoSourceError.readerOutputUnavailable
            )
        }
        return VideoFrameReader(
            reader: reader,
            output: output,
            preferredTransform: info.preferredTransform
        )
    }

}

/// Wraps an `AVAssetReader` plus its track output so callers don't
/// have to juggle the pair. Used by the export pass to pull frames in
/// display order.
final class VideoFrameReader: MediaFrameReader, @unchecked Sendable {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    let preferredTransform: CGAffineTransform
    private let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false])

    init(
        reader: AVAssetReader,
        output: AVAssetReaderTrackOutput,
        preferredTransform: CGAffineTransform
    ) {
        self.reader = reader
        self.output = output
        self.preferredTransform = preferredTransform
    }

    /// Blocks the caller until the next frame is decoded. Returns
    /// `nil` when the reader runs out of data. Throws on reader errors.
    func nextFrame() throws -> ReaderFrame? {
        guard let sample = output.copyNextSampleBuffer() else {
            switch reader.status {
            case .completed: return nil
            case .failed:
                throw reader.error ?? VideoSourceError.sampleBufferUnavailable
            case .cancelled:
                return nil
            default:
                return nil
            }
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else {
            throw VideoSourceError.pixelBufferUnavailable
        }
        let orientedBuffer: CVPixelBuffer
        if preferredTransform.isIdentity {
            orientedBuffer = pixelBuffer
        } else {
            let image = CIImage(cvPixelBuffer: pixelBuffer, options: [.colorSpace: NSNull()]).transformed(by: preferredTransform)
            let extent = image.extent.integral
            orientedBuffer = try PixelBufferTextureBridge.makeMetalCompatiblePixelBuffer(
                width: Int(extent.width), height: Int(extent.height), pixelFormat: CVPixelBufferGetPixelFormatType(pixelBuffer))
            let positioned = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            context.render(positioned, to: orientedBuffer, bounds: positioned.extent, colorSpace: nil)
            CVBufferPropagateAttachments(pixelBuffer, orientedBuffer)
        }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample)
        let duration = CMSampleBufferGetDuration(sample)
        return ReaderFrame(
            pixelBuffer: orientedBuffer,
            presentationTime: presentationTime,
            duration: duration
        )
    }

    func cancel() {
        reader.cancelReading()
    }
}

/// One frame from `VideoFrameReader`. The pixel buffer aliases AV
/// Foundation's internal buffer pool — finish using it (including any
/// GPU work) before pulling the next frame.
struct ReaderFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let presentationTime: CMTime
    let duration: CMTime
}

/// Owns one sequential decoder per playback traversal. Blocking sample reads
/// stay off the main actor; seeks and loop boundaries create a fresh reader.
actor PlaybackFrameReader {
    private let source: any EditorMediaSource
    private var reader: (any MediaFrameReader)?

    init(source: any EditorMediaSource, startTime: CMTime) async throws {
        self.source = source
        self.reader = try await source.makeFrameReader(startTime: startTime)
    }

    deinit { reader?.cancel() }

    /// Returns the decoder's timestamp and full-precision IOSurface without copying.
    func nextFrame() throws -> ReaderFrame? {
        try Task.checkCancellation()
        return try autoreleasepool { try reader?.nextFrame() }
    }

    /// AVFoundation teardown may block. Run it on the decoder actor before
    /// releasing the last reference from the main actor at a loop boundary.
    func close() {
        reader?.cancel()
        reader = nil
    }
}

/// One traversal plus its decoded first frame. Preparing this during playback
/// hides decoder startup at the seam without retaining a whole clip in memory.
struct PreparedPlaybackTraversal: Sendable {
    let reader: PlaybackFrameReader
    let firstFrame: ReaderFrame

    init(source: any EditorMediaSource, startTime: CMTime) async throws {
        let reader = try await PlaybackFrameReader(source: source, startTime: startTime)
        self.reader = reader
        guard let frame = try await reader.nextFrame() else { throw VideoSourceError.sampleBufferUnavailable }
        self.firstFrame = frame
        try Task.checkCancellation()
    }
}
