//
//  AnalysisSnapshotTests.swift
//  CorridorKeyToolboxLogicTests
//
//  Invariants for the value-type snapshot the SwiftUI inspector header
//  displays. SwiftUI is exercised via FxPlug's NSHostingView at runtime and
//  isn't reachable from the Swift Package, so we cover the state surface
//  the header reads from here.
//

import Testing
@testable import CorridorKeyToolboxLogic

@Suite("CorridorKeyAnalysisSnapshot")
struct CorridorKeyAnalysisSnapshotTests {

    @Test("Empty snapshot reports no progress and not working")
    func emptySnapshot() {
        let snapshot = CorridorKeyAnalysisSnapshot.empty
        #expect(snapshot.state == .notAnalysed)
        #expect(snapshot.progress == 0)
        #expect(snapshot.isWorking == false)
        #expect(snapshot.remainingTimeDescription == "—")
        #expect(snapshot.sourceResolutionDescription == "—")
        #expect(snapshot.neuralModelDescription == "Not Loaded")
    }

    @Test("Unavailable or invalid ETA never displays a misleading duration",
          arguments: [Double.nan, .infinity, -.infinity, -1])
    func invalidRemainingTime(seconds: Double) {
        let snapshot = CorridorKeyAnalysisSnapshot(
            state: .running, analyzedFrameCount: 1, totalFrameCount: 10,
            inferenceResolution: 512, analysisETASeconds: seconds)
        #expect(snapshot.remainingTimeDescription == "—")
    }

    @Test("Completed analysis does not retain an old ETA and preserves source diagnostics")
    func completedDiagnostics() {
        let snapshot = CorridorKeyAnalysisSnapshot(
            state: .completed, analyzedFrameCount: 10, totalFrameCount: 10,
            inferenceResolution: 1024, warmup: .failed("Model could not load."),
            analysisETASeconds: 125, sourceWidth: 3840, sourceHeight: 2160)
        #expect(snapshot.remainingTimeDescription == "—")
        #expect(snapshot.sourceResolutionDescription == "3840 × 2160")
        #expect(snapshot.neuralModelDescription == "Failed: Model could not load.")
    }

    @Test("Progress is analysed / total")
    func progressFraction() {
        let snapshot = CorridorKeyAnalysisSnapshot(
            state: .running,
            analyzedFrameCount: 150,
            totalFrameCount: 300,
            inferenceResolution: 1024
        )
        #expect(abs(snapshot.progress - 0.5) < 1e-9)
    }

    @Test("Progress never exceeds 1 even when analysed overshoots total")
    func progressIsClamped() {
        let snapshot = CorridorKeyAnalysisSnapshot(
            state: .completed,
            analyzedFrameCount: 350,
            totalFrameCount: 300,
            inferenceResolution: 1024
        )
        #expect(snapshot.progress == 1.0)
    }

    @Test("Progress defaults to zero when total is missing")
    func progressFallsBackToZeroWithoutTotal() {
        let snapshot = CorridorKeyAnalysisSnapshot(
            state: .requested,
            analyzedFrameCount: 0,
            totalFrameCount: 0,
            inferenceResolution: 1024
        )
        #expect(snapshot.progress == 0)
    }

    @Test("isWorking covers only requested and running",
          arguments: [
            (CorridorKeyAnalysisSnapshot.State.notAnalysed, false),
            (.requested, true),
            (.running, true),
            (.completed, false),
            (.interrupted, false)
          ])
    func isWorkingMatchesState(state: CorridorKeyAnalysisSnapshot.State, expected: Bool) {
        let snapshot = CorridorKeyAnalysisSnapshot(
            state: state,
            analyzedFrameCount: 0,
            totalFrameCount: 0,
            inferenceResolution: 1024
        )
        #expect(snapshot.isWorking == expected)
    }
}
