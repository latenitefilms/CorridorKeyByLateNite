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

    /// Shared wording for the standalone and FxPlug inspectors.
    static let explanation = "Import a black-and-white mask: white keeps the subject and black removes the background. Use Alpha Hint enables this file in place of Generated Hint and manual points."

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Button("Alpha Hint…", systemImage: "photo.on.rectangle") { choosingFile = true }
                if asset != nil {
                    Button("Remove Alpha Hint", systemImage: "xmark.circle") {
                        asset = nil
                        onChange()
                    }
                    .labelStyle(.iconOnly)
                }
            }
            if let asset {
                Text(asset.name).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Set Current Frame as Reference", systemImage: "scope", action: setCurrentReference)
                .controlSize(.small)
                .fixedSize(horizontal: false, vertical: true)
            Button("About Alpha Hint", systemImage: "questionmark.circle") { showingHelp = true }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .popover(isPresented: $showingHelp) {
                    ScrollView {
                        VStack(alignment: .leading) {
                            Text("Alpha Hint").font(.headline)
                            Text(Self.explanation)
                            Text("Reference Frame is zero-based. Single Frame propagates forwards and backwards using Time Awareness.")
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .padding()
                    }
                    .frame(width: 320, height: 240)
                }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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
