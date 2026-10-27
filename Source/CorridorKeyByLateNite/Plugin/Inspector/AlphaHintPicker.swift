import SwiftUI
import UniformTypeIdentifiers

/// The same sandboxed file-selection control is presented in both hosts.
struct AlphaHintPicker: View {
    @Binding var asset: AlphaHintAsset?
    var onChange: () -> Void
    var setCurrentReference: () -> Void
    @State private var choosingFile = false
    @State private var errorMessage: String?
    @State private var showingHelp = false

    var body: some View {
        VStack(alignment: .leading) {
            InspectorButtonRow {
                Button("Import Alpha Hint", systemImage: "photo.on.rectangle") { choosingFile = true }
                Button("About Alpha Hint", systemImage: "questionmark.circle") { showingHelp = true }
                    .popover(isPresented: $showingHelp) {
                        AlphaHintHelpView()
                    }
            }
            if let asset {
                HStack {
                    Text(asset.name).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Remove Alpha Hint", systemImage: "xmark.circle") {
                        self.asset = nil
                        onChange()
                    }
                    .labelStyle(.iconOnly)
                    .help("Remove Alpha Hint")
                }
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Set Current Frame as Reference", systemImage: "scope", action: setCurrentReference)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .labelStyle(.titleAndIcon)
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.image, .movie, .folder]) { result in
            do {
                asset = try AlphaHintAsset(url: result.get())
                errorMessage = nil
                onChange()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Shared help uses distinct paragraphs and headings, sized to its content.
struct AlphaHintHelpView: View {
    var body: some View {
        InspectorHelpPopover(title: "Alpha Hint", systemImage: "photo.on.rectangle") {
            InspectorHelpSection(
                title: "Import a mask",
                message: "Import a black-and-white image, movie or image sequence. White keeps the subject. Black removes the background."
            )
            InspectorHelpSection(
                title: "Enable the hint",
                message: "Turn on Use Alpha Hint to use the imported mask in place of Generated Hint and manual points."
            )
            Divider()
            InspectorHelpSection(
                title: "Choose a reference frame",
                message: "Reference Frame counts from zero. Choose Set Current Frame as Reference to use the frame at the playhead. With Single Frame selected, Time Awareness propagates the hint forwards and backwards."
            )
        }
    }
}
