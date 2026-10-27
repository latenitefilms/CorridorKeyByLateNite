//
//  SharedMLXBridgeRegistry.swift
//  CorridorKey by LateNite
//
//  Process-wide cache of one v2 engine per Metal device. All supported
//  quality levels, screen colours, and plug-in instances share its weights
//  and inference lock. Eager warm-up compiles the initially requested shape;
//  other shapes compile on their first use without reloading the model.
//  The engine remains resident for the process lifetime.
//

import Foundation
import Metal
#if CORRIDOR_KEY_SPM_MIRROR
import CorridorKeyToolboxLogic
#endif

final class SharedMLXBridgeRegistry: @unchecked Sendable {

    /// Process-wide singleton. The registry is stateless from the
    /// outside — callers just ask for an engine by key.
    static let shared = SharedMLXBridgeRegistry()

    /// V2 shares one function and one inference lock across all supported
    /// rungs and both screen colours. Invalid requests retain their own key
    /// so a failed unsupported resolution cannot poison the production model.
    private struct Key: Hashable, Sendable {
        let deviceRegistryID: UInt64
        let rung: Int
        let screenColor: ScreenColor

        init(deviceRegistryID: UInt64, rung: Int, screenColor: ScreenColor) {
            self.deviceRegistryID = deviceRegistryID
            self.rung = MLXBridgeArtifact.ladder.contains(rung) ? 0 : rung
            self.screenColor = .green
        }
    }

    /// Per-key list of waiters that should be woken when warm-up
    /// finishes (success or failure). Each waiter holds a
    /// `DispatchSemaphore` so the analyser thread can park without
    /// burning CPU on a 50 ms poll loop.
    private final class WaiterList {
        var semaphores: [DispatchSemaphore] = []
    }

    private let lock = NSLock()
    private var engines: [Key: MLXKeyingEngine] = [:]
    /// Recency tracker driving LRU eviction. Bumped on every
    /// `readyEngine` lookup and on warm-up completion; consulted by
    /// `evictLockedIfNeeded` when the per-device cap is exceeded.
    private var engineLastUsedAt: [Key: ContinuousClock.Instant] = [:]
    /// Backing tasks for in-flight warm-ups. Removed when the task
    /// finishes so subsequent lookups don't chase a dead reference.
    private var warmupTasks: [Key: Task<Void, Never>] = [:]
    /// Prevents a cancelled warm-up from overwriting a newer attempt's result.
    private var warmupTokens: [Key: UUID] = [:]
    /// Last failure message per `(device, rung)`. Cleared on successful
    /// warm-up; surfaced to UI via `warmupStatus`.
    private var warmupFailures: [Key: String] = [:]
    /// Threads parked in `waitForReady` waiting for `(device, rung)` to
    /// finish warming up. Signalled by `store(...)` / `record(...)` so
    /// the analyser wakes the moment warm-up completes instead of on
    /// the next poll tick.
    private var waiters: [Key: WaiterList] = [:]

    private init() {}

    // MARK: - Public API

    /// Returns the engine immediately if it's already warm. Non-blocking,
    /// used on the render hot path. Bumps the LRU recency tag so a
    /// rung that's actively rendering is never the one evicted.
    func readyEngine(deviceRegistryID: UInt64, rung: Int, screenColor: ScreenColor) -> MLXKeyingEngine? {
        let key = Key(deviceRegistryID: deviceRegistryID, rung: rung, screenColor: screenColor)
        lock.lock()
        defer { lock.unlock() }
        guard let engine = engines[key] else { return nil }
        engineLastUsedAt[key] = .now
        return engine
    }

    /// Blocks the calling thread until the `(device, rung)` engine is
    /// ready, the warm-up has failed, or warm-up is cancelled. Kicks off
    /// the warm-up itself if one isn't already running. Used by the
    /// analyser, which **must** key with MLX — falling through to the
    /// rough-matte fallback for a few frames while MLX warms would
    /// silently mix two engines' output into the cached matte sequence
    /// and produce a low-quality, inconsistent result.
    ///
    /// Implementation: enrolls a `DispatchSemaphore` on the per-key
    /// waiter list before checking status, then parks on the semaphore
    /// until the warm-up task signals it (success or failure). This
    /// avoids the legacy 50 ms `Thread.sleep` poll loop — wake latency
    /// is now bounded by GCD's signal delivery (<1 ms) instead of the
    /// poll interval, and the analyser thread is blocked, not spinning.
    ///
    /// Returns the engine on success, throws `KeyingInferenceError` on
    /// permanent failure.
    func waitForReady(
        deviceRegistryID: UInt64,
        rung: Int,
        screenColor: ScreenColor,
        cacheEntry: MetalDeviceCacheEntry,
        timeout: TimeInterval = 120
    ) throws -> MLXKeyingEngine {
        let key = Key(deviceRegistryID: deviceRegistryID, rung: rung, screenColor: screenColor)
        beginWarmup(
            deviceRegistryID: deviceRegistryID,
            rung: rung,
            screenColor: screenColor,
            cacheEntry: cacheEntry
        )
        let deadline = DispatchTime.now() + timeout

        while true {
            // Enroll a fresh waiter under the lock. The same lock guards
            // status mutations in `store(...)` / `record(...)`, so any
            // status change after this point is guaranteed to either be
            // observed below or to signal the semaphore.
            let semaphore = DispatchSemaphore(value: 0)
            lock.lock()
            if let engine = engines[key] {
                lock.unlock()
                return engine
            }
            if let message = warmupFailures[key] {
                lock.unlock()
                throw KeyingInferenceError.modelUnavailable(message)
            }
            // Warm-up is in flight — register and wait.
            let list = waiters[key] ?? WaiterList()
            list.semaphores.append(semaphore)
            waiters[key] = list
            lock.unlock()

            let result = semaphore.wait(timeout: deadline)
            if result == .timedOut {
                // Pull the semaphore back out so a delayed signal
                // doesn't accidentally unblock a future caller.
                detachWaiter(semaphore, forKey: key)
                throw KeyingInferenceError.modelUnavailable(
                    "\(screenColor.displayName) MLX bridge for \(rung)px did not become ready within \(Int(timeout))s."
                )
            }
            // Loop back to read state under the lock — covers the rare
            // case where the warm-up task was cancelled and rescheduled
            // between the signal and our wake-up.
        }
    }

