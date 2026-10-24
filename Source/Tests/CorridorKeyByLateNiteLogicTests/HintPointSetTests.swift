//
//  HintPointSetTests.swift
//  CorridorKeyToolboxLogicTests
//
//  Round-trip and editing semantics for the on-screen control's
//  hint-point storage. The set is the single source of truth that
//  travels through the FCP Library, so any encoding regression or
//  off-by-one in `removeNearest` would lose user-placed dots.
//

import Foundation
import CoreMedia
import Testing
@testable import CorridorKeyToolboxLogic

@Suite("HintPointSet")
struct HintPointSetTests {

    @Test("Round-trip via parameter dictionary preserves every point")
    func dictionaryRoundTrip() throws {
        let original = HintPointSet(points: [
            HintPoint(x: 0.25, y: 0.5, kind: .foreground, radiusNormalized: 0.05),
            HintPoint(x: 0.75, y: 0.5, kind: .background, radiusNormalized: 0.04)
        ])
        let dict = original.asParameterDictionary()
        let decoded = HintPointSet.fromParameterDictionary(dict)
        #expect(decoded.points.count == 2)
        #expect(decoded.points[0].kind == .foreground)
        #expect(decoded.points[0].x == 0.25)
        #expect(decoded.points[1].kind == .background)
        #expect(decoded.points[1].radiusNormalized == 0.04)
    }

    @Test("Dictionary decode accepts NSString keys and NSData values")
    func nsDictionaryRoundTrip() throws {
        let original = HintPointSet(points: [
            HintPoint(x: 0.45, y: 0.55, kind: .foreground, radiusNormalized: 0.03)
        ])
        let dictionary = NSMutableDictionary()
        dictionary[NSString(string: "blob")] = try original.encodedForHost() as NSData

        let decoded = HintPointSet.fromParameterDictionary(dictionary)

        #expect(decoded.points.count == 1)
        #expect(decoded.points[0].x == 0.45)
        #expect(decoded.points[0].kind == .foreground)
    }

    @Test("Empty dictionary decodes to empty set")
    func emptyDictionary() {
        let decoded = HintPointSet.fromParameterDictionary(NSDictionary())
        #expect(decoded.isEmpty)
    }

    @Test("nil dictionary decodes to empty set")
    func nilDictionary() {
        let decoded = HintPointSet.fromParameterDictionary(nil)
        #expect(decoded.isEmpty)
    }

    @Test("removeNearest removes the closest point inside tolerance")
    func removeNearestInsideTolerance() {
        var set = HintPointSet(points: [
            HintPoint(x: 0.1, y: 0.1, kind: .foreground),
            HintPoint(x: 0.5, y: 0.5, kind: .foreground),
            HintPoint(x: 0.9, y: 0.9, kind: .foreground)
        ])
        let removed = set.removeNearest(toX: 0.51, y: 0.49, tolerance: 0.05)
        #expect(removed == true)
        #expect(set.points.count == 2)
        #expect(set.points[0].x == 0.1)
        #expect(set.points[1].x == 0.9)
    }

    @Test("removeNearest leaves points outside tolerance alone")
    func removeNearestOutsideTolerance() {
        var set = HintPointSet(points: [
            HintPoint(x: 0.1, y: 0.1, kind: .foreground)
        ])
        let removed = set.removeNearest(toX: 0.5, y: 0.5, tolerance: 0.05)
        #expect(removed == false)
        #expect(set.points.count == 1)
    }

    @Test("clear empties the set")
    func clearEmpties() {
        var set = HintPointSet(points: [
            HintPoint(x: 0.1, y: 0.1, kind: .foreground),
            HintPoint(x: 0.9, y: 0.9, kind: .background)
        ])
        set.clear()
        #expect(set.isEmpty)
    }
    @Test("Hints stay on their source frames at fractional frame rates and round-trip through FxPlug")
    func frameScopedRoundTrip() throws {
        let duration = CMTime(value: 1001, timescale: 30000)
        let firstTime = CMTime(value: 1001 * 108000, timescale: 30000)
        let secondTime = CMTimeAdd(firstTime, duration)
        let firstFrame = try #require(HintFrame(time: firstTime, duration: duration))
        let secondFrame = try #require(HintFrame(time: secondTime, duration: duration))
        let foreground = HintPoint(x: 0.5, y: 0.5, kind: .foreground, frame: firstFrame)
        let background = HintPoint(x: 0.5, y: 0.5, kind: .background, frame: secondFrame)
        let original = HintPointSet(points: [foreground, background])
        let restored = HintPointSet.fromParameterDictionary(original.asParameterDictionary())
        #expect(restored == original)
        #expect(restored.points(at: firstTime) == [foreground])
        #expect(restored.points(at: secondTime) == [background])
        #expect(restored.points(at: CMTimeAdd(secondTime, duration)).isEmpty)
        #expect(restored.points(at: CMTimeConvertScale(firstTime, timescale: 60000, method: .default)) == [foreground])
        #expect(!restored.hasLegacyPoints)
    }

    @Test("Erasing and clearing a frame preserve annotations at the same position on other frames")
    func frameScopedEditing() throws {
        let duration = CMTime(value: 1, timescale: 24)
        let firstFrame = try #require(HintFrame(time: .zero, duration: duration))
        let secondFrame = try #require(HintFrame(time: duration, duration: duration))
        let first = HintPoint(x: 0.5, y: 0.5, kind: .foreground, frame: firstFrame)
        let second = HintPoint(x: 0.5, y: 0.5, kind: .background, frame: secondFrame)
        var hints = HintPointSet(points: [first, second])
        let removed = hints.removeNearest(toX: 0.5, y: 0.5, tolerance: 0.05, at: .zero)
        #expect(removed)
        #expect(hints.points == [second])
        let removedFromOtherFrame = hints.removeNearest(toX: 0.5, y: 0.5, tolerance: 0.05, at: .zero)
        #expect(!removedFromOtherFrame)
        hints.add(first)
        hints.clear(at: duration)
        #expect(hints.points == [first])
    }

    @Test("Legacy untimed hints decode without losing annotations or silently assigning a frame")
    func legacyHints() throws {
        let payload = Data(#"{"points":[{"x":0.25,"y":0.75,"kind":1,"radiusNormalized":0.04}]}"#.utf8)
        let hints = try JSONDecoder().decode(HintPointSet.self, from: payload)
        #expect(hints.hasLegacyPoints)
        #expect(hints.points(at: .zero) == hints.points)
        #expect(hints.points(at: CMTime(value: 10, timescale: 24)) == hints.points)
    }

    @Test("Invalid timestamps and durations never create global annotations")
    func invalidFrameTimes() throws {
        let duration = CMTime(value: 1, timescale: 24)
        #expect(HintFrame(time: .invalid, duration: duration) == nil)
        #expect(HintFrame(time: .indefinite, duration: duration) == nil)
        #expect(HintFrame(time: .zero, duration: .zero) == nil)
        #expect(HintFrame(time: .zero, duration: CMTime(value: -1, timescale: 24)) == nil)
        let frame = try #require(HintFrame(time: .zero, duration: duration))
        #expect(!frame.contains(.invalid))
        #expect(!frame.contains(duration))
        #expect(!frame.contains(CMTime(value: 0, timescale: 24, flags: .valid, epoch: 1)))
    }

}
