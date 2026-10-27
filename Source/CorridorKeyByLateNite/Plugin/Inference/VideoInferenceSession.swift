import Foundation
import Darwin
import Metal
import MLX
#if CORRIDOR_KEY_SPM_MIRROR
import CorridorKeyToolboxLogic
#endif

/// Signed transfer functions preserve negative and above-white scene values.
enum MLXVideoColor {
    static func displayToLinear(_ value: MLXArray) -> MLXArray {
        let magnitude = abs(value)
        let decoded = which(magnitude .<= 0.04045, magnitude / 12.92, pow((magnitude + 0.055) / 1.055, 2.4))
        return which(value .< 0, -decoded, decoded)
    }

    static func linearToDisplay(_ value: MLXArray) -> MLXArray {
        let magnitude = abs(value)
        let encoded = which(magnitude .<= 0.0031308, magnitude * 12.92,
                            1.055 * pow(maximum(magnitude, 0.0031308), 1 / 2.4) - 0.055)
        return which(value .< 0, -encoded, encoded)
    }
}

/// A completed network prediction, cropped to the source aspect ratio.
struct VideoInferenceFrame {
    let index: Int
    let alpha: [Float]
    let foregroundHalfRGBA: Data
    let source: [Float]?
    let geometry: InferenceGeometry
}

/// Failures that can be corrected without changing an editing project.
enum VideoAnalysisError: LocalizedError {
    case insufficientMemory(requiredBytes: UInt64, availableBytes: UInt64)
    case scratchFull
    case incompleteSequence
    case invalidFeatures

    var errorDescription: String? {
        switch self {
        case .insufficientMemory(let required, let available):
            "Time Awareness needs approximately \(required.formatted(.byteCount(style: .memory))) of GPU memory; \(available.formatted(.byteCount(style: .memory))) is the recommended device budget. Lower Time Awareness or Quality."
        case .scratchFull: "Analysis scratch storage is full. Free disk space or analyse a shorter range."
        case .incompleteSequence: "The source frames did not match the analysis range. Analyse Clip again."
        case .invalidFeatures: "An analysis intermediate could not be read. Analyse Clip again."
        }
    }
}

/// One analysis owns its recurrent state, scratch files and overlapping batons.
/// Callers serialize ingestion and completion. No session state lives in the shared model.
final class VideoInferenceSession: @unchecked Sendable {
    private let lock = NSLock()
    private let engine: MLXKeyingEngine
    private let settings: VideoInferenceSettings
    private let hintMode: HintMode
    let geometry: InferenceGeometry
    private let frameCount: Int
    private let needsSourceReadback: Bool
    private let scratch: URL
    private var scratchBytes: Int64 = 0
    private var ingestedCount = 0
    private var emittedCount = 0
    private var recurrentState: MLXArray
    private var retainedFeatures: [Int: [String: MLXArray]] = [:]
    private var finished = false
    private var scratchLease: Int32 = -1

    /// Creates a bounded scratch area after validating the requested model workload.
    init(engine: MLXKeyingEngine, settings: VideoInferenceSettings, hintMode: HintMode,
         geometry: InferenceGeometry, frameCount: Int, device: any MTLDevice,
         needsSourceReadback: Bool) throws {
        try settings.validate(frameCount: frameCount)
        self.engine = engine
        self.settings = settings
        self.hintMode = hintMode
        self.geometry = geometry
        self.frameCount = frameCount
        self.needsSourceReadback = needsSourceReadback
        let estimate = settings.estimatedGPUBytes(resolution: geometry.resolution, frameCount: frameCount)
        let available = device.recommendedMaxWorkingSetSize
        guard estimate <= available else {
            throw VideoAnalysisError.insufficientMemory(requiredBytes: estimate, availableBytes: available)
        }
        recurrentState = MLXArray.zeros([1, 1 + geometry.resolution * geometry.resolution / 4096, 384])
        let root = FileManager.default.temporaryDirectory.appending(path: "CorridorKey-Video-Scratch", directoryHint: .isDirectory)
        scratch = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        scratchLease = open(scratch.appending(path: ".lease").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard scratchLease >= 0, flock(scratchLease, LOCK_EX | LOCK_NB) == 0 else {
            if scratchLease >= 0 { close(scratchLease); scratchLease = -1 }
            try? FileManager.default.removeItem(at: scratch)
            throw VideoAnalysisError.scratchFull
        }
        // Remove only old abandoned passes. An active process keeps its lease,
        // even when a long analysis spans days or two hosts run simultaneously.
        for folder in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            guard folder != scratch,
                  let modified = try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  modified.timeIntervalSinceNow < -86_400 else { continue }
            let lease = open(folder.appending(path: ".lease").path, O_RDWR)
            guard lease >= 0 else { continue }
            if flock(lease, LOCK_EX | LOCK_NB) == 0 { try? FileManager.default.removeItem(at: folder) }
            close(lease)
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: scratch)
        if scratchLease >= 0 { close(scratchLease) }
    }

