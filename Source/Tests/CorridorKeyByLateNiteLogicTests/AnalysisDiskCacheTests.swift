import Foundation
import Testing
@testable import CorridorKeyToolboxLogic

@Suite("Bounded analysis storage")
struct AnalysisDiskCacheTests {
    private func frame(_ value: Float = 0.4) throws -> Data {
        try AnalysisFrameCodec.encode(
            alpha: [Float](repeating: 0.7, count: 16 * 16),
            foregroundHalfRGBA: AnalysisFrameCodec.foregroundHalfRGBA(
                [Float](repeating: value, count: 16 * 16 * 4)
            ), width: 16, height: 16
        )
    }

    @Test("Payloads survive reopening while metadata and the RAM working set stay small")
    func persistenceAndMemoryBudget() throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let blob = try frame()
        let cache = AnalysisDiskCache(directory: folder, memoryLimit: blob.count, diskLimit: blob.count * 10)
        let session = try cache.beginSession()
        let first = try cache.store(blob, in: session)
        let second = try cache.store(blob, in: session)
        #expect(cache.retainedMemoryBytes == 0)
        #expect(try cache.load(first) == blob)
        #expect(try cache.load(second) == blob)
        #expect(cache.retainedMemoryBytes == blob.count)
        let reopened = AnalysisDiskCache(directory: folder, memoryLimit: 0, diskLimit: blob.count * 10)
        #expect(try reopened.load(first) == blob)
        #expect(reopened.retainedMemoryBytes == 0)
        var state = PluginStateData()
        state.cachedFrameReference = first
        let encoded = try state.encodedForHost()
        let decoded = PluginStateData.decoded(from: encoded)
        #expect(decoded.cachedFrameReference == first)
        #expect(decoded.cachedMatteBlob == nil)
        withExtendedLifetime(session) {}
    }

    @Test("Disk quota protects active passes and evicts inactive passes")
    func diskQuotaAndLeases() throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let blob = try frame()
        let cache = AnalysisDiskCache(directory: folder, memoryLimit: 0, diskLimit: blob.count)
        var firstSession: AnalysisDiskCache.Session? = try cache.beginSession()
        let first = try cache.store(blob, in: #require(firstSession))
        let secondSession = try cache.beginSession()
        #expect(throws: AnalysisDiskCacheError.self) { try cache.store(blob, in: secondSession) }
        firstSession = nil
        var exportLeases: [AnalysisDiskCache.Session]? = try cache.pinSessions(for: [first])
        #expect(exportLeases?.count == 1)
        #expect(throws: AnalysisDiskCacheError.self) { try cache.store(blob, in: secondSession) }
        exportLeases = nil
        let second = try cache.store(blob, in: secondSession)
        #expect(throws: AnalysisDiskCacheError.self) { try cache.load(first) }
        #expect(try cache.load(second) == blob)
        withExtendedLifetime(secondSession) {}
    }

    @Test("Missing and damaged payloads fail explicitly instead of producing source pass-through")
    func damagedFrames() throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = AnalysisDiskCache(directory: folder, memoryLimit: 0, diskLimit: 1_000_000)
        let session = try cache.beginSession()
        let reference = try cache.store(frame(), in: session)
        let file = folder.appending(path: reference.sessionID.uuidString).appending(path: reference.frameID.uuidString + ".ckf")
        try Data([0]).write(to: file)
        #expect(throws: AnalysisDiskCacheError.self) { try cache.load(reference) }
        try FileManager.default.removeItem(at: file)
        #expect(throws: AnalysisDiskCacheError.self) { try cache.load(reference) }
        #expect(throws: AnalysisDiskCacheError.self) { try cache.store(Data(), in: session) }
        withExtendedLifetime(session) {}
    }

    @Test("Concurrent writers preserve independent immutable frames and respect the memory limit")
    func concurrentFrames() async throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = AnalysisDiskCache(directory: folder, memoryLimit: 512, diskLimit: 1_000_000)
        let session = try cache.beginSession()
        let payloads = try (0..<12).map { try frame(Float($0) / 12) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for blob in payloads {
                group.addTask {
                    let reference = try cache.store(blob, in: session)
                    #expect(try cache.load(reference) == blob)
                }
            }
            try await group.waitForAll()
        }
        #expect(cache.retainedMemoryBytes <= 512)
        cache.clearMemory()
        #expect(cache.retainedMemoryBytes == 0)
    }

    @Test("An interrupted manifest update cannot bypass the disk quota after reopening")
    func interruptedAccounting() throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let blob = try frame()
        let cache = AnalysisDiskCache(directory: folder, memoryLimit: 0, diskLimit: blob.count)
        let firstSession = try cache.beginSession()
        let first = try cache.store(blob, in: firstSession)
        let manifest = folder.appending(path: first.sessionID.uuidString).appending(path: "manifest.json")
        // Simulate a crash after the atomic frame write but before metadata commit.
        try Data("{}".utf8).write(to: manifest)
        let reopened = AnalysisDiskCache(directory: folder, memoryLimit: 0, diskLimit: blob.count)
        let secondSession = try reopened.beginSession()
        #expect(try reopened.load(first) == blob)
        #expect(throws: AnalysisDiskCacheError.self) { try reopened.store(blob, in: secondSession) }
        withExtendedLifetime(firstSession) {}
    }
}
