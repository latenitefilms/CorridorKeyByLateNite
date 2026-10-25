import Darwin
import Foundation

/// Serializable metadata for a disposable frame stored inside this host's sandbox.
/// No absolute paths or user-supplied filenames cross the FxPlug boundary.
public struct AnalysisFrameReference: Codable, Hashable, Sendable {
    /// Identifies one analysis pass; changing a clip or its hints starts a new pass.
    public let sessionID: UUID
    /// Identifies an immutable, atomically written CKF1 payload.
    public let frameID: UUID
    /// Bounds allocation and detects incomplete or replaced files before decoding.
    public let byteCount: Int
}

/// Recoverable failures for disposable analysis storage.
public enum AnalysisDiskCacheError: Error, LocalizedError {
    /// The pass was evicted, cleared, or created on another Mac.
    case missingFrame
    /// The active passes and the next frame exceed available storage.
    case storageFull
    /// The cache directory or its coordination lock cannot be opened.
    case unavailable
    /// A saved frame or its accounting metadata is malformed.
    case invalidFrame

    /// Recovery guidance suitable for either host's error presentation.
    public var errorDescription: String? {
        switch self {
        case .missingFrame: "Cached analysis is unavailable on this Mac. Choose Analyse Clip again."
        case .storageFull: "There is not enough analysis cache space. Free disk space or analyse at a lower Quality."
        case .unavailable: "The analysis cache could not be opened."
        case .invalidFrame: "The cached analysis frame is damaged. Choose Analyse Clip again."
        }
    }
}

/// Bounded, disposable frame storage shared by the standalone and FxPlug code.
/// Each host uses its own sandbox cache directory. Saved effects contain only
/// references: moving a library to another Mac requires analysis again.
///
/// Files are grouped by analysis pass. Cross-process file locks protect active
/// passes from eviction and serialize disk accounting. Old inactive passes are
/// evicted as a whole, least recently used first. RAM holds a strict byte-limited
/// LRU of compressed frames; a single worker prefetches only the latest request.
public final class AnalysisDiskCache: @unchecked Sendable {
    /// Production cache: at most 128 MiB compressed frames in RAM and 64 GiB
    /// frame payloads on disk. A pass that cannot fit fails explicitly.
    public static let shared = AnalysisDiskCache(
        directory: URL.cachesDirectory.appending(path: "CorridorKey by LateNite/Analysis-v1"),
        memoryLimit: 128 * 1024 * 1024,
        diskLimit: 64 * 1024 * 1024 * 1024
    )

    /// Identical policy explanation displayed by both inspectors.
    public static let storageExplanation = "Analysis is cached on this Mac. Moving a library to another Mac or clearing the cache requires Analyse Clip again."

    /// Keeps a pass in use until its owner finishes analysis or export.
    public final class Session: @unchecked Sendable {
        /// Stable identifier used by every frame in this analysis pass.
        public let id: UUID
        fileprivate let directory: URL
        private let descriptor: Int32

        fileprivate init(id: UUID, directory: URL, descriptor: Int32) {
            self.id = id
            self.directory = directory
            self.descriptor = descriptor
        }

        deinit { close(descriptor) }
    }

    private struct Manifest: Codable {
        var bytes: Int
        var lastAccess: Date
    }

    private struct MemoryEntry {
        let data: Data
        var access: UInt64
    }

    private let directory: URL
    private let memoryLimit: Int
    private let diskLimit: Int
    private let lock = NSLock()
    private var memory: [AnalysisFrameReference: MemoryEntry] = [:]
    private var memoryBytes = 0
    private var access: UInt64 = 0
    private var prefetchTarget: AnalysisFrameReference?
    private var prefetchRunning = false

    /// Creates an isolated cache; custom directories and limits support tests.
    public init(directory: URL, memoryLimit: Int, diskLimit: Int) {
        self.directory = directory
        self.memoryLimit = max(0, memoryLimit)
        self.diskLimit = max(0, diskLimit)
    }

    /// Actual retained compressed payload bytes, excluding callers' temporary copies.
    public var retainedMemoryBytes: Int { lock.withLock { memoryBytes } }

    /// Starts an empty pass and pins it against eviction until the returned owner releases it.
    public func beginSession() throws -> Session {
        try withDiskLock {
            // A process can exit between publishing a frame and updating its
            // manifest. Repair accounting once per pass, outside the frame loop.
            try reconcileDiskUsage()
            let identifier = UUID()
            let folder = sessionDirectory(identifier)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try writeManifest(Manifest(bytes: 0, lastAccess: .now), in: folder)
            return try pin(identifier, folder: folder)
        }
    }