    /// Converts one padded normalized input to scene-linear RGB, extracts frozen
    /// features once, and carries RVM state continuously across the source clip.
    func append(normalizedInput: any MTLBuffer, frameIndex: Int) throws {
        try lock.withLock {
            try Task.checkCancellation()
            guard !finished, frameIndex == ingestedCount, frameIndex < frameCount else {
                throw VideoAnalysisError.incompleteSequence
            }
            try autoreleasepool {
                let normalized = MLXKeyingEngine.makeInputArray(buffer: normalizedInput, resolution: geometry.resolution)
                let host = normalized * MLXArray([Float(0.229), 0.224, 0.225, 1])
                    + MLXArray([Float(0.485), 0.456, 0.406, 0])
                let rgb = host[0..., 0..., 0..., 0..<3]
                let linear = settings.inputIsLinear ? rgb : MLXVideoColor.displayToLinear(rgb)
                let source = concatenated([linear, host[0..., 0..., 0..., 3..<4]], axis: -1)
                let features = try engine.evaluateVideoStage([source, recurrentState])
                guard features.count == 4 else { throw VideoAnalysisError.invalidFeatures }
                recurrentState = features[3]
                try store(["source": source, "radio": features[0], "moge": features[1], "rvm": features[2]], index: frameIndex)
            }
            ingestedCount += 1
        }
    }

    /// With Time Awareness off, finish the newly ingested frame immediately.
    /// Both hosts use this path so no whole-clip feature spill or second pass is
    /// needed. The common stage-one/stage-two implementation preserves quality.
    func finishPreparedFrame(onFrame: (VideoInferenceFrame) throws -> Void) throws {
        try lock.withLock {
            guard settings.timeAwareness == .off, !finished else { return }
            while emittedCount < ingestedCount {
                try process(indices: [emittedCount], reverseRVM: false, skipReference: false,
                            checkCancellation: { try Task.checkCancellation() }, onFrame: onFrame)
                emittedCount += 1
            }
        }
    }

    /// Completes bidirectional hint propagation and Hann baton accumulation.
    /// Emitted indices can run backwards for a single-frame reference; hosts
    /// key their output cache by source index rather than delivery order.
    func finish(checkCancellation: () throws -> Void = { try Task.checkCancellation() }, onFrame: (VideoInferenceFrame) throws -> Void) throws {
        try lock.withLock {
            guard !finished, ingestedCount == frameCount else { throw VideoAnalysisError.incompleteSequence }
            defer {
                finished = true
                retainedFeatures.removeAll()
                try? FileManager.default.removeItem(at: scratch)
            }
            if settings.timeAwareness == .off {
                while emittedCount < ingestedCount {
                    try process(indices: [emittedCount], reverseRVM: false, skipReference: false,
                                checkCancellation: checkCancellation, onFrame: onFrame)
                    emittedCount += 1
                }
                return
            }
            if settings.useAlphaHint, settings.hintFrames == .singleFrame {
                let reference = settings.referenceFrame
                try process(indices: Array(reference..<frameCount), reverseRVM: false, skipReference: false, checkCancellation: checkCancellation, onFrame: onFrame)
                if reference > 0 {
                    try process(indices: Array((0...reference).reversed()), reverseRVM: true, skipReference: true, checkCancellation: checkCancellation, onFrame: onFrame)
                }
            } else {
                try process(indices: Array(0..<frameCount), reverseRVM: false, skipReference: false, checkCancellation: checkCancellation, onFrame: onFrame)
            }
        }
    }

