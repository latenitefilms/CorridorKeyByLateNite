import Foundation
import CoreMedia

/// Compares the old random-access playback pattern with sequential decoding.
/// Build with the four production adapters listed in Standalone-playback.md.
@main
struct PlaybackDecodeBenchmark {
    static func main() async throws {
        guard let path = CommandLine.arguments.dropFirst().first else {
            print("Usage: BenchmarkPlayback /path/to/video.mov")
            return
        }
        let source = try await VideoSource(url: URL(filePath: path))
        let count = source.totalFrameCount()
        let clock = ContinuousClock()
        print("Source: \(source.info.renderSize), \(source.info.nominalFrameRate) fps, \(count) frames")
        for sequential in [false, true] {
            let start = clock.now
            var decoded = 0
            for _ in 0..<3 {
                if sequential {
                    let reader = try await source.makeFrameReader()
                    defer { reader.cancel() }
                    while let frame = try reader.nextFrame() {
                        withExtendedLifetime(frame) {}
                        decoded += 1
                    }
                } else {
                    for index in 0..<count {
                        let buffer = try await source.makeFrame(atTime: CMTime(
                            seconds: Double(index) / Double(source.info.nominalFrameRate),
                            preferredTimescale: source.info.timescale))
                        withExtendedLifetime(buffer) {}
                        decoded += 1
                    }
                }
            }
            let elapsed = start.duration(to: clock.now).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            print("\(sequential ? "Sequential" : "Per-frame seek"): \(decoded) frames in \(seconds) seconds; \(Double(decoded) / seconds) fps")
        }
    }
}
