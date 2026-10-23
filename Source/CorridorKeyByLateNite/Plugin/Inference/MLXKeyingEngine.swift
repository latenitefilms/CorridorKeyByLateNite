//
//  MLXKeyingEngine.swift
//  CorridorKey by LateNite
//
//  Loads a CorridorKey `.mlxfn` bridge via mlx-swift's public
//  `ImportedFunction` API and runs inference for one frame at a time. The
//  v2 bridge is exported and validated by Tools/CorridorKeyV2. It includes
//  both keying stages and all three frozen foundation models. Single-frame
//  mode keeps results deterministic when the host requests frames out of order.
//
//  Apple Silicon's unified memory means the Metal↔MLX hand-off is mostly a
//  pointer copy; MLX schedules inference on the Metal GPU.
//

import Foundation
import Metal
import MLX
import Cmlx
import simd
#if CORRIDOR_KEY_SPM_MIRROR
import CorridorKeyToolboxLogic
#endif

/// One v2 artifact contains every quality rung and shares its weights between
/// all traces. Green and blue screens use the same trained model; screen colour
/// continues to select the hint and despill behaviour in the shared renderer.
enum MLXBridgeArtifact {

    /// Supported bridge resolutions, in preference order from lowest to
    /// highest. Every dimension satisfies v2's 128-pixel shape quantum.
    static let ladder: [Int] = [512, 768, 1024, 1536, 2048]

    /// The shared artifact is independent of the selected screen and quality.
    static func filename(forResolution resolution: Int, screenColor: ScreenColor) -> String {
        "corridorkey_v2.mlxfn"
    }

    /// Returns the ladder rung that is at least as large as `requested`,
    /// falling back to the maximum if nothing larger exists.
    static func closestSupportedResolution(forRequested requested: Int) -> Int? {
        ladder.first(where: { $0 >= requested }) ?? ladder.last
    }
}

/// Lazy bundled-resource lookup that works from any of the three
/// processes that may host the engine: the FxPlug XPC service (the
/// .mlxfn files sit in its own bundle), the standalone wrapper app
/// (which reaches into the embedded renderer plugin so we don't have
/// to duplicate the model's shared weights), and the SPM test runner
/// (which reads the same artifact from production resources).
private enum MLXBridgeResourceLocator {
    static func url(for filename: String) -> URL? {
        let fileManager = FileManager.default
#if CORRIDOR_KEY_SPM_MIRROR
        // Headless tests use the production artifact without copying several
        // gigabytes into the test bundle. Shipping targets never use this path.
        let productionURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "../Resources/MLX Models/\(filename)")
            .standardizedFileURL
        if fileManager.fileExists(atPath: productionURL.path) { return productionURL }
#endif
        let filenameStem = (filename as NSString).deletingPathExtension
        let filenameExtension = (filename as NSString).pathExtension

        // 1. The simplest case — the .mlxfn lives inside whatever
        //    bundle this process's main executable was loaded from.
        //    True for the FxPlug XPC service and for SPM test runners
        //    that bundle the test resource directly.
        if let url = Bundle.main.url(forResource: filenameStem, withExtension: filenameExtension) {
            return url
        }

        // 2. The wrapper app: the renderer plugin sits inside the
        //    .app at Contents/PlugIns/CorridorKey by LateNite Renderer.pluginkit
        //    and owns the .mlxfn resources. Looking them up here lets
        //    the standalone editor reuse the same on-disk artefacts
        //    the renderer ships, instead of bundling a second copy.
        if let pluginsURL = Bundle.main.builtInPlugInsURL {
            do {
                let plugins = try fileManager.contentsOfDirectory(
                    at: pluginsURL,
                    includingPropertiesForKeys: nil
                )
                for plugin in plugins {
                    let candidate = plugin
                        .appending(path: "Contents/Resources/\(filename)")
                    if fileManager.fileExists(atPath: candidate.path) {
                        return candidate
                    }
                }
            } catch {
                // Plugins folder absent or unreadable — fall through to
                // the bundle walk below; nothing to surface to the user.
            }
        }

        // 3. Walk every loaded bundle in case a host loaded ours
        //    indirectly (dev builds, unit tests, etc).
        for bundle in Bundle.allBundles {
            if let url = bundle.url(forResource: filenameStem, withExtension: filenameExtension) {
                return url
            }
            if let resourceURL = bundle.resourceURL {
                let candidate = resourceURL.appending(path: filename)
                if fileManager.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        return nil
    }
}

final class MLXKeyingEngine: KeyingInferenceEngine, @unchecked Sendable {

