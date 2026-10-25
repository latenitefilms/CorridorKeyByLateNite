//
//  StandaloneRenderEngine.swift
//  CorridorKey by LateNite — Standalone Editor
//
//  Glue layer between the standalone editor and the shared render
//  pipeline. Holds onto the system-default `MTLDevice`, a single
//  `RenderPipeline` instance, and a `PixelBufferTextureBridge` so each
//  preview / export call boils down to:
//
//      1. Wrap the source CVPixelBuffer as an MTLTexture (zero copy).
//      2. Make a Metal-compatible destination CVPixelBuffer if we're
//         exporting, or reuse the preview output texture.
//      3. Call `RenderPipeline.renderToTexture(...)`.
//      4. Hand the destination CVPixelBuffer back to the caller so it
//         can either upload it to a CAMetalLayer (preview) or write it
//         to AVAssetWriter (export).
//
//  The same render pipeline used by the FxPlug also powers this engine,
//  guaranteeing visual parity between Final Cut Pro and the standalone
//  editor without code duplication.
//

import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import Metal

#if CORRIDOR_KEY_HEADLESS_TESTS
@testable import CorridorKeyToolboxLogic
@testable import CorridorKeyToolboxMetalStages
#endif

/// Errors surfaced to the standalone editor when a render fails.
enum StandaloneRenderEngineError: Error, CustomStringConvertible {
    case noMetalDevice
    case bridgeUnavailable
    case destinationAllocationFailed

    var description: String {
        switch self {
        case .noMetalDevice:
            return "CorridorKey by LateNite could not access the system Metal device."
        case .bridgeUnavailable:
            return "CorridorKey by LateNite could not initialise the pixel-buffer ↔ Metal bridge."
        case .destinationAllocationFailed:
            return "CorridorKey by LateNite could not allocate a destination texture."
        }
    }
}

/// Bundle returned from a render. Holds the destination pixel buffer
/// (for downstream encoders), the Metal texture aliased onto its
/// IOSurface (for preview display), and the renderer's status report
/// so the editor can show "Source Pass-Through" / "Cached MLX" badges.
struct StandaloneRenderResult: @unchecked Sendable {
    let destinationPixelBuffer: CVPixelBuffer
    let destinationTexture: any MTLTexture
    let report: RenderReport
}

/// Serializes preview work away from the main actor. Cache reads, decompression
/// and synchronous GPU completion must not block inspector or transport input.
actor StandalonePreviewRenderer {
    private let engine: StandaloneRenderEngine

    init(engine: StandaloneRenderEngine) { self.engine = engine }

    /// The immutable frame retains its pixel buffer until GPU work has completed.
    /// Queued obsolete scrub requests stop before allocating or reading the cache.
    func render(frame: ReaderFrame, state: PluginStateData, showingOriginal: Bool = false) throws -> StandaloneRenderResult {
        try Task.checkCancellation()
        if showingOriginal { return try engine.renderShowingOriginal(source: frame.pixelBuffer) }
        if state.outputMode == .original || (state.outputMode != .hint
            && state.cachedMatteBlob == nil && state.cachedFrameReference == nil) {
            return try engine.renderShowingOriginal(
                source: frame.pixelBuffer,
                description: state.outputMode == .original ? "Original" : "Source Pass-Through — Analyse Clip to Key"
            )
        }
        return try engine.render(source: frame.pixelBuffer, state: state, renderTime: frame.presentationTime)
    }
}

/// One-stop render facade for the standalone editor. Constructed once
/// per editor session; held by `EditorViewModel` and shared across
/// preview, analyse, and export.
final class StandaloneRenderEngine: @unchecked Sendable {

