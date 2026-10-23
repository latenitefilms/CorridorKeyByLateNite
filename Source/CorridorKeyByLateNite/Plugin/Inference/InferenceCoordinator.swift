//
//  InferenceCoordinator.swift
//  CorridorKey by LateNite
//
//  The inference adapter for the analyser path. Every analyse-time call
//  goes through MLX — there is intentionally **no** fallback engine, so
//  the cached matte sequence is always 100% neural-network output. If
//  MLX isn't warm yet, `runInference` blocks (via the registry's
//  `waitForReady`) until the bridge is ready or the warm-up fails.
//  Engines live in `SharedMLXBridgeRegistry` so multiple plug-in
//  instances share a single warmed bridge per `(device, rung)`.
//
//  Note: the green-bias "rough matte" still exists, but as a *hint*
//  fed into MLX as the 4th input channel by the pre-inference pass
//  (`extractHint` / `combineAndNormaliseIntoBuffer`). It is never used
//  as a final output matte.
//
//  Analysis always evaluates the current inputs. Playback and post-process
//  edits use the persisted matte cache and never call this coordinator.
//  A timestamp alone cannot identify model input across clips or hint edits.
//

import Foundation
import Metal
import CoreMedia
#if CORRIDOR_KEY_SPM_MIRROR
import CorridorKeyToolboxLogic
#endif

/// Result bundle from `runInference`. The `engineDescription` records
/// **which engine actually processed this frame** (MLX or the rough-matte
/// fallback), not whichever engine happens to be ready when a log line
/// fires. Without this distinction the analyse log misreports rough-matte
/// frames as MLX, which masked the "first analysis is mostly rough-matte
/// because MLX is still warming up" diagnosis for ages.
struct InferenceRunResult {
    let output: KeyingInferenceOutput
    let engineDescription: String
}

final class InferenceCoordinator: @unchecked Sendable {

    /// Master switch for the MLX bridge. Always `true` in shipping
    /// builds — the analyser refuses to run without MLX. Kept as a
    /// constant so a future development build can flip it for debugging
    /// the pre-/post-inference pipeline without paying for the warm-up.
    private static let mlxEnabled = true

    private let stateLock = NSLock()

    /// The `(device, rung, screenColor)` this coordinator most recently
    /// asked the registry to warm. Used by `warmupStatus` and
    /// `cancelWarmup` to target the right key.
    private var trackedDeviceRegistryID: UInt64 = 0
    private var trackedRung: Int = 0
    private var trackedScreenColor: ScreenColor = .green

    /// Human-readable backend summary for diagnostics.
    var backendDescription: String {
        stateLock.lock()
        let device = trackedDeviceRegistryID
        let rung = trackedRung
        let color = trackedScreenColor
        stateLock.unlock()
        if rung > 0, let engine = SharedMLXBridgeRegistry.shared.readyEngine(
            deviceRegistryID: device,
            rung: rung,
            screenColor: color
        ) {
            return engine.backendDisplayName
        }
        return "Idle"
    }

    /// Current warm-up status. The inspector bridge consumes this to render
    /// the "Loading neural model…" badge during the first-play stall.
    var warmupStatus: WarmupStatus {
        stateLock.lock()
        let device = trackedDeviceRegistryID
        let rung = trackedRung
        let color = trackedScreenColor
        stateLock.unlock()
        guard rung > 0 else { return .cold }
        return SharedMLXBridgeRegistry.shared.status(
            deviceRegistryID: device,
            rung: rung,
            screenColor: color
        )
    }

    /// Cancels the in-flight MLX warm-up tracked by this coordinator.
    /// Safe when no warm-up is running — it's a no-op in that case.
    func cancelWarmup() {
        stateLock.lock()
        let device = trackedDeviceRegistryID
        let rung = trackedRung
        let color = trackedScreenColor
        stateLock.unlock()
        guard rung > 0 else { return }
        SharedMLXBridgeRegistry.shared.cancelWarmup(
            deviceRegistryID: device,
            rung: rung,
            screenColor: color
        )
    }

