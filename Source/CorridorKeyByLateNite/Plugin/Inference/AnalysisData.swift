//
//  AnalysisData.swift
//  CorridorKey by LateNite
//
//  Strongly-typed model for the analysis cache that lives inside the FxPlug
//  custom parameter. Keeping this inside the Final Cut Pro Library (rather
//  than a disk sidecar) matches Apple's `FxBrightnessAnalysis` reference and
//  lets editors ship projects between machines without losing the cache.
//
//  The wire format is a single `NSDictionary` because that's what FxPlug's
//  custom parameter API can serialise through `NSSecureCoding`. The keys and
//  types here are the whole contract between the analyser (writer) and the
//  pluginState/render path (reader) — treat them as stable.
//

import Foundation
import CoreMedia

/// Dictionary keys used when flattening `AnalysisData` into the custom
/// parameter's `NSDictionary`. Changing any of these without bumping
/// `AnalysisData.currentSchemaVersion` will silently break saved libraries.
enum AnalysisDataKey {
    static let schemaVersion: String = "schemaVersion"
    static let frameDuration: String = "frameDuration"
    static let firstFrameTime: String = "firstFrameTime"
    static let frameCount: String = "frameCount"
    static let analyzedCount: String = "analyzedCount"
    static let screenColorRaw: String = "screenColorRaw"
    static let qualityModeRaw: String = "qualityModeRaw"
    static let inferenceResolution: String = "inferenceResolution"
    static let matteWidth: String = "matteWidth"
    static let matteHeight: String = "matteHeight"
    static let mattes: String = "mattes"
    static let hintConfiguration: String = "hintConfiguration"
}

/// In-memory representation of the analysis cache. Built either by the
/// analyser (accumulating frames) or by the render path (reading the custom
/// parameter).
struct AnalysisData: Sendable {

    /// Bump when the stored layout changes in a way that's incompatible with
    /// older plug-in versions. Readers treat mismatched versions as "no
    /// cache" so Analyse Clip has to rebuild. Bumped to `3` after adding
    /// `qualityModeRaw` so the inspector can tell the user when a saved
    /// cache no longer matches the Quality setting they've selected. Version 4
    /// invalidates v1 model mattes so saved clips are analysed with v2. Version 5
    /// requires complete alpha + reconstructed foreground frames (CKF1). Version 6
    /// records the annotations used to build the cache, including their frame times.
    /// Version 7 stores alpha and RGB in canonical top-down rows for every host.
    static let currentSchemaVersion: Int = 7

    let schemaVersion: Int
    let frameDuration: CMTime
    let firstFrameTime: CMTime
    let frameCount: Int
    let analyzedCount: Int
    let screenColorRaw: Int
    /// Raw value of the `QualityMode` that was active when this cache was
    /// built. If the user flips the Quality popup to a different rung, the
    /// cached matte resolution no longer matches the rung they want — the
    /// inspector header shows "Not analysed yet" so they know a re-analyse
    /// is needed.
    let qualityModeRaw: Int
    let inferenceResolution: Int
    let matteWidth: Int
    let matteHeight: Int
    /// Per-frame compressed matte payloads. Keyed by the frame's position in
    /// the analysis range (0-based). Missing keys indicate the analyser did
    /// not reach that frame yet — the render path treats that as a cache miss
    /// for that specific time.
    let mattes: [Int: Data]
    /// Immutable input snapshot: edits must not reuse mattes from older annotations.
    var hintConfiguration: AnalysisHintConfiguration? = nil

    /// Checks the entire annotation set because temporal blending can affect later frames.
    func matchesHints(mode: HintMode, points: HintPointSet) -> Bool {
        hintConfiguration == AnalysisHintConfiguration(mode: mode, points: points)
    }

    /// Returns the 0-based frame index for the given render time, relative to
    /// the analysed range. Returns `nil` when the render time sits outside
    /// the range or the frame duration is degenerate (would divide by zero).
    func frameIndex(for renderTime: CMTime) -> Int? {
        let durationSeconds = CMTimeGetSeconds(frameDuration)
        guard durationSeconds > 0 else { return nil }
        let deltaSeconds = CMTimeGetSeconds(CMTimeSubtract(renderTime, firstFrameTime))
        let index = Int((deltaSeconds / durationSeconds).rounded())
        guard index >= 0, index < frameCount else { return nil }
        return index
    }

    /// Returns the compressed matte blob for a given render time, or nil when
    /// the frame hasn't been analysed yet.
    func matte(at renderTime: CMTime) -> Data? {
        guard let index = frameIndex(for: renderTime) else { return nil }
        return mattes[index]
    }

    /// Returns the cached matte and its inference resolution when the
    /// analysis metadata matches the current render request.
    func cachedMatte(
        at renderTime: CMTime,
        screenColorRaw requestedScreenColorRaw: Int,
        hintConfiguration requestedHints: AnalysisHintConfiguration? = nil
    ) -> CachedAnalysisMatte? {
        guard requestedHints == nil || hintConfiguration == requestedHints,
              screenColorRaw == requestedScreenColorRaw,
              let blob = matte(at: renderTime)
        else { return nil }
        return CachedAnalysisMatte(blob: blob, inferenceResolution: inferenceResolution)
    }

    // MARK: - Dictionary round-trip