    /// Pins existing passes for a multi-frame export. Missing passes fail before rendering.
    public func pinSessions(for references: [AnalysisFrameReference]) throws -> [Session] {
        try withDiskLock {
            try Set(references.map(\.sessionID)).map { identifier in
                let folder = sessionDirectory(identifier)
                guard FileManager.default.fileExists(atPath: folder.appending(path: "manifest.json").path) else {
                    throw AnalysisDiskCacheError.missingFrame
                }
                return try pin(identifier, folder: folder)
            }
        }
    }

    /// Stores a complete frame without keeping the whole clip resident in RAM.
    public func store(_ data: Data, in session: Session) throws -> AnalysisFrameReference {
        guard AnalysisFrameCodec.parseHeader(data) != nil,
              session.directory == sessionDirectory(session.id) else {
            throw AnalysisDiskCacheError.invalidFrame
        }
        let reference = AnalysisFrameReference(sessionID: session.id, frameID: UUID(), byteCount: data.count)
        try withDiskLock {
            try makeSpace(for: data.count, protecting: session.id)
            let file = frameURL(reference)
            var manifest = try readManifest(in: session.directory)
            try data.write(to: file, options: .atomic)
            do {
                let (updatedBytes, overflow) = manifest.bytes.addingReportingOverflow(data.count)
                guard !overflow else { throw AnalysisDiskCacheError.invalidFrame }
                manifest.bytes = updatedBytes
                manifest.lastAccess = .now
                try writeManifest(manifest, in: session.directory)
            } catch {
                try? FileManager.default.removeItem(at: file)
                throw error
            }
        }
        // Analysis streams forward; retaining every freshly encoded frame would
        // evict the playback working set and adds no value until it is requested.
        return reference
    }

    /// Loads an immutable frame, validating its size and envelope before caching it.
    public func load(_ reference: AnalysisFrameReference) throws -> Data {
        guard reference.byteCount > 16, reference.byteCount <= 4096 * 4096 * 10 + 16 else {
            throw AnalysisDiskCacheError.invalidFrame
        }
        if let cached = lock.withLock({ () -> Data? in
            guard var entry = memory[reference] else { return nil }
            access &+= 1
            entry.access = access
            memory[reference] = entry
            return entry.data
        }) { return cached }

        let data = try withDiskLock {
            let file = frameURL(reference)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                  (attributes[.size] as? NSNumber)?.intValue == reference.byteCount else {
                throw AnalysisDiskCacheError.missingFrame
            }
            let data = try Data(contentsOf: file)
            guard data.count == reference.byteCount, AnalysisFrameCodec.parseHeader(data) != nil else {
                throw AnalysisDiskCacheError.invalidFrame
            }
            let folder = sessionDirectory(reference.sessionID)
            var manifest = try readManifest(in: folder)
            if Date.now.timeIntervalSince(manifest.lastAccess) > 60 {
                manifest.lastAccess = .now
                try writeManifest(manifest, in: folder)
            }
            return data
        }
        lock.withLock {
            guard data.count <= memoryLimit else { return }
            if let previous = memory.removeValue(forKey: reference) { memoryBytes -= previous.data.count }
            while memoryBytes + data.count > memoryLimit,
                  let oldest = memory.min(by: { $0.value.access < $1.value.access }) {
                memoryBytes -= oldest.value.data.count
                memory.removeValue(forKey: oldest.key)
            }
            access &+= 1
            memory[reference] = MemoryEntry(data: data, access: access)
            memoryBytes += data.count
        }
        return data
    }

    /// Coalesces scrub requests into one bounded background disk reader.
    public func prefetch(_ reference: AnalysisFrameReference) {
        let start = lock.withLock {
            guard memory[reference] == nil else { return false }
            prefetchTarget = reference
            guard !prefetchRunning else { return false }
            prefetchRunning = true
            return true
        }
        guard start else { return }
        Task.detached(priority: .utility) { [weak self] in
            self?.drainPrefetch()
        }
    }

    /// Releases the RAM working set without deleting saved analysis files.
    public func clearMemory() {
        lock.withLock {
            memory.removeAll()
            memoryBytes = 0
            prefetchTarget = nil
        }
    }

    private func drainPrefetch() {
        while let target = lock.withLock({ () -> AnalysisFrameReference? in
            guard let target = prefetchTarget else {
                prefetchRunning = false
                return nil
            }
            prefetchTarget = nil
            return target
        }) {
            // A missing speculative frame is reported if an actual render requests it.
            _ = try? load(target)
        }
    }