    /// Evaluates the current frame and hint with the shared v2 model,
    /// waiting for warm-up if necessary. Analysis never substitutes a
    /// chroma matte or reuses another input's prediction.
    func runInference(
        request: KeyingInferenceRequest,
        screenColor: ScreenColor,
        cacheEntry: MetalDeviceCacheEntry
    ) throws -> InferenceRunResult {
        guard Self.mlxEnabled else {
            throw KeyingInferenceError.modelUnavailable("MLX is disabled in this build.")
        }

        let deviceRegistryID = cacheEntry.device.registryID
        trackRequestedBridge(
            deviceRegistryID: deviceRegistryID,
            rung: request.inferenceResolution,
            screenColor: screenColor
        )

        // Block until the MLX bridge is warm. Earlier builds fell
        // through to a green-bias rough-matte engine when MLX wasn't
        // ready yet, which silently degraded the first ~15 s of every
        // analysis to a shape-only matte. We now wait — the green
        // hint is still used inside MLX (as the 4th input channel via
        // `extractHint` in pre-inference), but the *output* matte is
        // always the neural one.
        let engine: MLXKeyingEngine
        do {
            engine = try SharedMLXBridgeRegistry.shared.waitForReady(
                deviceRegistryID: deviceRegistryID,
                rung: request.inferenceResolution,
                screenColor: screenColor,
                cacheEntry: cacheEntry
            )
        } catch {
            PluginLog.error("MLX bridge unavailable: \(error.localizedDescription)")
            throw error
        }

        let output = try makeOutputTextures(request: request, cacheEntry: cacheEntry)
        try engine.run(request: request, output: output)
        return InferenceRunResult(output: output, engineDescription: engine.backendDisplayName)
    }

    /// Asks the shared registry to start warm-up for `(device, rung,
    /// screenColor)` without waiting. Used by
    /// `CorridorKeyToolboxPlugIn.init` to pre-warm the default bridge the
    /// moment the effect is applied.
    func requestEagerWarmup(rung: Int, screenColor: ScreenColor, cacheEntry: MetalDeviceCacheEntry) {
        guard Self.mlxEnabled else { return }
        let deviceRegistryID = cacheEntry.device.registryID
        trackRequestedBridge(deviceRegistryID: deviceRegistryID, rung: rung, screenColor: screenColor)
        SharedMLXBridgeRegistry.shared.beginWarmup(
            deviceRegistryID: deviceRegistryID,
            rung: rung,
            screenColor: screenColor,
            cacheEntry: cacheEntry
        )
    }

    /// Drains reusable MLX allocations at the end of analysis. Keeping the
    /// bounded allocator cache warm during a pass avoids per-frame churn;
    /// clearing it afterwards returns that memory without unloading weights.
    func releaseCacheBetweenSessions() {
        stateLock.lock()
        let deviceRegistryID = trackedDeviceRegistryID
        let rung = trackedRung
        let color = trackedScreenColor
        stateLock.unlock()

        if rung > 0,
           let mlx = SharedMLXBridgeRegistry.shared.readyEngine(
               deviceRegistryID: deviceRegistryID,
               rung: rung,
               screenColor: color
           ) {
            mlx.clearMLXCache()
        }
    }

    // MARK: - Tracked bridge target

    private func trackRequestedBridge(deviceRegistryID: UInt64, rung: Int, screenColor: ScreenColor) {
        stateLock.lock()
        trackedDeviceRegistryID = deviceRegistryID
        trackedRung = rung
        trackedScreenColor = screenColor
        stateLock.unlock()
    }

    // MARK: - Output textures

    private func makeOutputTextures(
        request: KeyingInferenceRequest,
        cacheEntry: MetalDeviceCacheEntry
    ) throws -> KeyingInferenceOutput {
        guard let alpha = cacheEntry.makeIntermediateTexture(
            width: request.inferenceResolution,
            height: request.inferenceResolution,
            pixelFormat: .r32Float,
            storageMode: .shared
        ) else {
            throw KeyingInferenceError.deviceUnavailable
        }
        guard let foreground = cacheEntry.makeIntermediateTexture(
            width: request.inferenceResolution,
            height: request.inferenceResolution,
            pixelFormat: .rgba32Float,
            storageMode: .shared
        ) else {
            throw KeyingInferenceError.deviceUnavailable
        }
        return KeyingInferenceOutput(alphaTexture: alpha, foregroundTexture: foreground)
    }
}
