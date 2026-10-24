//
//  ExportSheet.swift
//  CorridorKey by LateNite — Standalone Editor
//
//  Modal sheet that gathers ProRes / HEVC export options, runs the
//  export through `EditorViewModel.runExport`, and surfaces progress
//  + result so the user knows when their file is ready.
//

import SwiftUI
import AppKit

struct ExportSheet: View {
    @Bindable var viewModel: EditorViewModel
    let dismiss: () -> Void

    @State private var codec: ExportOptions.ExportCodec = .proRes4444
    @State private var preserveAlpha: Bool = true
    @State private var destinationURL: URL?
    @State private var imageFormat: StillImageExportFormat = .png

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(viewModel.isStillImage ? "Export Keyed Image" : "Export Keyed Clip")
                .font(.title2)
                .bold()

            Text(viewModel.isStillImage
                 ? "Saves the current output at the image’s original resolution. PNG and TIFF preserve transparency with 16-bit colour. The preview backdrop is not included."
                 : "Renders the current parameters across every analysed frame and writes the result to a QuickTime movie. Apple ProRes carries the highest quality; HEVC keeps file sizes compact and is hardware-encoded on Apple Silicon. Choose a codec with alpha (ProRes 4444 or HEVC with Alpha) to embed the matte directly into the output file.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                if viewModel.isStillImage {
                    Picker("Format", selection: $imageFormat) {
                        ForEach(StillImageExportFormat.allCases) { format in
                            Text(format.displayName).tag(format)
                        }
                    }
                    .onChange(of: imageFormat) { _, _ in
                        // A new format needs a matching user-approved destination.
                        destinationURL = nil
                    }
                } else {
                    EnumPicker(
                        title: "Codec",
                        selection: $codec,
                        defaultValue: .proRes4444,
                        onChange: {}
                    )

                    Toggle("Preserve Alpha Channel", isOn: $preserveAlpha)
                        .disabled(!codec.supportsAlpha)
                }
            }
            .disabled(viewModel.exportStatus.inProgress)

            HStack(spacing: 8) {
                Button("Choose Destination…", systemImage: "folder", action: chooseDestination)
                    .buttonStyle(.bordered)
                    .disabled(viewModel.exportStatus.inProgress)
                Spacer()
                Text(destinationLabel)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }

            Divider()

            ExportProgressLabel(status: viewModel.exportStatus, totalFrames: viewModel.totalFrames)

            HStack {
                if case .completed(let url) = viewModel.exportStatus {
                    Button("Reveal in Finder", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    .buttonStyle(.bordered)
                }
                Spacer()
                Button("Cancel", role: .cancel) {
                    if viewModel.exportStatus.inProgress {
                        viewModel.cancelExport()
                    }
                    dismiss()
                }
                Button("Export", systemImage: "square.and.arrow.up", action: startExport)
                    .buttonStyle(.borderedProminent)
                    .disabled(destinationURL == nil || viewModel.exportStatus.inProgress)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private var destinationLabel: String {
        guard let destinationURL else { return "No file chosen yet" }
        return destinationURL.path
    }

    private func chooseDestination() {
        let panel = NSSavePanel()
        panel.title = "Export As"
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = viewModel.isStillImage ? [imageFormat.contentType] : [.quickTimeMovie]
        let filenameExtension = viewModel.isStillImage ? imageFormat.filenameExtension : "mov"
        panel.nameFieldStringValue = (viewModel.clipInfo?.url.deletingPathExtension().lastPathComponent ?? "Untitled")
            + " (Keyed)." + filenameExtension
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }
        destinationURL = url
    }

    private func startExport() {
        guard let destinationURL else { return }
        if viewModel.isStillImage {
            viewModel.runExport(options: StillImageExportOptions(destination: destinationURL, format: imageFormat))
            return
        }
        let options = ExportOptions(
            destination: destinationURL,
            codec: codec,
            preserveAlpha: preserveAlpha
        )
        viewModel.runExport(options: options)
    }
}

extension ExportOptions.ExportCodec: DisplayNamed {}

private struct ExportProgressLabel: View {
    let status: EditorExportStatus
    let totalFrames: Int

    var body: some View {
        switch status {
        case .idle:
            Text("Press Export to start writing the file.")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .running(let processed, let total):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: Double(processed), total: Double(max(total, 1)))
                Text("Encoded \(processed) of \(total) frames")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .completed(let url):
            // Filename gets its own line so long names don't push
            // the success badge out of view. The "Reveal in
            // Finder" affordance now lives in the bottom button
            // row so it lines up with Cancel/Export — leaving
            // this panel as a pure status read-out.
            VStack(alignment: .leading, spacing: 4) {
                Label("Export complete", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(url.lastPathComponent)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .failed(let message):
            Label("Export failed: \(message)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        case .cancelled:
            Label("Export cancelled.", systemImage: "stop.circle.fill")
                .foregroundStyle(.orange)
        }
    }
}