    /// Strategy for handing the normalised input tensor to MLX. Switched
    /// at engine init by the production code; the test suite can override
    /// per-instance via `testOverrideInputStrategy(_:)` to cross-check
    /// parity between the two paths.
    ///
    /// * `.zeroCopy` — aliases the shared MTLBuffer directly via
    ///   MLX's managed C array API. Apple Silicon's unified memory makes
    ///   this near-free — no copy, MLX reads the same bytes the Metal
    ///   normalise kernel just wrote. The shipping default.
    /// * `.cpuStaging` — copies the buffer into a reusable Swift
    ///   `[Float]` and constructs an `MLXArray` that owns its memory.
    ///   Was tried as a workaround for a slow-eval symptom on one clip
    ///   but proved unreliable in production (matte quality regressions).
    ///   Kept available so unit tests can validate parity with the
    ///   shipping path.
    enum InputStrategy: Sendable {
        case zeroCopy
        case cpuStaging
    }
    private static let defaultInputStrategy: InputStrategy = .zeroCopy
    /// V2's uncapped allocator retained over 13 GiB of reusable buffers at
    /// 2048px on M1 Max. A 1 GiB cache keeps similar throughput while leaving
    /// memory available to the host. This limits cached, not active, tensors.
    /// Static initialization applies the process-wide setting exactly once.
    private static let configureMemoryCache: Void = {
        MLX.Memory.cacheLimit = min(MLX.Memory.cacheLimit, 1024 * 1024 * 1024)
    }()
    private var inputStrategy: InputStrategy = MLXKeyingEngine.defaultInputStrategy

    /// Test-only entry point. Production callers must not flip the
    /// strategy mid-flight — the override exists so parity tests can
    /// run both paths against the same input within a single process.
    func testOverrideInputStrategy(_ strategy: InputStrategy) {
        runLock.lock()
        inputStrategy = strategy
        runLock.unlock()
    }

    let backendDisplayName: String
    var guideSourceDescription: String

    private let cacheEntry: MetalDeviceCacheEntry
    /// Guards `importedFunction` / `loadedResolution` / `loadedBridgeURL`
    /// reads and writes. Held briefly so warm-up and per-frame renders never
    /// deadlock each other.
    private let stateLock = NSLock()
    /// Serialises the entire `run(...)` path. FxPlug calls us from multiple
    /// render threads concurrently and `ImportedFunction` is not documented as
    /// thread-safe — funnel everything through a single in-flight inference.
    private let runLock = NSLock()
    private var importedFunction: ImportedFunction?
    private var loadedResolution: Int = 0
    /// Resource identity, independent of the requested screen colour or rung.
    private var loadedBridgeURL: URL?

    /// Reusable scratch buffer for the `.cpuStaging` strategy. Sized at
    /// warm-up so per-frame inference doesn't pay the 67 MB allocation
    /// cost on every call. `runLock` serialises access; no extra guard.
    private var inputScratch: [Float] = []

    /// Keeps the caller's Metal allocation alive until MLX releases its view.
    private final class InputBufferOwner {
        let buffer: any MTLBuffer

        init(buffer: any MTLBuffer) {
            self.buffer = buffer
        }
    }

    /// Wraps an already validated shared input allocation without copying.
    /// MLX Swift 0.31.3's raw-pointer initializer retains its finalizer payload
    /// but never releases it. Use the existing C API with a balanced retain
    /// and release so long analyses do not leak the capture or Metal buffer.
    static func makeInputArray(buffer: any MTLBuffer, resolution: Int) -> MLXArray {
        let shape: [Int32] = [1, Int32(resolution), Int32(resolution), 4]
        let owner = Unmanaged.passRetained(InputBufferOwner(buffer: buffer)).toOpaque()
        return MLXArray(mlx_array_new_data_managed_payload(
            buffer.contents(), shape, Int32(shape.count), MLX_FLOAT32, owner,
            { payload in
                guard let payload else { return }
                Unmanaged<InputBufferOwner>.fromOpaque(payload).release()
            }
        ))
    }

    init(cacheEntry: MetalDeviceCacheEntry) {
        _ = Self.configureMemoryCache
        self.cacheEntry = cacheEntry
        self.backendDisplayName = "CorridorKey v2 · MLX on \(cacheEntry.device.name)"
        self.guideSourceDescription = "Auto rough fallback"
    }