    /// Packs the cache into a dictionary that FxPlug can persist. Uses
    /// `NSDictionary` / `NSData` / `NSNumber` so the value passes the
    /// `classesForCustomParameterID:` whitelist that the host enforces.
    func asParameterDictionary() -> NSDictionary {
        let framesDictionary = NSMutableDictionary(capacity: mattes.count)
        for (index, matteData) in mattes {
            framesDictionary[NSString(string: String(index))] = matteData as NSData
        }

        let frameDurationDict = CMTimeCopyAsDictionary(frameDuration, allocator: kCFAllocatorDefault) as NSDictionary?
        let firstFrameTimeDict = CMTimeCopyAsDictionary(firstFrameTime, allocator: kCFAllocatorDefault) as NSDictionary?

        let contents = NSMutableDictionary()
        if let hintConfiguration {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            contents[AnalysisDataKey.hintConfiguration] = try? encoder.encode(hintConfiguration)
        }
        contents[AnalysisDataKey.schemaVersion] = NSNumber(value: schemaVersion)
        if let frameDurationDict {
            contents[AnalysisDataKey.frameDuration] = frameDurationDict
        }
        if let firstFrameTimeDict {
            contents[AnalysisDataKey.firstFrameTime] = firstFrameTimeDict
        }
        contents[AnalysisDataKey.frameCount] = NSNumber(value: frameCount)
        contents[AnalysisDataKey.analyzedCount] = NSNumber(value: analyzedCount)
        contents[AnalysisDataKey.screenColorRaw] = NSNumber(value: screenColorRaw)
        contents[AnalysisDataKey.qualityModeRaw] = NSNumber(value: qualityModeRaw)
        contents[AnalysisDataKey.inferenceResolution] = NSNumber(value: inferenceResolution)
        contents[AnalysisDataKey.matteWidth] = NSNumber(value: matteWidth)
        contents[AnalysisDataKey.matteHeight] = NSNumber(value: matteHeight)
        contents[AnalysisDataKey.mattes] = framesDictionary.copy() as? NSDictionary ?? NSDictionary()
        return contents.copy() as? NSDictionary ?? NSDictionary()
    }

    /// Reconstructs the cache from the dictionary the host hands us. Returns
    /// nil when the dictionary is missing required keys or lives at a future
    /// schema version we don't know how to read.
    static func fromParameterDictionary(_ dictionary: NSDictionary?) -> AnalysisData? {
        guard let dictionary else { return nil }

        let schemaVersion = (dictionary[AnalysisDataKey.schemaVersion] as? NSNumber)?.intValue ?? 0
        guard schemaVersion == currentSchemaVersion else { return nil }

        guard let frameDurationDict = dictionary[AnalysisDataKey.frameDuration] as? NSDictionary,
              let firstFrameTimeDict = dictionary[AnalysisDataKey.firstFrameTime] as? NSDictionary
        else {
            return nil
        }
        let frameDuration = CMTimeMakeFromDictionary(frameDurationDict as CFDictionary)
        let firstFrameTime = CMTimeMakeFromDictionary(firstFrameTimeDict as CFDictionary)

        let frameCount = (dictionary[AnalysisDataKey.frameCount] as? NSNumber)?.intValue ?? 0
        let analyzedCount = (dictionary[AnalysisDataKey.analyzedCount] as? NSNumber)?.intValue ?? 0
        let screenColorRaw = (dictionary[AnalysisDataKey.screenColorRaw] as? NSNumber)?.intValue ?? 0
        let qualityModeRaw = (dictionary[AnalysisDataKey.qualityModeRaw] as? NSNumber)?.intValue ?? 0
        let inferenceResolution = (dictionary[AnalysisDataKey.inferenceResolution] as? NSNumber)?.intValue ?? 0
        let matteWidth = (dictionary[AnalysisDataKey.matteWidth] as? NSNumber)?.intValue ?? 0
        let matteHeight = (dictionary[AnalysisDataKey.matteHeight] as? NSNumber)?.intValue ?? 0

        guard frameCount >= 0, inferenceResolution > 0, matteWidth > 0, matteHeight > 0 else {
            return nil
        }

        var mattes: [Int: Data] = [:]
        if let framesDictionary = dictionary[AnalysisDataKey.mattes] as? NSDictionary {
            mattes.reserveCapacity(framesDictionary.count)
            for (key, value) in framesDictionary {
                guard let keyString = key as? String, let index = Int(keyString) else { continue }
                if let data = value as? Data {
                    mattes[index] = data
                } else if let nsData = value as? NSData {
                    mattes[index] = Data(referencing: nsData)
                }
            }
        }

        return AnalysisData(
            schemaVersion: schemaVersion,
            frameDuration: frameDuration,
            firstFrameTime: firstFrameTime,
            frameCount: frameCount,
            analyzedCount: analyzedCount,
            screenColorRaw: screenColorRaw,
            qualityModeRaw: qualityModeRaw,
            inferenceResolution: inferenceResolution,
            matteWidth: matteWidth,
            matteHeight: matteHeight,
            mattes: mattes,
            hintConfiguration: (dictionary[AnalysisDataKey.hintConfiguration] as? Data).flatMap {
                try? PropertyListDecoder().decode(AnalysisHintConfiguration.self, from: $0)
            }
        )
    }
}

/// Per-frame matte payload lifted from an `AnalysisData` snapshot.
struct CachedAnalysisMatte: Sendable {
    let blob: Data
    let inferenceResolution: Int
}

/// The hint inputs captured at analysis start, shared by both hosts.
struct AnalysisHintConfiguration: Equatable, Sendable, Codable {
    let mode: HintMode
    let points: HintPointSet
}
