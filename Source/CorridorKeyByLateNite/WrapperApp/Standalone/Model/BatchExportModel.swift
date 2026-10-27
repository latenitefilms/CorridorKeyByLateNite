import Foundation
import Observation
import UniformTypeIdentifiers

/// One queue row retains sandbox access until it is removed from the queue.
struct BatchExportItem: Identifiable {
    let id = UUID()
    let source: BatchSourceAccess
    var status: BatchExportStatus = .waiting
}

/// Owns a reviewable batch queue and freezes its keying settings at Start.
@MainActor
@Observable
final class BatchExportModel {
    private(set) var items: [BatchExportItem] = []
    private(set) var isRunning = false
    var destination: URL?
    var codec: ExportOptions.ExportCodec = .proRes4444
    var preserveAlpha = true
    var importError: String?
    @ObservationIgnored private let runner: BatchExportRunner
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var destinationAccess: BatchSourceAccess?

    init(engine: StandaloneRenderEngine) { runner = BatchExportRunner(engine: engine) }

    /// Drops and multi-selection share validation, deduplication, and permissions.
    func add(_ urls: [URL]) {
        guard !isRunning else { return }
        var unsupported: [String] = []
        for url in urls {
            let access = BatchSourceAccess(url: url)
            let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
                ?? UTType(filenameExtension: url.pathExtension)
            guard type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true else {
                unsupported.append(url.lastPathComponent)
                continue
            }
            guard !items.contains(where: { $0.source.url.standardizedFileURL == url.standardizedFileURL }) else { continue }
            items.append(BatchExportItem(source: access))
        }
        if !unsupported.isEmpty { importError = "Batch Export accepts videos. Skipped: " + unsupported.joined(separator: ", ") }
    }

    func remove(_ id: UUID) {
        guard !isRunning else { return }
        items.removeAll { $0.id == id }
    }

    func selectDestination(_ url: URL) {
        guard !isRunning else { return }
        destinationAccess = BatchSourceAccess(url: url)
        destination = url
    }

    var pendingCount: Int {
        items.filter { if case .completed = $0.status { false } else { true } }.count
    }

    /// Completed shots stay completed. Start retries only failed, cancelled, or new shots.
    func start(state: PluginStateData) {
        guard !isRunning, let destination, pendingCount > 0 else { return }
        let pending = items.filter { if case .completed = $0.status { false } else { true } }
        let outputs = BatchExportNaming.destinations(for: pending.map(\.source.url), in: destination)
        let jobs = zip(pending, outputs).map { BatchExportJob(id: $0.0.id, source: $0.0.source, destination: $0.1) }
        for index in items.indices where pending.contains(where: { $0.id == items[index].id }) {
            items[index].status = .waiting
        }
        isRunning = true
        let settings = BatchExportNaming.sharedSettings(from: state)
        let runner = runner
        let codec = codec
        let preserveAlpha = preserveAlpha
        let access = destinationAccess
        task = Task { [weak self] in
            let (events, continuation) = AsyncStream<(UUID, BatchExportStatus)>.makeStream()
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await runner.run(jobs: jobs, state: settings, codec: codec, preserveAlpha: preserveAlpha) {
                        continuation.yield(($0, $1))
                    }
                    continuation.finish()
                }
                for await (id, status) in events {
                    guard let self, let index = self.items.firstIndex(where: { $0.id == id }) else { continue }
                    self.items[index].status = status
                }
            }
            withExtendedLifetime(access) {}
            guard let self else { return }
            if Task.isCancelled {
                for index in self.items.indices {
                    switch self.items[index].status {
                    case .waiting, .preparing, .analysing, .exporting: self.items[index].status = .cancelled
                    default: break
                    }
                }
            }
            self.isRunning = false
            self.task = nil
        }
    }

    /// Cancels cooperatively and returns the task so app termination can drain it.
    @discardableResult
    func cancel() -> Task<Void, Never>? {
        task?.cancel()
        return task
    }
}
