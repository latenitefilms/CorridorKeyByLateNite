import AVFoundation
import CoreImage
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers
#if CORRIDOR_KEY_SPM_MIRROR
import CorridorKeyToolboxLogic
#endif

/// Reads a user-selected still or synchronized movie while retaining sandbox access.
/// Metadata loads asynchronously; frame decoding is serialized by the analysis owner.
final class AlphaHintReader: @unchecked Sendable {
    private let url: URL
    private let accessing: Bool
    private let settings: VideoInferenceSettings
    private let still: CIImage?
    private let reader: AVAssetReader?
    private let output: AVAssetReaderTrackOutput?
    private let transform: CGAffineTransform
    private let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false])
    private var nextIndex = 0
    /// A folder grant permits lazy reads of a naturally ordered image sequence.
    private var sequence: [URL] = []

    /// Validates duration and frame rate before the first source frame is processed.
    init(settings: VideoInferenceSettings, frameCount: Int, frameDuration: CMTime, previewFrame: Int? = nil) async throws {
        guard let asset = settings.alphaHintAsset else { throw VideoInferenceSettingsError.missingHint }
        let url = try asset.resolvedURL()
        self.url = url
        accessing = url.startAccessingSecurityScopedResource()
        self.settings = settings
        do {
            if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                guard settings.hintFrames == .allFrames else { throw VideoInferenceSettingsError.hintSequenceMismatch }
                sequence = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                    .filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                guard !sequence.isEmpty, previewFrame != nil || sequence.count == frameCount else {
                    throw VideoInferenceSettingsError.hintSequenceMismatch
                }
                still = nil
                reader = nil
                output = nil
                transform = .identity
            } else if let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
                      CGImageSourceGetCount(imageSource) > 0 {
                // ImageIO can return a non-nil, zero-image source for a movie.
                // Only decoded image entries distinguish stills from AV assets.
                guard settings.hintFrames == .singleFrame || frameCount == 1 || previewFrame != nil,
                      let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true, .colorSpace: NSNull()]) else {
                    throw VideoInferenceSettingsError.hintSequenceMismatch
                }
                still = image
                reader = nil
                output = nil
                transform = .identity
            } else {
                guard settings.hintFrames == .allFrames else { throw VideoInferenceSettingsError.hintSequenceMismatch }
                let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
                guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                    throw VideoInferenceSettingsError.hintSequenceMismatch
                }
                let duration = try await asset.load(.duration)
                let rate = try await track.load(.nominalFrameRate)
                let seconds = frameDuration.seconds
                guard previewFrame != nil || (seconds.isFinite && seconds > 0 &&
                      abs(Double(rate) * seconds - 1) < 0.001 &&
                      abs(duration.seconds / seconds - Double(frameCount)) < 0.51) else {
                    throw VideoInferenceSettingsError.hintSequenceMismatch
                }
                transform = try await track.load(.preferredTransform)
                let reader = try AVAssetReader(asset: asset)
                if let previewFrame {
                    guard rate > 0 else { throw VideoInferenceSettingsError.hintSequenceMismatch }
                    reader.timeRange = CMTimeRange(start: CMTime(seconds: Double(previewFrame) / Double(rate), preferredTimescale: 600_000), end: duration)
                    nextIndex = previewFrame
                }
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:]
                ])
                output.alwaysCopiesSampleData = false
                guard reader.canAdd(output) else { throw VideoInferenceSettingsError.hintSequenceMismatch }
                reader.add(output)
                guard reader.startReading() else { throw reader.error ?? VideoAnalysisError.invalidFeatures }
                self.reader = reader
                self.output = output
                still = nil
            }
        } catch {
            if accessing { url.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    deinit {
        reader?.cancelReading()
        if accessing { url.stopAccessingSecurityScopedResource() }
    }

    /// Returns a top-down plate; RGB luminance supplies the matte and transparency
    /// naturally removes transparent pixels. No display gamma is applied to mask values.
    func texture(frameIndex: Int, sourceWidth: Int, sourceHeight: Int,
                 device: any MTLDevice, commandQueue: any MTLCommandQueue) throws -> (any MTLTexture)? {
        if settings.hintFrames == .singleFrame, frameIndex != settings.referenceFrame { return nil }
        let image: CIImage
        if !sequence.isEmpty {
            guard sequence.indices.contains(frameIndex),
                  let frame = CIImage(contentsOf: sequence[frameIndex], options: [.applyOrientationProperty: true, .colorSpace: NSNull()]) else {
                throw VideoInferenceSettingsError.hintSequenceMismatch
            }
            image = frame
        } else if let still {
            image = still
        } else {
            guard frameIndex == nextIndex, let sample = output?.copyNextSampleBuffer(),
                  let buffer = CMSampleBufferGetImageBuffer(sample) else {
                throw reader?.error ?? VideoInferenceSettingsError.hintSequenceMismatch
            }
            nextIndex += 1
            image = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()]).transformed(by: transform)
        }
        let extent = image.extent.integral
        guard Int(extent.width) == sourceWidth, Int(extent.height) == sourceHeight else {
            throw VideoInferenceSettingsError.hintDimensionsMismatch
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                                  width: sourceWidth, height: sourceHeight, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        guard let texture = device.makeTexture(descriptor: descriptor),
              let commandBuffer = commandQueue.makeCommandBuffer() else { throw VideoAnalysisError.invalidFeatures }
        let luminance = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        let positioned = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .applyingFilter("CIColorMatrix", parameters: ["inputRVector": luminance,
                                                         "inputGVector": luminance, "inputBVector": luminance])
        // CI renders Metal textures in bottom-up raster order, unlike its
        // CVPixelBuffer destination. The model and cached frames are top-down.
        let topDown = positioned.transformed(by: CGAffineTransform(scaleX: 1, y: -1))
            .transformed(by: CGAffineTransform(translationX: 0, y: extent.height))
        context.render(topDown, to: texture, commandBuffer: commandBuffer,
                       bounds: CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight), colorSpace: CGColorSpaceCreateDeviceRGB())
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error { throw error }
        return texture
    }
}

/// FxAnalyzer has synchronous callbacks. Metadata still loads in a Swift
/// task; only its synchronous consumer waits at the API boundary.
final class DeferredAlphaHintReader: @unchecked Sendable {
    private let condition = NSCondition()
    private var result: Result<AlphaHintReader, any Error>?
    private var task: Task<Void, Never>?

    init(settings: VideoInferenceSettings, frameCount: Int, frameDuration: CMTime, previewFrame: Int? = nil) {
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<AlphaHintReader, any Error>
            do { result = .success(try await AlphaHintReader(settings: settings, frameCount: frameCount, frameDuration: frameDuration, previewFrame: previewFrame)) }
            catch { result = .failure(error) }
            self?.complete(result)
        }
    }

    deinit { task?.cancel() }

    private func complete(_ result: Result<AlphaHintReader, any Error>) {
        condition.lock()
        self.result = result
        condition.broadcast()
        condition.unlock()
    }

    /// Metadata errors propagate to the host's analysis error UI.
    func waitForReader() throws -> AlphaHintReader {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(60)
        while result == nil {
            guard condition.wait(until: deadline) else { throw VideoAnalysisError.invalidFeatures }
        }
        guard let result else { throw VideoAnalysisError.invalidFeatures }
        return try result.get()
    }
}
