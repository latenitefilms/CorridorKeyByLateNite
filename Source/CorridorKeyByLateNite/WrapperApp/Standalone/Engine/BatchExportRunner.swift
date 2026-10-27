import Foundation

/// Keeps file-picker or drag-and-drop sandbox access alive while a shot waits.
final class BatchSourceAccess: @unchecked Sendable {
    let url: URL
    private let hasAccess: Bool

    init(url: URL) {
        self.url = url
        hasAccess = url.startAccessingSecurityScopedResource()
    }

    deinit { if hasAccess { url.stopAccessingSecurityScopedResource() } }
}

/// A frozen source and destination for one sequential batch job.
struct BatchExportJob: Sendable {
    let id: UUID
    let source: BatchSourceAccess
    let destination: URL
}

/// Queue state shared by the runner, model, and accessible progress rows.
enum BatchExportStatus: Equatable, Sendable {
    case waiting
    case preparing(completed: Int, total: Int)
    case analysing(completed: Int, total: Int)
    case exporting(completed: Int, total: Int)
    case completed(URL)
    case failed(String)
    case cancelled
}

/// Allocates unique output names without replacing an input or existing output.
enum BatchExportNaming {
    static func destinations(for sources: [URL], in directory: URL) -> [URL] {
        var reserved = Set<String>()
        return sources.map { source in
            let stem = source.deletingPathExtension().lastPathComponent + " (Keyed)"
            var suffix = 1
            var candidate: URL
            repeat {
                let name = suffix == 1 ? stem : "\(stem) \(suffix)"
                candidate = directory.appending(path: name + ".mov")
                suffix += 1
            } while reserved.contains(candidate.lastPathComponent.lowercased())
                || FileManager.default.fileExists(atPath: candidate.path)
                || sources.contains(where: { $0.standardizedFileURL == candidate.standardizedFileURL })
            reserved.insert(candidate.lastPathComponent.lowercased())
            return candidate
        }
    }

    /// Shot-specific masks and cached frames cannot be applied to unrelated media.
    static func sharedSettings(from state: PluginStateData) -> PluginStateData {
        var settings = state
        settings.hintPointSet.clear()
        if settings.hintMode == .manual { settings.hintMode = .appleVision }
        settings.video.useAlphaHint = false
        settings.video.alphaHintAsset = nil
        settings.video.referenceFrame = 0
        settings.cachedFrameReference = nil
        settings.cachedMatteBlob = nil
        settings.cachedMatteInferenceResolution = 0
        settings.sourceFrameIndex = 0
        return settings
    }
}

private struct BatchExportFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Runs one shot at a time, releasing its decoder and analysis references before
/// moving on. The same analysis and export engines drive individual exports.
actor BatchExportRunner {
    private let engine: StandaloneRenderEngine

    init(engine: StandaloneRenderEngine) { self.engine = engine }

    /// A failed shot is reported individually; remaining queued shots continue.
    func run(jobs: [BatchExportJob], state: PluginStateData, codec: ExportOptions.ExportCodec,
             preserveAlpha: Bool, eventHandler: @Sendable (UUID, BatchExportStatus) -> Void) async {
        for job in jobs {
            guard !Task.isCancelled else {
                eventHandler(job.id, .cancelled)
                continue
            }
            do {
                let source = try await VideoSource(url: job.source.url)
                let cache: [Int: MatteCacheEntry]
                if state.outputMode == .original || state.outputMode == .hint {
                    cache = [:]
                } else {
                    eventHandler(job.id, .analysing(completed: 0, total: source.totalFrameCount()))
                    cache = try await analyse(source: source, state: state) { status in
                        eventHandler(job.id, status)
                    }
                }
                try Task.checkCancellation()
                let snapshot = ExportProjectSnapshot(state: state, cachedMattes: cache)
                let exporter = ProResExporter(renderEngine: engine, videoSource: source, project: snapshot)
                let options = ExportOptions(destination: job.destination, codec: codec,
                                            preserveAlpha: preserveAlpha, overwriteExisting: false)
                try await export(exporter: exporter, options: options) { completed, total in
                    eventHandler(job.id, .exporting(completed: completed, total: total))
                }
                eventHandler(job.id, .completed(job.destination))
            } catch is CancellationError {
                eventHandler(job.id, .cancelled)
            } catch {
                eventHandler(job.id, .failed(error.localizedDescription))
            }
        }
    }

    private func analyse(source: VideoSource, state: PluginStateData,
                         progress: @Sendable (BatchExportStatus) -> Void) async throws -> [Int: MatteCacheEntry] {
        let runner = AnalysisRunner(renderEngine: engine, videoSource: source)
        let (events, continuation) = AsyncStream<AnalysisRunnerEvent>.makeStream()
        return try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await runner.run(state: state) { continuation.yield($0) }
                continuation.finish()
            }
            defer { group.cancelAll(); continuation.finish() }
            var cache: [Int: MatteCacheEntry] = [:]
            var total = source.totalFrameCount()
            var completed = false
            for await event in events {
                try Task.checkCancellation()
                switch event {
                case .totalFramesResolved(let count): total = count
                case .framePrepared(let index): progress(.preparing(completed: index + 1, total: total))
                case .frameProcessed(let index, _, let entry):
                    cache[index] = entry
                    progress(.analysing(completed: cache.count, total: total))
                case .completed: completed = true
                case .failed(let message): throw BatchExportFailure(message: message)
                case .cancelled: throw CancellationError()
                }
            }
            try Task.checkCancellation()
            guard completed else { throw BatchExportFailure(message: "Analysis did not finish.") }
            return cache
        }
    }

    private func export(exporter: ProResExporter, options: ExportOptions,
                        progress: @Sendable (Int, Int) -> Void) async throws {
        let (events, continuation) = AsyncStream<ExportRunnerEvent>.makeStream()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await exporter.run(options: options) { continuation.yield($0) }
                continuation.finish()
            }
            defer { group.cancelAll(); continuation.finish() }
            var total = 1
            var completed = false
            for await event in events {
                try Task.checkCancellation()
                switch event {
                case .started(let count):
                    total = count
                    progress(0, total)
                case .frameWritten(let index): progress(index + 1, total)
                case .completed: completed = true
                case .failed(let message): throw BatchExportFailure(message: message)
                case .cancelled: throw CancellationError()
                }
            }
            try Task.checkCancellation()
            guard completed else { throw BatchExportFailure(message: "Export did not finish.") }
        }
    }
}
