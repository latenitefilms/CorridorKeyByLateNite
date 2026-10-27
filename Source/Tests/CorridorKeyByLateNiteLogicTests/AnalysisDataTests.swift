//
//  AnalysisDataTests.swift
//  CorridorKeyToolboxLogicTests
//
//  Exercises the NSDictionary round-trip that the FxPlug custom parameter
//  uses for on-disk persistence, plus the frame-index math the render path
//  relies on to locate the right matte for the current play-head.
//

import Foundation
import CoreMedia
import Testing
@testable import CorridorKeyToolboxLogic

@Suite("AnalysisData")
struct AnalysisDataTests {

    @Test("Cache selection honours the quality choice independently of preview resolution")
    func cacheQualityIdentity() {
        let data = AnalysisData(
            schemaVersion: AnalysisData.currentSchemaVersion,
            frameDuration: CMTime(value: 1, timescale: 30), firstFrameTime: .zero,
            frameCount: 1, analyzedCount: 1, screenColorRaw: 0,
            qualityModeRaw: QualityMode.automatic.rawValue,
            inferenceResolution: 1536, matteWidth: 1536, matteHeight: 864,
            mattes: [0: Data([1])]
        )
        #expect(data.cachedMatte(at: .zero, screenColorRaw: 0,
                                qualityModeRaw: QualityMode.automatic.rawValue)?.inferenceResolution == 1536)
        // Even an explicit selection with the same resolution changes identity.
        #expect(data.cachedMatte(at: .zero, screenColorRaw: 0,
                                qualityModeRaw: QualityMode.ultra1536.rawValue) == nil)
    }

    @Test("Decoded metadata tracks host edits, undo and reset without crossing instances")
    func metadataSnapshotLifetime() throws {
        let store = AnalysisSnapshotStore()
        let original = AnalysisData(
            schemaVersion: AnalysisData.currentSchemaVersion,
            frameDuration: CMTime(value: 1, timescale: 30), firstFrameTime: .zero,
            frameCount: 1, analyzedCount: 1, screenColorRaw: 0, qualityModeRaw: 0,
            inferenceResolution: 512, matteWidth: 512, matteHeight: 512,
            mattes: [0: Data([1])]
        )
        let dictionary = original.asParameterDictionary()
        #expect(store.load(dictionary)?.mattes[0] == Data([1]))
        #expect(store.load(dictionary.copy() as? NSDictionary)?.mattes[0] == Data([1]))
        let changed = try #require(dictionary.mutableCopy() as? NSMutableDictionary)
        changed[AnalysisDataKey.mattes] = ["0": Data([2])] as NSDictionary
        #expect(store.load(changed)?.mattes[0] == Data([2]))
        #expect(store.load(dictionary)?.mattes[0] == Data([1]), "Undo restores the earlier host value")
        #expect(store.load(nil)?.mattes[0] == Data([1]), "A failed IPC read can use this instance's last snapshot")
        #expect(store.load(NSDictionary()) == nil, "A successful empty host value must invalidate analysis")
        #expect(store.load(nil) == nil, "Old frames cannot reappear after a host reset")
        #expect(store.load(dictionary)?.mattes[0] == Data([1]))
        #expect(AnalysisSnapshotStore().load(nil) == nil, "Separate effect instances never borrow analysis")
        store.clear()
        #expect(store.load(nil) == nil)
        #expect(store.load(dictionary)?.mattes[0] == Data([1]), "Reset also clears the decoded dictionary")
    }

    @Test("FxPlug persistence stores compact references without embedding frame pixels")
    func diskReferenceRoundTrip() throws {
        let sessionID = UUID()
        let references = Dictionary(uniqueKeysWithValues: (0..<1000).map { index in
            (index, AnalysisFrameReference(sessionID: sessionID, frameID: UUID(), byteCount: 37_000_000))
        })
        let original = AnalysisData(
            schemaVersion: AnalysisData.currentSchemaVersion,
            frameDuration: CMTime(value: 1, timescale: 24), firstFrameTime: .zero,
            frameCount: 1000, analyzedCount: 1000, screenColorRaw: 0,
            qualityModeRaw: QualityMode.maximum2048.rawValue,
            inferenceResolution: 2048, matteWidth: 2048, matteHeight: 2048,
            mattes: [:], frameReferences: references
        )
        let dictionary = original.asParameterDictionary()
        let archive = try NSKeyedArchiver.archivedData(withRootObject: dictionary, requiringSecureCoding: true)
        // A thousand 37 MB frames must remain small library metadata.
        #expect(archive.count < 200_000)
        let decoded = try NSKeyedUnarchiver.unarchivedObject(
            ofClasses: [NSDictionary.self, NSString.self, NSNumber.self, NSData.self], from: archive
        ) as? NSDictionary
        let restored = try #require(AnalysisData.fromParameterDictionary(decoded))
        #expect(restored.frameReferences == references)
        #expect(restored.mattes.isEmpty)
        let last = try #require(restored.cachedMatte(at: CMTime(value: 999, timescale: 24), screenColorRaw: 0))
        #expect(last.reference == references[999])
        #expect(last.blob == nil)
    }

    @Test("Dictionary round-trip preserves every field")
    func dictionaryRoundTrip() {
        let matteA = Data([0x01, 0x02, 0x03])
        let matteB = Data([0x04, 0x05])
        let original = AnalysisData(
            schemaVersion: AnalysisData.currentSchemaVersion,
            frameDuration: CMTime(value: 1, timescale: 30),
            firstFrameTime: CMTime(value: 0, timescale: 30),
            frameCount: 2,
            analyzedCount: 2,
            screenColorRaw: 0,
            qualityModeRaw: QualityMode.maximum2048.rawValue,
            inferenceResolution: 1024,
            matteWidth: 1024,
            matteHeight: 1024,
            mattes: [0: matteA, 1: matteB]
        )
        let dict = original.asParameterDictionary()
        let roundTripped = AnalysisData.fromParameterDictionary(dict)
        let restored = try? #require(roundTripped)

        #expect(restored?.schemaVersion == AnalysisData.currentSchemaVersion)
        #expect(restored?.frameCount == 2)
        #expect(restored?.analyzedCount == 2)
        #expect(restored?.inferenceResolution == 1024)
        #expect(restored?.matteWidth == 1024)
        #expect(restored?.matteHeight == 1024)
        #expect(restored?.mattes[0] == matteA)
        #expect(restored?.mattes[1] == matteB)
        #expect(restored?.qualityModeRaw == QualityMode.maximum2048.rawValue)
        #expect(CMTimeCompare(restored?.frameDuration ?? .invalid, CMTime(value: 1, timescale: 30)) == 0)
        #expect(CMTimeCompare(restored?.firstFrameTime ?? .invalid, CMTime(value: 0, timescale: 30)) == 0)
    }

    @Test("Schema version mismatch rejects the dictionary")
    func schemaVersionMismatch() {
        let dict = NSMutableDictionary()
        dict[AnalysisDataKey.schemaVersion] = NSNumber(value: AnalysisData.currentSchemaVersion + 99)
        dict[AnalysisDataKey.frameCount] = NSNumber(value: 1)
        #expect(AnalysisData.fromParameterDictionary(dict) == nil)
    }

    @Test("Nil dictionary decodes as nil")
    func nilDictionaryReturnsNil() {
        #expect(AnalysisData.fromParameterDictionary(nil) == nil)
    }

    @Test("Caches created before frame-specific hints and canonical image rows require reanalysis")
    func previousModelCacheIsRejected() {
        for schema in [3, 4, 5, 6] {
            let dictionary = NSMutableDictionary()
            dictionary[AnalysisDataKey.schemaVersion] = NSNumber(value: schema)
            dictionary[AnalysisDataKey.frameCount] = NSNumber(value: 1)
            #expect(AnalysisData.fromParameterDictionary(dictionary) == nil)
        }
    }

    @Test("Frame index maps render time to the right slot")
    func frameIndexMapping() {
        let data = AnalysisData(
            schemaVersion: AnalysisData.currentSchemaVersion,
            frameDuration: CMTime(value: 1, timescale: 30),
            firstFrameTime: CMTime(value: 0, timescale: 30),
            frameCount: 10,
            analyzedCount: 10,
            screenColorRaw: 0,
            qualityModeRaw: QualityMode.draft512.rawValue,
            inferenceResolution: 512,
            matteWidth: 512,
            matteHeight: 512,
            mattes: [:]
        )
        #expect(data.frameIndex(for: CMTime(value: 0, timescale: 30)) == 0)
        #expect(data.frameIndex(for: CMTime(value: 5, timescale: 30)) == 5)
        #expect(data.frameIndex(for: CMTime(value: 9, timescale: 30)) == 9)
        #expect(data.frameIndex(for: CMTime(value: 10, timescale: 30)) == nil)
        #expect(data.frameIndex(for: CMTime(value: -1, timescale: 30)) == nil)
    }

    @Test("Frame index honours non-zero first frame time")
    func frameIndexMappingWithOffsetStart() {
        let data = AnalysisData(
            schemaVersion: AnalysisData.currentSchemaVersion,
            frameDuration: CMTime(value: 1, timescale: 24),
            firstFrameTime: CMTime(value: 48, timescale: 24),
            frameCount: 4,
            analyzedCount: 4,
            screenColorRaw: 0,
            qualityModeRaw: QualityMode.draft512.rawValue,
            inferenceResolution: 512,
            matteWidth: 512,
            matteHeight: 512,
            mattes: [:]
        )
        #expect(data.frameIndex(for: CMTime(value: 47, timescale: 24)) == nil)
        #expect(data.frameIndex(for: CMTime(value: 48, timescale: 24)) == 0)
        #expect(data.frameIndex(for: CMTime(value: 51, timescale: 24)) == 3)
        #expect(data.frameIndex(for: CMTime(value: 52, timescale: 24)) == nil)
    }

    @Test("Matte lookup returns the entry for the requested time")
    func matteLookup() {
        let data = AnalysisData(
            schemaVersion: AnalysisData.currentSchemaVersion,
            frameDuration: CMTime(value: 1, timescale: 30),
            firstFrameTime: CMTime(value: 0, timescale: 30),
            frameCount: 3,
            analyzedCount: 2,
            screenColorRaw: 0,
            qualityModeRaw: QualityMode.draft512.rawValue,
            inferenceResolution: 512,
            matteWidth: 512,
            matteHeight: 512,
            mattes: [
                0: Data([0xAA]),
                2: Data([0xCC])
            ]
        )
        #expect(data.matte(at: CMTime(value: 0, timescale: 30)) == Data([0xAA]))
        #expect(data.matte(at: CMTime(value: 1, timescale: 30)) == nil)
        #expect(data.matte(at: CMTime(value: 2, timescale: 30)) == Data([0xCC]))
        #expect(data.matte(at: CMTime(value: 3, timescale: 30)) == nil)
    }

    @Test("Cached matte lookup also validates screen colour")
    func cachedMatteLookupValidatesScreenColor() throws {
        let matte = Data([0x11, 0x22])
        let data = AnalysisData(
            schemaVersion: AnalysisData.currentSchemaVersion,
            frameDuration: CMTime(value: 1, timescale: 30),
            firstFrameTime: CMTime(value: 0, timescale: 30),
            frameCount: 1,
            analyzedCount: 1,
            screenColorRaw: ScreenColor.green.rawValue,
            qualityModeRaw: QualityMode.draft512.rawValue,
            inferenceResolution: 512,
            matteWidth: 512,
            matteHeight: 512,
            mattes: [0: matte]
        )

        let cacheHit = try #require(data.cachedMatte(
            at: CMTime(value: 0, timescale: 30),
            screenColorRaw: ScreenColor.green.rawValue
        ))
        #expect(cacheHit.blob == matte)
        #expect(cacheHit.inferenceResolution == 512)
        #expect(data.cachedMatte(
            at: CMTime(value: 0, timescale: 30),
            screenColorRaw: ScreenColor.blue.rawValue
        ) == nil)
    }
    @Test("Persisted cache rejects added, removed, retimed hints and changes to Hint mode")
    func hintCacheInvalidation() throws {
        let duration = CMTime(value: 1, timescale: 24)
        let frame = try #require(HintFrame(time: .zero, duration: duration))
        let points = HintPointSet(points: [HintPoint(x: 0.5, y: 0.5, kind: .background, frame: frame)])
        let configuration = AnalysisHintConfiguration(mode: .manual, points: points)
        let original = AnalysisData(
            schemaVersion: AnalysisData.currentSchemaVersion, frameDuration: duration,
            firstFrameTime: .zero, frameCount: 1, analyzedCount: 1,
            screenColorRaw: 0, qualityModeRaw: 0, inferenceResolution: 512,
            matteWidth: 1, matteHeight: 1, mattes: [0: Data([1])],
            hintConfiguration: configuration
        )
        let restored = try #require(AnalysisData.fromParameterDictionary(original.asParameterDictionary()))
        #expect(restored.matchesHints(mode: .manual, points: points))
        #expect(restored.cachedMatte(at: .zero, screenColorRaw: 0, hintConfiguration: configuration) != nil)
        #expect(!restored.matchesHints(mode: .automatic, points: points))
        var changed = points
        let nextFrame = try #require(HintFrame(time: duration, duration: duration))
        changed.points[0].frame = nextFrame
        #expect(!restored.matchesHints(mode: .manual, points: changed))
        changed.add(HintPoint(x: 0.2, y: 0.3, kind: .foreground, frame: frame))
        #expect(restored.cachedMatte(at: .zero, screenColorRaw: 0,
                                  hintConfiguration: AnalysisHintConfiguration(mode: .manual, points: changed)) == nil)
        #expect(!restored.matchesHints(mode: .manual, points: HintPointSet()))
        var missingConfiguration = original
        missingConfiguration.hintConfiguration = nil
        #expect(missingConfiguration.cachedMatte(at: .zero, screenColorRaw: 0, hintConfiguration: configuration) == nil)
    }

}