    private func process(indices: [Int], reverseRVM: Bool, skipReference: Bool,
                         checkCancellation: () throws -> Void,
                         onFrame: (VideoInferenceFrame) throws -> Void) throws {
        let windowSize = settings.timeAwareness.effectiveFrameCount(for: indices.count)
        let plan = TemporalWindow.plan(frameCount: indices.count, window: windowSize)
        var accumulated: [Int: MLXArray] = [:]
        var weights: [Int: Float] = [:]
        var carry: [Int: MLXArray] = [:]
        var reverseFeatures: [Int: MLXArray] = [:]
        var reverseState = MLXArray.zeros([1, 1 + geometry.resolution * geometry.resolution / 4096, 384])
        var reverseCursor = 0
        for (windowIndex, window) in plan.enumerated() {
            try checkCancellation()
            try autoreleasepool {
                var sources: [MLXArray] = []
                var radio: [MLXArray] = []
                var moge: [MLXArray] = []
                var rvm: [MLXArray] = []
                var confidence: [Float] = []
                let localIndices = Array(window.start..<(window.start + window.count))
                for position in localIndices {
                    try checkCancellation()
                    let index = indices[position]
                    let feature = try load(index: index)
                    guard var source = feature["source"], let radioFrame = feature["radio"],
                          let mogeFrame = feature["moge"], let rvmFrame = feature["rvm"] else {
                        throw VideoAnalysisError.invalidFeatures
                    }
                    var quality: Float = hintMode == .none ? -1 : Float(settings.alphaHintStrength)
                    if settings.useAlphaHint {
                        quality = settings.hintFrames == .allFrames || index == settings.referenceFrame
                            ? Float(settings.alphaHintStrength) : 0
                    }
                    if quality <= 0 {
                        source = concatenated([source[0..., 0..., 0..., 0..<3],
                                               MLXArray.zeros([1, geometry.resolution, geometry.resolution, 1])], axis: -1)
                    }
                    if let prior = carry[position] {
                        source = concatenated([source[0..., 0..., 0..., 0..<3], prior.expandedDimensions(axis: 0)], axis: -1)
                        quality = Float(settings.internalHintStrength)
                    }
                    // The explicit reference always wins over propagated hints.
                    if settings.useAlphaHint, settings.hintFrames == .singleFrame, index == settings.referenceFrame,
                       let original = feature["source"] {
                        source = original
                        quality = Float(settings.alphaHintStrength)
                    }
                    sources.append(source)
                    radio.append(radioFrame)
                    moge.append(mogeFrame)
                    if reverseRVM {
                        // Backward propagation has its own chronological RVM
                        // state; never reuse a future frame's forward state.
                        while reverseCursor <= position {
                            let reverseInput = try load(index: indices[reverseCursor])
                            guard let rgb = reverseInput["source"] else { throw VideoAnalysisError.invalidFeatures }
                            let extracted = try engine.evaluateVideoStage([rgb, reverseState])
                            reverseState = extracted[3]
                            reverseFeatures[reverseCursor] = extracted[2]
                            reverseCursor += 1
                        }
                        guard let reversed = reverseFeatures[position] else { throw VideoAnalysisError.invalidFeatures }
                        rvm.append(reversed)
                    } else {
                        rvm.append(rvmFrame)
                    }
                    confidence.append(quality)
                }
                // No user/model hint anywhere in this window uses v2's -1 sentinel.
                if !confidence.contains(where: { $0 > 0 }) { confidence = confidence.map { _ in -1 } }
                guard let lastSource = sources.last, let lastRadio = radio.last,
                      let lastMoge = moge.last, let lastRVM = rvm.last, let lastQuality = confidence.last else {
                    throw VideoAnalysisError.incompleteSequence
                }
                while sources.count < windowSize {
                    sources.append(lastSource); radio.append(lastRadio); moge.append(lastMoge)
                    rvm.append(lastRVM); confidence.append(lastQuality)
                }
                let temporal = try engine.evaluateVideoStage([
                    concatenated(sources, axis: 0), MLXArray(confidence, [1, windowSize]),
                    stacked(radio, axis: 1), stacked(moge, axis: 1), stacked(rvm, axis: 1)
                ])
                guard temporal.count == 2 else { throw VideoAnalysisError.invalidFeatures }
                for (offset, position) in localIndices.enumerated() {
                    let contribution = temporal[0][0, offset] * window.weights[offset]
                    accumulated[position] = accumulated[position].map { $0 + contribution } ?? contribution
                    weights[position, default: 0] += window.weights[offset]
                    carry[position] = temporal[1][offset]
                }
                // Materialize and detach window views before releasing its graph.
                for position in localIndices {
                    if let baton = accumulated[position], let hint = carry[position] {
                        let materializedBaton = contiguous(baton)
                        let materializedHint = contiguous(hint)
                        try checkedEval(materializedBaton, materializedHint)
                        accumulated[position] = materializedBaton
                        carry[position] = materializedHint
                    }
                }
                let nextStart = windowIndex + 1 < plan.count ? plan[windowIndex + 1].start : indices.count
                for position in accumulated.keys.sorted() where position < nextStart {
                    guard let baton = accumulated.removeValue(forKey: position),
                          let weight = weights.removeValue(forKey: position), weight > 0 else {
                        throw VideoAnalysisError.invalidFeatures
                    }
                    if !(skipReference && position == 0) {
                        try checkCancellation()
                        let feature = try load(index: indices[position])
                        guard let source = feature["source"] else { throw VideoAnalysisError.invalidFeatures }
                        let normalized = (baton / weight).asType(.float16).asType(.float32)
                            .reshaped([1, 1, 512, geometry.resolution / 16, geometry.resolution / 16])
                        let output = try engine.evaluateVideoStage([source, normalized, MLXArray.zeros([0])])
                        try onFrame(try makeFrame(index: indices[position], source: source, output: output))
                    }
                    carry.removeValue(forKey: position)
                    reverseFeatures.removeValue(forKey: position)
                    retainedFeatures.removeValue(forKey: indices[position])
                }
            }
        }
    }

