import SwiftUI
import UniformTypeIdentifiers

/// The same sandboxed file-selection control is presented in both hosts.
struct AlphaHintPicker: View {
    @Binding var asset: AlphaHintAsset?
    var onChange: () -> Void
    var setCurrentReference: () -> Void
    @State private var choosingFile = false
    @State private var errorMessage: String?

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
                Text(asset.name).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Button("Set Current Frame as Reference", systemImage: "scope", action: setCurrentReference)
                .controlSize(.small)
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
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
