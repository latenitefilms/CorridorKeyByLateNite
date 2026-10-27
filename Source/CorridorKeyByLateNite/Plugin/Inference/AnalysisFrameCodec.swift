import Accelerate
import Compression
import Foundation

/// Persists both v2 predictions in source row order, before user refinement.
///
/// CKF1 stores a 16-byte little-endian header (magic, width, height, storage)
/// followed by an R16F alpha plane and an RGBA16F straight foreground plane.
/// Only alpha is clamped. Signed and above-white foreground values survive.
/// LZ4 prioritizes playback latency; incompressible frames use raw storage.
/// Playback decompresses directly into reusable shared Metal memory and uploads
/// half-float textures without allocating float arrays or converting on the CPU.
public enum AnalysisFrameCodec {
    /// Validated dimensions and storage mode of a complete frame envelope.
    public struct Header: Sendable {
        /// Inference width, in pixels.
        public let width: Int
        /// Inference height, in pixels.
        public let height: Int
        fileprivate let storage: UInt32

        /// Size of the decoded alpha plane, in bytes.
        public var alphaByteCount: Int { width * height * 2 }
        /// Size of both decoded planes, in bytes.
        public var decodedByteCount: Int { width * height * 10 }
    }

    private static let magic = Array("CKF1".utf8)
    private static let headerByteCount = 16
    private static let maximumSide = 4096

    /// Converts interleaved float RGBA to half precision with Accelerate.
    /// The result can be retained while temporal stability adjusts alpha.
    public static func foregroundHalfRGBA(_ foreground: [Float]) throws -> Data {
        guard !foreground.isEmpty, foreground.count.isMultiple(of: 4) else {
            throw MatteCodecError.invalidSize
        }
        var result = Data(count: foreground.count * 2)
        try result.withUnsafeMutableBytes { destination in
            try convertToHalf(foreground, into: destination)
        }
        return result
    }

    /// Encodes a complete frame. Foreground is already RGBA16F and is never
    /// premultiplied by alpha, including after temporal blending.
    public static func encode(
        alpha: [Float], foregroundHalfRGBA: Data, width: Int, height: Int
    ) throws -> Data {
        guard validDimensions(width: width, height: height) else {
            throw MatteCodecError.dimensionsOutOfBounds
        }
        let pixelCount = width * height
        guard alpha.count == pixelCount, foregroundHalfRGBA.count == pixelCount * 8 else {
            throw MatteCodecError.invalidSize
        }
        var raw = Data(count: pixelCount * 10)
        var clamped = [Float](repeating: 0, count: pixelCount)
        vDSP.clip(alpha, to: 0...1, result: &clamped)
        try raw.withUnsafeMutableBytes { destination in
            try convertToHalf(clamped, into: UnsafeMutableRawBufferPointer(rebasing: destination[..<(pixelCount * 2)]))
            foregroundHalfRGBA.copyBytes(to: UnsafeMutableRawBufferPointer(rebasing: destination[(pixelCount * 2)...]))
        }

        // A same-sized destination bounds peak allocation and makes raw storage
        // the fallback whenever compression cannot reduce this frame's size.
        var compressed = Data(count: raw.count)
        let compressedCount = compressed.withUnsafeMutableBytes { destination in
            raw.withUnsafeBytes { source in
                guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress,
                      let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(
                    destinationBase, destination.count,
                    sourceBase, source.count,
                    nil, COMPRESSION_LZ4
                )
            }
        }
        let useCompression = compressedCount > 0 && compressedCount < raw.count
        var output = Data(magic)
        for value in [UInt32(width), UInt32(height), useCompression ? UInt32(1) : UInt32(0)] {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { output.append(contentsOf: $0) }
        }
        output.append(useCompression ? compressed.prefix(compressedCount) : raw)
        return output
    }

    /// Rejects legacy alpha-only caches, unknown storage, truncated headers,
    /// unreasonable dimensions, and payloads larger than their raw frame.
    public static func parseHeader(_ blob: Data) -> Header? {
        guard blob.count > headerByteCount, blob.prefix(4).elementsEqual(magic) else { return nil }
        let fields = blob.withUnsafeBytes { bytes in
            (bytes.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian,
             bytes.loadUnaligned(fromByteOffset: 8, as: UInt32.self).littleEndian,
             bytes.loadUnaligned(fromByteOffset: 12, as: UInt32.self).littleEndian)
        }
        let width = Int(fields.0)
        let height = Int(fields.1)
        guard validDimensions(width: width, height: height), fields.2 <= 1 else { return nil }
        let header = Header(width: width, height: height, storage: fields.2)
        let payloadCount = blob.count - headerByteCount
        guard payloadCount <= header.decodedByteCount,
              fields.2 != 0 || payloadCount == header.decodedByteCount else { return nil }
        return header
    }

    /// Decodes directly into caller-owned memory. A successful decode requires
    /// an end-of-stream marker, exact decoded size and no trailing input.
    public static func decode(_ blob: Data, into destination: UnsafeMutableRawBufferPointer) -> Bool {
        guard let header = parseHeader(blob), destination.count >= header.decodedByteCount,
              let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress else { return false }
        return blob.withUnsafeBytes { source in
            guard let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else { return false }
            let payload = sourceBase.advanced(by: headerByteCount)
            let payloadCount = source.count - headerByteCount
            if header.storage == 0 {
                destinationBase.update(from: payload, count: header.decodedByteCount)
                return true
            }
            var stream = compression_stream(
                dst_ptr: destinationBase, dst_size: header.decodedByteCount,
                src_ptr: payload, src_size: payloadCount, state: nil
            )
            guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZ4) == COMPRESSION_STATUS_OK else {
                return false
            }
            defer { compression_stream_destroy(&stream) }
            stream.dst_ptr = destinationBase
            stream.dst_size = header.decodedByteCount
            stream.src_ptr = payload
            stream.src_size = payloadCount
            let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
            return status == COMPRESSION_STATUS_END && stream.dst_size == 0 && stream.src_size == 0
        }
    }

    private static func validDimensions(width: Int, height: Int) -> Bool {
        width > 0 && height > 0 && width <= maximumSide && height <= maximumSide
    }

    private static func convertToHalf(_ values: [Float], into destination: UnsafeMutableRawBufferPointer) throws {
        try values.withUnsafeBufferPointer { source in
            guard let sourceBase = source.baseAddress, let destinationBase = destination.baseAddress else {
                throw MatteCodecError.invalidSize
            }
            var input = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: sourceBase), height: 1,
                                      width: vImagePixelCount(values.count), rowBytes: values.count * 4)
            var output = vImage_Buffer(data: destinationBase, height: 1,
                                       width: vImagePixelCount(values.count), rowBytes: values.count * 2)
            guard vImageConvert_PlanarFtoPlanar16F(&input, &output, vImage_Flags(kvImageNoFlags)) == kvImageNoError else {
                throw MatteCodecError.compressionFailed
            }
        }
    }
}