    private func makeFrame(index: Int, source: MLXArray, output: [MLXArray]) throws -> VideoInferenceFrame {
        guard output.count == 2 else { throw VideoAnalysisError.invalidFeatures }
        let rows = geometry.offsetY..<(geometry.offsetY + geometry.contentHeight)
        let columns = geometry.offsetX..<(geometry.offsetX + geometry.contentWidth)
        let alpha = contiguous(output[0][0, rows, columns, 0])
        let foreground = MLXVideoColor.linearToDisplay(output[1][0, rows, columns])
        let rgba = contiguous(concatenated([foreground, MLXArray.ones([geometry.contentHeight, geometry.contentWidth, 1])], axis: -1).asType(.float16))
        try checkedEval(alpha, rgba)
        var sourcePixels: [Float]?
        if needsSourceReadback {
            let rgb = MLXVideoColor.linearToDisplay(source[0, rows, columns, 0..<3])
            let sourceRGBA = concatenated([rgb, MLXArray.ones([geometry.contentHeight, geometry.contentWidth, 1])], axis: -1)
            try checkedEval(sourceRGBA)
            sourcePixels = sourceRGBA.asArray(Float.self)
        }
        return VideoInferenceFrame(index: index, alpha: alpha.asArray(Float.self),
                                   foregroundHalfRGBA: rgba.asData().data, source: sourcePixels, geometry: geometry)
    }

    private func store(_ arrays: [String: MLXArray], index: Int) throws {
        // A still has no overlap or clip history to spill to disk. Materialize
        // its one input before the caller can reuse the normalized Metal buffer.
        if frameCount == 1 || settings.timeAwareness == .off {
            try checkedEval(Array(arrays.values))
            retainedFeatures[index] = arrays
            return
        }
        let bytes = arrays.values.reduce(Int64(0)) { $0 + Int64($1.size * 4) }
        let remaining = try scratch.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage ?? Int64.max
        guard scratchBytes + bytes < 64 * 1024 * 1024 * 1024, remaining > bytes + 512 * 1024 * 1024 else {
            throw VideoAnalysisError.scratchFull
        }
        try MLX.save(arrays: arrays, url: fileURL(index: index))
        scratchBytes += bytes
    }

    private func load(index: Int) throws -> [String: MLXArray] {
        if let retained = retainedFeatures[index] { return retained }
        let arrays = try MLX.loadArrays(url: fileURL(index: index))
        guard arrays["source"]?.shape == [1, geometry.resolution, geometry.resolution, 4] else {
            throw VideoAnalysisError.invalidFeatures
        }
        if !settings.lowGPUMemory { retainedFeatures[index] = arrays }
        return arrays
    }

    private func fileURL(index: Int) -> URL { scratch.appending(path: "\(index).safetensors") }
}