    private func sessionDirectory(_ identifier: UUID) -> URL {
        directory.appending(path: identifier.uuidString, directoryHint: .isDirectory)
    }

    private func frameURL(_ reference: AnalysisFrameReference) -> URL {
        sessionDirectory(reference.sessionID).appending(path: reference.frameID.uuidString + ".ckf")
    }

    private func pin(_ identifier: UUID, folder: URL) throws -> Session {
        let descriptor = open(folder.appending(path: "lease.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw AnalysisDiskCacheError.unavailable }
        guard flock(descriptor, LOCK_SH | LOCK_NB) == 0 else {
            close(descriptor)
            throw AnalysisDiskCacheError.unavailable
        }
        return Session(id: identifier, directory: folder, descriptor: descriptor)
    }

    private func withDiskLock<Result>(_ operation: () throws -> Result) throws -> Result {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.appending(path: "cache.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw AnalysisDiskCacheError.unavailable }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw AnalysisDiskCacheError.unavailable }
        return try operation()
    }

    private func readManifest(in folder: URL) throws -> Manifest {
        let manifest = try JSONDecoder().decode(
            Manifest.self, from: Data(contentsOf: folder.appending(path: "manifest.json"))
        )
        guard manifest.bytes >= 0, manifest.lastAccess.timeIntervalSince1970.isFinite else {
            throw AnalysisDiskCacheError.invalidFrame
        }
        return manifest
    }

    private func writeManifest(_ manifest: Manifest, in folder: URL) throws {
        try JSONEncoder().encode(manifest).write(to: folder.appending(path: "manifest.json"), options: .atomic)
    }

    private func reconcileDiskUsage() throws {
        let folders = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        for folder in folders where UUID(uuidString: folder.lastPathComponent) != nil {
            let properties = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard properties.isDirectory == true, properties.isSymbolicLink != true else { continue }
            var bytes = 0
            for file in try FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
            ) where file.pathExtension == "ckf" {
                let attributes = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
                      let size = attributes.fileSize, size >= 0 else { continue }
                let (updatedBytes, overflow) = bytes.addingReportingOverflow(size)
                guard !overflow else { throw AnalysisDiskCacheError.invalidFrame }
                bytes = updatedBytes
            }
            let previous = try? readManifest(in: folder)
            if previous?.bytes != bytes {
                try writeManifest(Manifest(bytes: bytes, lastAccess: previous?.lastAccess ?? .now), in: folder)
            }
            // Recover the lease file too if an earlier beginSession was interrupted.
            let descriptor = open(folder.appending(path: "lease.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { throw AnalysisDiskCacheError.unavailable }
            close(descriptor)
        }
    }

    private func makeSpace(for requiredBytes: Int, protecting activeID: UUID) throws {
        guard requiredBytes <= diskLimit else { throw AnalysisDiskCacheError.storageFull }
        let folders = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let passes = folders.compactMap { folder -> (UUID, URL, Manifest)? in
            guard let identifier = UUID(uuidString: folder.lastPathComponent),
                  let manifest = try? readManifest(in: folder), manifest.bytes >= 0 else { return nil }
            return (identifier, folder, manifest)
        }.sorted { $0.2.lastAccess < $1.2.lastAccess }
        var totalBytes = 0
        for pass in passes {
            let (updatedBytes, overflow) = totalBytes.addingReportingOverflow(pass.2.bytes)
            guard !overflow else { throw AnalysisDiskCacheError.invalidFrame }
            totalBytes = updatedBytes
        }
        for (identifier, folder, manifest) in passes where totalBytes > diskLimit - requiredBytes {
            guard identifier != activeID else { continue }
            let descriptor = open(folder.appending(path: "lease.lock").path, O_RDWR)
            guard descriptor >= 0 else { continue }
            defer { close(descriptor) }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { continue }
            try FileManager.default.removeItem(at: folder)
            totalBytes -= manifest.bytes
            lock.withLock {
                let obsolete = memory.keys.filter { $0.sessionID == identifier }
                for key in obsolete {
                    if let entry = memory.removeValue(forKey: key) { memoryBytes -= entry.data.count }
                }
            }
        }
        guard totalBytes <= diskLimit - requiredBytes else { throw AnalysisDiskCacheError.storageFull }
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: directory.path)
        if let freeBytes = (attributes[.systemFreeSize] as? NSNumber)?.int64Value,
           freeBytes < Int64(requiredBytes) * 2 + 512 * 1024 * 1024 {
            throw AnalysisDiskCacheError.storageFull
        }
    }
}
