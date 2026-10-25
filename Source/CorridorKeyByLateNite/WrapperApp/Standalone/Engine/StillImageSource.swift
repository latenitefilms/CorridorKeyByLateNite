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
    private static let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false])
    private static let managedContext = CIContext(options: [.cacheIntermediates: false])

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
        let profileName = decoded.colorSpace?.name as String? ?? ""
        let preservesEncoding = profileName.contains("sRGB") || profileName.contains("P3") || profileName.contains("2020")
        // Known working gamuts retain their stored transfer for Input is Linear.
        // Other ICC profiles still receive Core Image's color-managed conversion.
        let decodedImage = preservesEncoding ? CIImage(cgImage: decoded, options: [.colorSpace: NSNull()]) : CIImage(cgImage: decoded)
        let oriented = decodedImage.oriented(forExifOrientation: orientation)
        let image = oriented.transformed(by: CGAffineTransform(
            translationX: -oriented.extent.minX, y: -oriented.extent.minY
        ))
        let buffer = try PixelBufferTextureBridge.makeMetalCompatiblePixelBuffer(
            width: Int(image.extent.width), height: Int(image.extent.height),
            pixelFormat: kCVPixelFormatType_64RGBAHalf
        )
        if preservesEncoding {
            Self.context.render(image, to: buffer, bounds: image.extent, colorSpace: nil)
        } else {
            let outputProfile = profileName.contains("Linear") ? CGColorSpace.extendedLinearSRGB : CGColorSpace.extendedSRGB
            Self.managedContext.render(image, to: buffer, bounds: image.extent, colorSpace: CGColorSpace(name: outputProfile))
        }
        let primaries = profileName.contains("P3") ? kCVImageBufferColorPrimaries_P3_D65
            : (profileName.contains("2020") ? kCVImageBufferColorPrimaries_ITU_R_2020 : kCVImageBufferColorPrimaries_ITU_R_709_2)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, primaries, .shouldPropagate)
        try Task.checkCancellation()
        self.pixelBuffer = buffer
        self.info = MediaSourceInfo(
            kind: .stillImage, url: url, renderSize: image.extent.size,
            // A single logical frame gives subject hints a valid time range.
            // This interval is never exposed as image playback or duration.
            nominalFrameRate: 1, duration: CMTime(value: 1, timescale: 1),
            nativePixelFormat: kCVPixelFormatType_64RGBAHalf, timescale: 1,
            videoTrackID: kCMPersistentTrackID_Invalid, preferredTransform: .identity,
            colorPrimaries: primaries as String, transferFunction: nil, yCbCrMatrix: nil,
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
        let image = CIImage(cvPixelBuffer: pixelBuffer, options: [.colorSpace: NSNull()])
        Self.context.render(image, to: converted, bounds: image.extent, colorSpace: nil)
        CVBufferPropagateAttachments(pixelBuffer, converted)
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
