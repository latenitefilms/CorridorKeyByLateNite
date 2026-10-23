import Foundation
import Testing
@testable import CorridorKeyToolboxLogic

@Suite("Complete analysis frame codec")
struct AnalysisFrameCodecTests {
    @Test("Alpha clamps while signed and above-white straight RGB survive", arguments: [1, 128])
    func roundTrip(side: Int) throws {
        let count = side * side
        let alpha = (0..<count).map { Float($0 % 5) / 2 - 0.25 }
        let foreground = Array(repeating: [Float]([-0.125, 0.375, 3.5, 1]), count: count).flatMap { $0 }
        let half = try AnalysisFrameCodec.foregroundHalfRGBA(foreground)
        let blob = try AnalysisFrameCodec.encode(alpha: alpha, foregroundHalfRGBA: half, width: side, height: side)
        let header = try #require(AnalysisFrameCodec.parseHeader(blob))
        #expect(header.width == side && header.height == side)
        var raw = Data(count: header.decodedByteCount)
        #expect(raw.withUnsafeMutableBytes { AnalysisFrameCodec.decode(blob, into: $0) })
        #expect(raw.suffix(from: header.alphaByteCount) == half)
        raw.withUnsafeBytes { bytes in
            for index in alpha.indices {
                let value = Float(Float16(bitPattern: bytes.loadUnaligned(fromByteOffset: index * 2, as: UInt16.self)))
                #expect(value == max(0, min(1, alpha[index])))
            }
        }
        // A one-pixel payload cannot pay the LZ4 framing overhead; large flat
        // images exercise compression. Both storage paths must decode exactly.
        #expect(side == 1 ? blob.count == 26 : blob.count < raw.count / 10)
    }

    @Test("Malformed and legacy frames cannot enter cached playback")
    func malformed() throws {
        let foreground = try AnalysisFrameCodec.foregroundHalfRGBA([Float](repeating: 0.5, count: 64 * 64 * 4))
        let blob = try AnalysisFrameCodec.encode(alpha: [Float](repeating: 1, count: 64 * 64),
                                               foregroundHalfRGBA: foreground, width: 64, height: 64)
        var raw = Data(count: 64 * 64 * 10)
        var corruptions = [Data(blob.prefix(10)), Data(blob.dropLast()), blob + Data([1]), Data("CKM1".utf8)]
        var badSize = blob
        badSize.replaceSubrange(4..<8, with: [255, 255, 255, 127])
        corruptions.append(badSize)
        var badStorage = blob
        badStorage[12] = 2
        corruptions.append(badStorage)
        for corrupt in corruptions {
            #expect(!raw.withUnsafeMutableBytes { AnalysisFrameCodec.decode(corrupt, into: $0) })
        }
        var small = Data(count: raw.count - 1)
        #expect(!small.withUnsafeMutableBytes { AnalysisFrameCodec.decode(blob, into: $0) })
        // A Data slice has a nonzero start index; parsing must not assume alignment.
        let padded = Data([0]) + blob
        #expect(raw.withUnsafeMutableBytes { AnalysisFrameCodec.decode(padded.dropFirst(), into: $0) })
        #expect(throws: MatteCodecError.self) {
            try AnalysisFrameCodec.encode(alpha: [1], foregroundHalfRGBA: foreground, width: 1, height: 1)
        }
        #expect(throws: MatteCodecError.self) {
            try AnalysisFrameCodec.encode(alpha: [], foregroundHalfRGBA: Data(), width: Int.max, height: 1)
        }
    }
}