    /// Removes `semaphore` from the waiter list for `key`. Called when
    /// `waitForReady` times out so a stray late signal can't unblock the
    /// next caller's semaphore by accident. Safe to call when the
    /// semaphore was already removed by a successful wake-up.
    private func detachWaiter(_ semaphore: DispatchSemaphore, forKey key: Key) {
        lock.lock()
        defer { lock.unlock() }
        guard let list = waiters[key] else { return }
        list.semaphores.removeAll { $0 === semaphore }
        if list.semaphores.isEmpty {
            waiters.removeValue(forKey: key)
        }
    }

    /// Kicks off a background warm-up for `(device, rung)` if one isn't
    /// already running and the engine isn't already warm. Idempotent —
    /// repeated calls return immediately when a task is in flight or the
    /// engine is ready.
    func beginWarmup(
        deviceRegistryID: UInt64,
        rung: Int,
        screenColor: ScreenColor,
        cacheEntry: MetalDeviceCacheEntry
    ) {
        let key = Key(deviceRegistryID: deviceRegistryID, rung: rung, screenColor: screenColor)
        lock.lock()
        if engines[key] != nil || warmupTasks[key] != nil {
            lock.unlock()
            return
        }
        // Clear prior failure so a retry gets a fresh status.
        warmupFailures[key] = nil
        let token = UUID()
        warmupTokens[key] = token

        // Priority is `.userInitiated`, not `.utility`, so a
        // synchronous `waitForReady` caller — usually the analyser
        // thread, which itself runs at user-initiated QoS — never
        // blocks a higher-priority thread on lower-priority work.
        // macOS surfaces that pattern as a priority-inversion
        // warning the moment a `DispatchSemaphore.wait` parks the
        // analyse thread. Eager warm-up (no caller waiting) is
        // also a one-shot per `(device, rung, colour)`, so bumping
        // the priority doesn't inflate steady-state CPU usage either.
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.runWarmup(key: key, token: token, cacheEntry: cacheEntry, rung: rung, screenColor: screenColor)
        }
        // Register while still holding the lock. Concurrent callers must not
        // create duplicate copies of the multi-gigabyte v2 model.
        warmupTasks[key] = task
        lock.unlock()
    }

    /// Current warm-up status for the given `(device, rung, screenColor)`.
    /// Used by the inspector bridge to drive the "Loading neural model…"
    /// badge.
    func status(deviceRegistryID: UInt64, rung: Int, screenColor: ScreenColor) -> WarmupStatus {
        let key = Key(deviceRegistryID: deviceRegistryID, rung: rung, screenColor: screenColor)
        lock.lock()
        defer { lock.unlock() }
        if let message = warmupFailures[key] {
            return .failed(message)
        }
        if engines[key] != nil {
            return .ready(resolution: rung)
        }
        if warmupTasks[key] != nil {
            return .warming(resolution: rung)
        }
        return .cold
    }

    /// Cancels the in-flight warm-up for `(device, rung, screenColor)` if
    /// any. Other plug-in instances that were also waiting on the same
    /// warm-up lose their in-flight state too, but they'll simply retry on
    /// their next render request. This is the trade-off of sharing —
    /// individual cancellations don't get fine-grained behaviour.
    @discardableResult
    func cancelWarmup(deviceRegistryID: UInt64, rung: Int, screenColor: ScreenColor) -> Task<Void, Never>? {
        let key = Key(deviceRegistryID: deviceRegistryID, rung: rung, screenColor: screenColor)
        lock.lock()
        let task = warmupTasks[key]
        warmupTasks[key] = nil
        lock.unlock()
        task?.cancel()
        return task
    }

    // MARK: - Internal

    private func runWarmup(
        key: Key,
        token: UUID,
        cacheEntry: MetalDeviceCacheEntry,
        rung: Int,
        screenColor: ScreenColor
    ) async {
        let engine = MLXKeyingEngine(cacheEntry: cacheEntry)
        guard engine.supports(resolution: rung, screenColor: screenColor) else {
            record(failure: "No CorridorKey v2 model bundled for \(rung)px", forKey: key, token: token)
            return
        }
        do {
            try Task.checkCancellation()
            try await engine.prepare(resolution: rung, screenColor: screenColor)
            try Task.checkCancellation()
            store(engine: engine, forKey: key, token: token, device: cacheEntry.device)
            PluginLog.notice(
                "Shared MLX engine ready: \(screenColor.displayName) \(rung)px on \(cacheEntry.device.name)."
            )
        } catch is CancellationError {
            record(failure: "Warm-up cancelled.", forKey: key, token: token)
        } catch {
            record(failure: error.localizedDescription, forKey: key, token: token)
            PluginLog.error("Shared MLX warm-up failed: \(error.localizedDescription)")
        }
    }

    private func store(engine: MLXKeyingEngine, forKey key: Key, token: UUID, device: any MTLDevice) {
        lock.lock()
        guard warmupTokens[key] == token else {
            lock.unlock()
            return
        }
        engines[key] = engine
        engineLastUsedAt[key] = .now
        warmupTasks[key] = nil
        warmupFailures[key] = nil
        evictLockedIfNeeded(activeKey: key, device: device)
        let parked = waiters.removeValue(forKey: key)?.semaphores ?? []
        lock.unlock()
        // Wake every parked analyser thread. Calling `signal()` outside
        // the lock keeps the wake path fast and prevents a waiter that
        // immediately re-enters `waitForReady` from contending with us.
        parked.forEach { $0.signal() }
    }

    private func record(failure message: String, forKey key: Key, token: UUID) {
        lock.lock()
        guard warmupTokens[key] == token else {
            lock.unlock()
            return
        }
        warmupTasks[key] = nil
        warmupFailures[key] = message
        let parked = waiters.removeValue(forKey: key)?.semaphores ?? []
        lock.unlock()
        parked.forEach { $0.signal() }
    }

    // MARK: - LRU eviction

    /// Drops least-recently-used engines on `device` until the resident
    /// count fits the device-tier budget. Caller holds `lock`. The
    /// freshly-stored `activeKey` is pinned (never evicted) so the rung
    /// the user just analysed at can't be removed by its own warm-up.
    private func evictLockedIfNeeded(activeKey: Key, device: any MTLDevice) {
        let budget = bridgeBudget(for: device)
        let perDeviceKeys = engines.keys.filter { $0.deviceRegistryID == device.registryID }
        guard perDeviceKeys.count > budget else { return }
        let toRemove = perDeviceKeys.count - budget
        let candidates: [(Key, ContinuousClock.Instant)] = perDeviceKeys
            .filter { $0 != activeKey }
            .compactMap { key in
                guard let when = engineLastUsedAt[key] else { return nil }
                return (key, when)
            }
            .sorted { $0.1 < $1.1 }
        for index in 0..<min(toRemove, candidates.count) {
            let key = candidates[index].0
            engines.removeValue(forKey: key)
            engineLastUsedAt.removeValue(forKey: key)
            PluginLog.notice(
                "Evicted LRU MLX bridge: \(key.screenColor.displayName) \(key.rung)px on device \(key.deviceRegistryID) (kept \(budget) bridges to fit unified-memory budget)."
            )
        }
    }

    /// The shared v2 artifact uses a single resident engine on every device.
    private func bridgeBudget(for device: any MTLDevice) -> Int {
        let workingSetGB = Double(device.recommendedMaxWorkingSetSize) / (1024 * 1024 * 1024)
        return Self.bridgeBudget(forWorkingSetGB: workingSetGB)
    }

    /// Retains the testable budget interface; v2 uses one model at every tier.
    static func bridgeBudget(forWorkingSetGB workingSetGB: Double) -> Int {
        // The single artifact handles every rung; duplicate engines would
        // duplicate several gigabytes of weights without improving concurrency.
        1
    }

    // MARK: - Test hooks

    /// Snapshot of `(rung, screenColor, lastUsedAt)` triples currently
    /// resident for `device`. Test-only — production code never inspects
    /// this. The values are copied out of the lock so the caller can
    /// iterate without contention.
    func residentEnginesSnapshot(
        deviceRegistryID: UInt64
    ) -> [(rung: Int, screenColor: ScreenColor, lastUsedAt: ContinuousClock.Instant)] {
        lock.lock()
        defer { lock.unlock() }
        return engines.keys
            .filter { $0.deviceRegistryID == deviceRegistryID }
            .compactMap { key in
                guard let when = engineLastUsedAt[key] else { return nil }
                return (rung: key.rung, screenColor: key.screenColor, lastUsedAt: when)
            }
            .sorted { lhs, rhs in
                if lhs.rung != rhs.rung { return lhs.rung < rhs.rung }
                return lhs.screenColor.rawValue < rhs.screenColor.rawValue
            }
    }
}