    /// Releases MLX's internal buffer cache. Called by the analyser at the
    /// end of an Analyse Clip pass. During inference the bounded cache can
    /// reuse allocations; after analysis the host can reclaim those buffers.
    func clearMLXCache() {
        let beforeBytes = MLX.Memory.cacheMemory
        MLX.Memory.clearCache()
        let afterBytes = MLX.Memory.cacheMemory
        let releasedMB = (beforeBytes - afterBytes) / (1024 * 1024)
        if releasedMB > 0 {
            PluginLog.notice("MLX cache cleared: released \(releasedMB) MB.")
        }
    }

    /// Blocks the calling thread until MLX's GPU stream has retired
    /// every operation it had outstanding. The Standalone Editor's
    /// quit path calls this so the global compute pipeline state
    /// objects can't be released while MLX still has inference work
    /// queued on its private command queue. Without it, Quit during
    /// analysis trips Metal's API Validation
    /// `notifyExternalReferencesNonZeroOnDealloc` assertion in Debug
    /// builds (the only place Validation is enabled by default);
    /// release builds wouldn't crash but would still race the same
    /// release/deinit, so we guard both.
    static func synchronizeMLXGPUStream() {
        Stream.gpu.synchronize()
    }

    func supports(resolution: Int, screenColor: ScreenColor) -> Bool {
        guard MLXBridgeArtifact.ladder.contains(resolution) else { return false }
        let filename = MLXBridgeArtifact.filename(forResolution: resolution, screenColor: screenColor)
        return MLXBridgeResourceLocator.url(for: filename) != nil
    }

    func prepare(resolution: Int, screenColor: ScreenColor) async throws {
        guard MLXBridgeArtifact.ladder.contains(resolution) else {
            throw KeyingInferenceError.unsupportedResolution(resolution)
        }
        let rung = resolution
        let filename = MLXBridgeArtifact.filename(forResolution: rung, screenColor: screenColor)
        guard let bridgeURL = MLXBridgeResourceLocator.url(for: filename) else {
            throw KeyingInferenceError.modelUnavailable(
                "No \(screenColor.displayName) MLX bridge bundled for \(resolution)px."
            )
        }
        try await prepare(bridgeURL: bridgeURL, rung: rung, screenColor: screenColor)
    }

    /// Test entry point that loads the bridge from an explicit URL. Useful
    /// from SPM unit tests where the `.mlxfn` lives in the test target's
    /// resources bundle (which is not enumerated by `Bundle.allBundles`).
    /// Production callers should use `prepare(resolution:screenColor:)`.
    func prepare(bridgeURL: URL, rung: Int, screenColor: ScreenColor) async throws {
        guard MLXBridgeArtifact.ladder.contains(rung) else {
            throw KeyingInferenceError.unsupportedResolution(rung)
        }
        if alreadyLoaded(bridgeURL: bridgeURL) { return }

        PluginLog.notice("Loading MLX bridge from \(bridgeURL.path) (\(screenColor.displayName) screen).")
        let function: ImportedFunction
        do {
            function = try ImportedFunction(url: bridgeURL)
        } catch {
            throw KeyingInferenceError.modelUnavailable(
                "MLX could not load \(bridgeURL.lastPathComponent): \(error.localizedDescription)"
            )
        }

        // Drive one zero-filled inference to trigger MLX's JIT compilation and
        // allocate the Metal buffer pool. Finishing this before we advertise
        // the engine as loaded means the first real render frame never pays a
        // multi-second stall while MLX compiles on demand.
        try await warmJIT(function: function, rung: rung)
        storeFunction(function, rung: rung, bridgeURL: bridgeURL)
    }

    /// Runs a throwaway inference on a zero tensor so MLX compiles the graph
    /// and warms the Metal buffer cache. Failed warm-up must never publish a
    /// ready engine, otherwise the first frame fails after analysis has begun.
    private func warmJIT(function: ImportedFunction, rung: Int) async throws {
        let warmupStart = Date()
        let zeros = [Float](repeating: 0, count: rung * rung * 4)
        let input = MLXArray(zeros, [1, rung, rung, 4])
        do {
            let outputs = try withError {
                try function(input)
            }
            guard outputs.count == 2 else {
                throw KeyingInferenceError.modelUnavailable("CorridorKey v2 must return alpha and foreground.")
            }
            try assertOutputShapes(alpha: outputs[0], foreground: outputs[1], rung: rung)
            try checkedEval(outputs)
        } catch {
            throw KeyingInferenceError.modelUnavailable("CorridorKey v2 warm-up failed: \(error.localizedDescription)")
        }
        let elapsedSeconds = Date().timeIntervalSince(warmupStart)
        PluginLog.notice("MLX JIT warm-up finished in \(elapsedSeconds.formatted(.number.precision(.fractionLength(2))))s for \(rung)px.")
    }

