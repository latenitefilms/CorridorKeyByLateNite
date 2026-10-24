//
//  StillImageSource.swift
//  CorridorKey by LateNite — Standalone Editor
//

import Foundation
import CoreImage
import CoreMedia
import CoreVideo
import ImageIO
import Synchronization

/// Recoverable failures when an image cannot enter the Metal render pipeline.
enum StillImageSourceError: Error, LocalizedError {
    case cannotDecode(URL)
    case unsupportedDimensions

    var errorDescription: String? {
        switch self {
        case .cannotDecode(let url):
            return "Couldn't read \(url.lastPathComponent). Choose a supported image such as PNG, TIFF, JPEG, or HEIC."
        case .unsupportedDimensions:
            return "This image is too large to render. Choose an image no larger than 16,384 pixels on either side."
        }
    }
}

/// Decodes the primary image once, applies EXIF orientation, and retains an
/// immutable half-float buffer. The model, preview, and exporter share that buffer
/// without repeating disk reads or image decompression for every parameter edit.
/// Core Video is not Sendable; the buffer is read-only after initialization.
final class StillImageSource: EditorMediaSource, @unchecked Sendable {
    let info: MediaSourceInfo
    private let pixelBuffer: CVPixelBuffer
    private static let context = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])

    /// Decodes at native resolution off the caller's actor. Sandbox access ends
    /// after the eager render, so no lazy file reads outlive the permission scope.
    init(url: URL) async throws {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer { if didStartAccessing { url.stopAccessingSecurityScopedResource() } }
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw StillImageSourceError.cannotDecode(url)
        }
        let primaryIndex = CGImageSourceGetPrimaryImageIndex(source)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, primaryIndex, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else {
            throw StillImageSourceError.cannotDecode(url)
        }
        // Apple Silicon's maximum 2D texture dimension. Check before decoding
        // to avoid allocating an image the renderer cannot use.
        guard width <= 16_384, height <= 16_384 else {
            throw StillImageSourceError.unsupportedDimensions
        }
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false, kCGImageSourceShouldAllowFloat: true]
        guard let decoded = CGImageSourceCreateImageAtIndex(source, primaryIndex, options as CFDictionary) else {
            throw StillImageSourceError.cannotDecode(url)
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.int32Value ?? 1
        let oriented = CIImage(cgImage: decoded).oriented(forExifOrientation: orientation)
        let image = oriented.transformed(by: CGAffineTransform(
            translationX: -oriented.extent.minX, y: -oriented.extent.minY
        ))
        let buffer = try PixelBufferTextureBridge.makeMetalCompatiblePixelBuffer(
            width: Int(image.extent.width), height: Int(image.extent.height),
            pixelFormat: kCVPixelFormatType_64RGBAHalf
        )
        Self.context.render(image, to: buffer, bounds: image.extent,
                            colorSpace: CGColorSpace(name: CGColorSpace.extendedSRGB))
        try Task.checkCancellation()
        self.pixelBuffer = buffer
        self.info = MediaSourceInfo(
            kind: .stillImage, url: url, renderSize: image.extent.size,
            // A single logical frame gives subject hints a valid time range.
            // This interval is never exposed as image playback or duration.
            nominalFrameRate: 1, duration: CMTime(value: 1, timescale: 1),
            nativePixelFormat: kCVPixelFormatType_64RGBAHalf, timescale: 1,
            videoTrackID: kCMPersistentTrackID_Invalid, preferredTransform: .identity,
            colorPrimaries: nil, transferFunction: nil, yCbCrMatrix: nil,
            imageColorSpace: decoded.colorSpace?.model == .rgb ? decoded.colorSpace : nil
        )
    }

    /// Reuses the decoded image; lower-precision requests are converted for probes.
    func makeFrame(
        atTime time: CMTime,
        preferredPixelFormat: OSType = kCVPixelFormatType_64RGBAHalf
    ) async throws -> CVPixelBuffer {
        try Task.checkCancellation()
        guard preferredPixelFormat != kCVPixelFormatType_64RGBAHalf else { return pixelBuffer }
        let converted = try PixelBufferTextureBridge.makeMetalCompatiblePixelBuffer(
            width: Int(info.renderSize.width), height: Int(info.renderSize.height), pixelFormat: preferredPixelFormat
        )
        let colorSpace = CGColorSpace(name: CGColorSpace.extendedSRGB) ?? CGColorSpaceCreateDeviceRGB()
        let image = CIImage(cvPixelBuffer: pixelBuffer, options: [.colorSpace: colorSpace])
        Self.context.render(image, to: converted, bounds: image.extent, colorSpace: colorSpace)
        return converted
    }

    /// Each reader yields the image exactly once, at time zero.
    func makeFrameReader(
        startTime: CMTime = .zero,
        preferredPixelFormat: OSType = kCVPixelFormatType_64RGBAHalf
    ) async throws -> any MediaFrameReader {
        let buffer = try await makeFrame(atTime: .zero, preferredPixelFormat: preferredPixelFormat)
        let frame = startTime > .zero ? nil : ReaderFrame(
            pixelBuffer: buffer, presentationTime: .zero, duration: info.duration
        )
        return StillImageFrameReader(frame: frame)
    }
}

/// Synchronizes consuming or cancelling the single retained frame.
private final class StillImageFrameReader: MediaFrameReader {
    private let pendingFrame: Mutex<ReaderFrame?>

    init(frame: ReaderFrame?) { pendingFrame = Mutex(frame) }

    func nextFrame() throws -> ReaderFrame? {
        pendingFrame.withLock { frame in
            defer { frame = nil }
            return frame
        }
    }

    func cancel() { pendingFrame.withLock { $0 = nil } }
}
