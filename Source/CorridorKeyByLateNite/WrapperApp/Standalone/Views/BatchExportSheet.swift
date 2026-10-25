import SwiftUI
import UniformTypeIdentifiers

/// Multi-shot queue with shared codec/settings, per-shot progress, and retry.
struct BatchExportSheet: View {
    @Bindable var model: BatchExportModel
    let state: PluginStateData
    @Environment(\.dismiss) private var dismiss
    @State private var isImporting = false
    @State private var isChoosingFolder = false

    var body: some View {
        VStack(alignment: .leading) {
            Text("Batch Export").font(.title2).bold()
            Text("Each video is analysed and exported using the current keying settings. Shot-specific points and Alpha Hint files are excluded; Manual Points uses Chroma. Existing files are kept.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List {
                ForEach(model.items) { item in
                    HStack {
                        BatchExportRow(item: item)
                        Spacer()
                        if !model.isRunning {
                            Button("Remove Shot", systemImage: "minus.circle") { model.remove(item.id) }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }
            .overlay {
                if model.items.isEmpty {
                    ContentUnavailableView("Add Videos", systemImage: "film.stack",
                                           description: Text("Drop videos here or choose Add Videos."))
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard !model.isRunning else { return false }
                model.add(urls)
                return !urls.isEmpty
            }
            HStack {
                Button("Add Videos…", systemImage: "plus") { isImporting = true }
                Picker("Codec", selection: $model.codec) {
                    ForEach(ExportOptions.ExportCodec.allCases) { codec in
                        Text(codec.displayName).tag(codec)
                    }
                }
            }
            .disabled(model.isRunning)
            Toggle("Preserve Alpha Channel", isOn: $model.preserveAlpha)
                .disabled(model.isRunning || !model.codec.supportsAlpha)
            HStack {
                Button("Choose Folder…", systemImage: "folder") { isChoosingFolder = true }
                    .disabled(model.isRunning)
                Text(model.destination?.path ?? "Choose an export folder")
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Divider()
            HStack {
                Text("\(model.items.count) shots · \(model.pendingCount) remaining")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                if model.isRunning {
                    Button("Stop Batch", systemImage: "stop.fill") { model.cancel() }
                } else {
                    Button("Done", role: .cancel) { dismiss() }
                    Button("Export \(model.pendingCount) Shots", systemImage: "square.and.arrow.up") { model.start(state: state) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.destination == nil || model.pendingCount == 0)
                }
            }
        }
        .padding()
        .frame(minWidth: 560, idealWidth: 640, minHeight: 480)
        .interactiveDismissDisabled(model.isRunning)
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.movie, .video], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): model.add(urls)
            case .failure(let error): model.importError = error.localizedDescription
            }
        }
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): model.selectDestination(url)
            case .failure(let error): model.importError = error.localizedDescription
            }
        }
        .alert("Couldn't Add Media", isPresented: Binding(
            get: { model.importError != nil }, set: { if !$0 { model.importError = nil } }
        )) {
            Button("OK", role: .cancel) { model.importError = nil }
        } message: { Text(model.importError ?? "") }
    }
}

/// Status is expressed as text as well as a progress bar for VoiceOver.
private struct BatchExportRow: View {
    let item: BatchExportItem

    var body: some View {
        VStack(alignment: .leading) {
            Text(item.source.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
            switch item.status {
            case .waiting: Text("Waiting").foregroundStyle(.secondary)
            case .preparing(let completed, let total):
                ProgressView("Preparing Time Awareness · \(completed) of \(total) frames", value: Double(completed), total: Double(max(1, total)))
            case .analysing(let completed, let total):
                ProgressView("Analysing · \(completed) of \(total) frames", value: Double(completed), total: Double(max(1, total)))
            case .exporting(let completed, let total):
                ProgressView("Exporting · \(completed) of \(total) frames", value: Double(completed), total: Double(max(1, total)))
            case .completed(let url):
                Label("Exported · \(url.lastPathComponent)", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
                ShareLink(item: url) { Label("Share Export", systemImage: "square.and.arrow.up") }
            case .failed(let message): Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            case .cancelled: Text("Cancelled · ready to retry").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.vertical)
    }
}