    func run(request: KeyingInferenceRequest, output: KeyingInferenceOutput) throws {
        runLock.lock()
        defer { runLock.unlock() }
        // Per-call autoreleasepool drops the local MLXArrays + their
        // captured retain-boxes the moment we exit this method.
        // Without it, the autoreleased Obj-C wrappers MLX returns
        // hang around in the calling thread's outer pool — Final Cut
        // Pro's analyse loop never drains that pool, which is what
        // turned the cache into a 40+ GB sink in production.
        let runStart = ContinuousClock.now
        try autoreleasepool {
            try runBody(request: request, output: output)
        }
        let elapsed = ContinuousClock.now - runStart
        let elapsedSeconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        // Feed the device capability cache so subsequent `automatic`
        // ceiling decisions reflect real measurements, not the static
        // RAM-tier heuristic.
        let rung = request.inferenceResolution
        if rung > 0 {
            DeviceCapabilityCache.shared.record(
                deviceRegistryID: cacheEntry.device.registryID,
                rung: rung,
                milliseconds: elapsedSeconds * 1000
            )
        }
    }

    private func runBody(request: KeyingInferenceRequest, output: KeyingInferenceOutput) throws {
        let (function, _) = loadedState()
        guard let function else {
            throw KeyingInferenceError.modelUnavailable("MLX bridge not prepared.")
        }
        let rung = request.inferenceResolution
        guard MLXBridgeArtifact.ladder.contains(rung) else {
            throw KeyingInferenceError.unsupportedResolution(rung)
        }
        guard output.alphaTexture.width == rung, output.alphaTexture.height == rung,
              output.foregroundTexture.width == rung, output.foregroundTexture.height == rung else {
            throw KeyingInferenceError.modelUnavailable("Inference output dimensions do not match the requested quality.")
        }
        _ = request.rawSourceTexture
        let expectedBytes = rung * rung * 4 * MemoryLayout<Float>.size
        guard request.normalisedInputBuffer.length >= expectedBytes else {
            throw KeyingInferenceError.modelUnavailable(
                "MLX input buffer is \(request.normalisedInputBuffer.length) bytes; expected ≥ \(expectedBytes)."
            )
        }

        // Step 1: build the MLX input. Two strategies live here; see
        // `InputStrategy` for the trade-off and the wall-time data.
        let inputBuffer = request.normalisedInputBuffer
        let inputArray: MLXArray
        switch inputStrategy {
        case .zeroCopy:
            inputArray = Self.makeInputArray(buffer: inputBuffer, resolution: rung)
        case .cpuStaging:
            let expectedCount = rung * rung * 4
            if inputScratch.count != expectedCount {
                inputScratch = [Float](repeating: 0, count: expectedCount)
            }
            // Copy 67 MB once into the Swift scratch. On Apple Silicon's
            // unified memory both source and destination are CPU-visible,
            // so this is just a memcpy with no GPU sync. Lets MLX own the
            // input layout end-to-end, which empirically keeps MLX
            // evaluation on the fast path.
            inputScratch.withUnsafeMutableBufferPointer { destination in
                guard let destinationBase = destination.baseAddress else { return }
                memcpy(destinationBase, inputBuffer.contents(), expectedCount * MemoryLayout<Float>.size)
            }
            inputArray = MLXArray(inputScratch, [1, rung, rung, 4])
        }

        // Step 2: invoke the imported function. The graph returns
        // `(alpha, foreground)` per CorridorKey's bridge exporter.
        var results: [MLXArray]
        do {
            results = try withError {
                try function(inputArray)
            }
        } catch {
            throw KeyingInferenceError.modelUnavailable(
                "MLX apply failed: \(error.localizedDescription)"
            )
        }
        guard results.count == 2 else {
            throw KeyingInferenceError.modelUnavailable(
                "MLX bridge returned \(results.count) outputs; expected 2."
            )
        }
        try assertOutputShapes(alpha: results[0], foreground: results[1], rung: rung)
        // V2 returns reversed-axis views to match the renderer's established
        // orientation. Materialize on the GPU before aliasing their storage;
        // asMTLBuffer would otherwise fall back to a CPU copy for those views.
        results = results.map { contiguous($0) }

        // Step 3: force evaluation so the backing buffers are populated.
        do {
            try checkedEval(results[0], results[1])
        } catch {
            throw KeyingInferenceError.modelUnavailable(
                "MLX eval failed: \(error.localizedDescription)"
            )
        }

        // Step 4: alias MLX's own output storage as MTLBuffers (still on
        // the GPU, no CPU copy) and encode a compute pass that reads them
        // into the output textures the caller provided. A completion
        // handler retains the MLXArrays so their backing memory survives
        // until the kernel finishes reading.
        let device = cacheEntry.device
        guard let alphaMLXBuffer = results[0].asMTLBuffer(device: device, noCopy: true) else {
            throw KeyingInferenceError.modelUnavailable("MLX alpha output could not be exposed as MTLBuffer.")
        }
        guard let foregroundMLXBuffer = results[1].asMTLBuffer(device: device, noCopy: true) else {
            throw KeyingInferenceError.modelUnavailable("MLX foreground output could not be exposed as MTLBuffer.")
        }

        guard let commandQueue = cacheEntry.borrowCommandQueue() else {
            throw KeyingInferenceError.deviceUnavailable
        }
        defer { cacheEntry.returnCommandQueue(commandQueue) }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw KeyingInferenceError.deviceUnavailable
        }
        commandBuffer.label = "CorridorKey by LateNite MLX Writeback"