    let device: any MTLDevice
    private let pipeline: RenderPipeline
    private let bridge: PixelBufferTextureBridge

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw StandaloneRenderEngineError.noMetalDevice
        }
        self.device = device
        self.pipeline = RenderPipeline()
        do {
            self.bridge = try PixelBufferTextureBridge(device: device)
        } catch {
            throw StandaloneRenderEngineError.bridgeUnavailable
        }
    }

    /// Read the decoder's actual RGB primaries; alpha is coverage in every gamut.
    static func workingGamut(for buffer: CVPixelBuffer) -> WorkingColorGamut {
        let value = CVBufferCopyAttachment(buffer, kCVImageBufferColorPrimariesKey, nil) as? String
        if value == kCVImageBufferColorPrimaries_ITU_R_2020 as String { return .rec2020 }
        if value == kCVImageBufferColorPrimaries_P3_D65 as String { return .displayP3 }
        return .rec709
    }

    // MARK: - Preview / scrub

    /// Creates the same temporal session used by FxAnalyzer.
    func makeVideoSession(state: PluginStateData, frameCount: Int, sourceSize: CGSize) throws -> VideoInferenceSession {
        let entry = try MetalDeviceCache.shared.entry(for: device)
        return try pipeline.makeVideoInferenceSession(sourceWidth: Int(sourceSize.width), sourceHeight: Int(sourceSize.height),
                                                       state: state, frameCount: frameCount, entry: entry,
                                                       readbackSource: state.temporalStabilityEnabled && state.temporalStabilityStrength > 0)
    }

    /// Decodes the optional external hint at matching source-frame timing.
    func appendVideoFrame(source: CVPixelBuffer, state: PluginStateData, renderTime: CMTime,
                          frameIndex: Int, session: VideoInferenceSession, hintReader: AlphaHintReader?) throws {
        let backed = try bridge.makeTexture(for: source, usage: .shaderRead)
        let entry = try MetalDeviceCache.shared.entry(for: device)
        guard let queue = entry.borrowCommandQueue() else { throw MetalDeviceCacheError.queueExhausted }
        defer { entry.returnCommandQueue(queue) }
        let hint = try hintReader?.texture(frameIndex: frameIndex, sourceWidth: backed.metalTexture.width,
                                           sourceHeight: backed.metalTexture.height, device: device, commandQueue: queue)
        try pipeline.appendVideoFrame(sourceTexture: backed.metalTexture, hintTexture: hint, state: state,
                                       workingGamut: Self.workingGamut(for: source), renderTime: renderTime, frameIndex: frameIndex,
                                       session: session, entry: entry, commandQueue: queue)
    }

    /// Renders one frame for preview. The destination uses the same
    /// pixel format as the source so the preview layer can display it
    /// directly without an extra blit. The destination texture is
    /// created with `[.shaderRead, .renderTarget]` usage so the
    /// pipeline's compose render pass can bind it as a colour
    /// attachment.
    func render(
        source pixelBuffer: CVPixelBuffer,
        state: PluginStateData,
        renderTime: CMTime
    ) throws -> StandaloneRenderResult {
        let sourceBacked = try bridge.makeTexture(for: pixelBuffer, usage: .shaderRead)
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let destinationBuffer = try PixelBufferTextureBridge.makeMetalCompatiblePixelBuffer(
            width: sourceBacked.metalTexture.width,
            height: sourceBacked.metalTexture.height,
            pixelFormat: pixelFormat
        )
        let destinationBacked = try bridge.makeTexture(
            for: destinationBuffer,
            usage: [.shaderRead, .renderTarget]
        )
        let report = try pipeline.renderToTexture(
            source: sourceBacked.metalTexture,
            destination: destinationBacked.metalTexture,
            alphaHint: nil,
            state: state,
            workingGamut: Self.workingGamut(for: pixelBuffer),
            renderTime: renderTime
        )
        return StandaloneRenderResult(
            destinationPixelBuffer: destinationBuffer,
            destinationTexture: destinationBacked.metalTexture,
            report: report
        )
    }

    /// Returns the source frame untouched, wrapped as a
    /// `StandaloneRenderResult`. Drives the "Show Original" push-and-
    /// hold button: the user gets a side-by-side comparison against
    /// the unkeyed plate without paying the MLX / post-process cost.
    /// Re-uses the bridge so the source IOSurface and the wrapping
    /// `MTLTexture` share memory — the preview layer is reading the
    /// same bytes the decoder produced, not a copy.
    func renderShowingOriginal(
        source pixelBuffer: CVPixelBuffer,
        description: String = "Show Original (Press-and-Hold)"
    ) throws -> StandaloneRenderResult {
        let sourceBacked = try bridge.makeTexture(for: pixelBuffer, usage: .shaderRead)
        return StandaloneRenderResult(
            destinationPixelBuffer: pixelBuffer,
            destinationTexture: sourceBacked.metalTexture,
            report: RenderReport(
                backendDescription: description,
                guideSourceDescription: "—",
                effectiveInferenceResolution: 0,
                deviceName: device.name
            )
        )
    }

    // MARK: - Analysis

    /// Returns reusable MLX allocations to the process after analysis ends,
    /// including cancellation and failure. Loaded weights stay shared and warm.
    func releaseAnalysisCache() {
        pipeline.inferenceCoordinator.releaseCacheBetweenSessions()
    }

    /// Runs the FxAnalyzer-equivalent extraction step on a single
    /// frame. Returns the encoded matte blob ready to be stored in the
    /// project's matte cache. Mirrors `RenderPipeline.extractAlphaMatteForAnalysis`
    /// but exposes only the bits the standalone editor needs. Shared
    /// inference already returns alpha in the source texture's row order;
    /// both hosts must encode those rows without another orientation change.
    func extractMatteBlob(
        source pixelBuffer: CVPixelBuffer,
        state: PluginStateData,
        renderTime: CMTime
    ) throws -> AnalysisFrameOutput {
        let extracted = try extractAnalysisFrame(source: pixelBuffer, state: state, renderTime: renderTime)
        let blob = try AnalysisFrameCodec.encode(
            alpha: extracted.alpha,
            foregroundHalfRGBA: extracted.foregroundHalfRGBA,
            width: extracted.width,
            height: extracted.height
        )
        return AnalysisFrameOutput(
            blob: blob,
            width: extracted.width,
            height: extracted.height,
            inferenceResolution: extracted.inferenceResolution,
            engineDescription: extracted.engineDescription,
            sourceFloats: extracted.source,
            alphaFloats: extracted.alpha,
            foregroundHalfRGBA: extracted.foregroundHalfRGBA
        )
    }

    /// Extracts a prediction without encoding it. Sequential analysis applies
    /// temporal stability first, then compresses the completed frame exactly once.
    func extractAnalysisFrame(
        source pixelBuffer: CVPixelBuffer,
        state: PluginStateData,
        renderTime: CMTime
    ) throws -> RenderPipeline.AnalysisExtraction {
        let sourceBacked = try bridge.makeTexture(for: pixelBuffer, usage: .shaderRead)
        let device = sourceBacked.metalTexture.device
        let entry = try MetalDeviceCache.shared.entry(for: device)
        guard let commandQueue = entry.borrowCommandQueue() else {
            throw MetalDeviceCacheError.queueExhausted
        }
        defer { entry.returnCommandQueue(commandQueue) }
        return try pipeline.extractAlphaMatteForAnalysis(
            sourceTexture: sourceBacked.metalTexture,
            state: state,
            workingGamut: Self.workingGamut(for: pixelBuffer),
            renderTime: renderTime,
            device: device,
            entry: entry,
            commandQueue: commandQueue,
            readbackSource: state.temporalStabilityEnabled && state.temporalStabilityStrength > 0
        )
    }

    /// Eagerly warms up the MLX bridge for the chosen quality rung
    /// and screen colour. Lets the editor surface a "Loading neural
    /// model…" status while the bridge compiles, the same way the
    /// FxPlug does. Defaulting `screenColor` keeps existing callers
    /// (and tests) source-compatible — they implicitly request the
    /// green bridge, matching the inspector's default.
    func beginWarmup(forResolution resolution: Int, screenColor: ScreenColor = .green) throws {
        let entry = try MetalDeviceCache.shared.entry(for: device)
        SharedMLXBridgeRegistry.shared.beginWarmup(
            deviceRegistryID: device.registryID,
            rung: resolution,
            screenColor: screenColor,
            cacheEntry: entry
        )
    }

    /// Queries the warm-up status for the inspector status badge.
    func warmupStatus(forResolution resolution: Int, screenColor: ScreenColor = .green) -> WarmupStatus {
        SharedMLXBridgeRegistry.shared.status(
            deviceRegistryID: device.registryID,
            rung: resolution,
            screenColor: screenColor
        )
    }

    /// Cancels an in-flight MLX warm-up for the editor's device.
    /// Ready engines stay cached; only the background compile/eval
    /// task is stopped.
    @discardableResult
    func cancelWarmup(forResolution resolution: Int, screenColor: ScreenColor = .green) -> Task<Void, Never>? {
        SharedMLXBridgeRegistry.shared.cancelWarmup(
            deviceRegistryID: device.registryID,
            rung: resolution,
            screenColor: screenColor
        )
    }
}

/// Per-frame analysis output. Kept separate from the render result so
/// callers cannot accidentally route it back into the preview path.
struct AnalysisFrameOutput: @unchecked Sendable {
    let blob: Data
    let width: Int
    let height: Int
    let inferenceResolution: Int
    let engineDescription: String
    /// Optional raw float buffer of the source RGBA at inference
    /// resolution. Populated only when temporal stability is on so the
    /// CPU-side blender can compute motion gates.
    let sourceFloats: [Float]?
    /// Raw alpha matte at inference resolution. The same data the blob
    /// encodes; included separately so the temporal blender can mutate
    /// it without re-decoding.
    let alphaFloats: [Float]
    /// Straight model RGB retained while temporal stability modifies alpha.
    let foregroundHalfRGBA: Data
}