        try RenderStages.writeMLXOutputsFused(
            alphaBuffer: alphaMLXBuffer,
            foregroundBuffer: foregroundMLXBuffer,
            alphaDestination: output.alphaTexture,
            foregroundDestination: output.foregroundTexture,
            entry: cacheEntry,
            commandBuffer: commandBuffer
        )

        // Retain the MLXArrays (and the MTLBuffer aliases they back) until
        // the GPU is done reading them. `asMTLBuffer(noCopy:true)` requires
        // the MLXArray to outlive the MTLBuffer; `addCompletedHandler`
        // fires after the kernels are done, so keeping a strong
        // reference here is the simplest lifetime extension that works.
        // The captures cross a `@Sendable` boundary — MLXArray and
        // MTLBuffer aren't Sendable-typed, but they're safe to capture
        // because we only use them to keep allocations alive, not mutate
        // them. Wrap in a small `@unchecked Sendable` box to satisfy the
        // concurrency checker.
        final class RetainBox: @unchecked Sendable {
            let alphaArray: MLXArray
            let foregroundArray: MLXArray
            let alphaBuffer: any MTLBuffer
            let foregroundBuffer: any MTLBuffer
            init(alphaArray: MLXArray, foregroundArray: MLXArray, alphaBuffer: any MTLBuffer, foregroundBuffer: any MTLBuffer) {
                self.alphaArray = alphaArray
                self.foregroundArray = foregroundArray
                self.alphaBuffer = alphaBuffer
                self.foregroundBuffer = foregroundBuffer
            }
        }
        let retainBox = RetainBox(
            alphaArray: results[0],
            foregroundArray: results[1],
            alphaBuffer: alphaMLXBuffer,
            foregroundBuffer: foregroundMLXBuffer
        )
        commandBuffer.addCompletedHandler { _ in
            _ = retainBox
        }

        let semaphore = DispatchSemaphore(value: 0)
        commandBuffer.addCompletedHandler { _ in semaphore.signal() }
        commandBuffer.commit()
        semaphore.wait()
        if let error = commandBuffer.error { throw error }
    }

    // MARK: - Lock-guarded state helpers

    private func alreadyLoaded(bridgeURL: URL) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return importedFunction != nil
            && loadedBridgeURL == bridgeURL
    }

    private func loadedState() -> (ImportedFunction?, Int) {
        stateLock.lock()
        defer { stateLock.unlock() }
        return (importedFunction, loadedResolution)
    }

    private func storeFunction(_ function: ImportedFunction, rung: Int, bridgeURL: URL) {
        stateLock.lock()
        defer { stateLock.unlock() }
        if importedFunction != nil, loadedBridgeURL == bridgeURL {
            return
        }
        importedFunction = function
        loadedResolution = rung
        loadedBridgeURL = bridgeURL
    }

    /// Validates that the loaded bridge's outputs have the expected NHWC layout.
    /// Fails loudly on mismatch so a misbuilt or misplaced `.mlxfn` doesn't
    /// silently corrupt downstream writes.
    private func assertOutputShapes(alpha: MLXArray, foreground: MLXArray, rung: Int) throws {
        let expectedAlpha = [1, rung, rung, 1]
        let expectedForeground = [1, rung, rung, 3]
        if alpha.shape != expectedAlpha || foreground.shape != expectedForeground
            || alpha.dtype != .float32 || foreground.dtype != .float32 {
            PluginLog.error(
                "MLX bridge returned unexpected shapes: alpha=\(alpha.shape) foreground=\(foreground.shape); expected \(expectedAlpha) and \(expectedForeground)."
            )
            throw KeyingInferenceError.modelUnavailable(
                "MLX bridge returned unexpected output shapes."
            )
        }
    }

}
