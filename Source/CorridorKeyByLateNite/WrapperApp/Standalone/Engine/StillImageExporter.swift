//
//  StillImageExporter.swift
//  CorridorKey by LateNite — Standalone Editor
//

import Foundation

#if CORRIDOR_KEY_HEADLESS_TESTS
@testable import CorridorKeyToolboxLogic
#endif
import CoreImage
import UniformTypeIdentifiers

/// Lossless image formats that retain the keyed alpha channel at 16 bits per channel.
enum StillImageExportFormat: String, Sendable, CaseIterable, Identifiable {
    case png
    case tiff

    var id: Self { self }
    var displayName: String { rawValue.uppercased() }
    var contentType: UTType { self == .png ? .png : .tiff }
    var filenameExtension: String { rawValue }
}

/// Destination and format chosen in the still-image export sheet.
struct StillImageExportOptions: Sendable {
    let destination: URL
    let format: StillImageExportFormat
}

/// Renders a single image through the same cached-matte pipeline as movie export.
actor StillImageExporter {
    private let renderEngine: StandaloneRenderEngine
    private let source: any EditorMediaSource
    private let project: ExportProjectSnapshot

    init(renderEngine: StandaloneRenderEngine, source: any EditorMediaSource, project: ExportProjectSnapshot) {
        self.renderEngine = renderEngine
        self.source = source
        self.project = project
    }

    /// Encodes before touching the destination, then commits atomically. A failed
    /// or cancelled render cannot delete an existing user file.
    func run(options: StillImageExportOptions, eventHandler: @Sendable (ExportRunnerEvent) -> Void) async {
        let didStartAccessing = options.destination.startAccessingSecurityScopedResource()
        defer { if didStartAccessing { options.destination.stopAccessingSecurityScopedResource() } }
        eventHandler(.started(totalFrames: 1))
        do {
            try Task.checkCancellation()
            let frame = try await source.makeFrame(atTime: .zero)
            var state = project.renderState(forFrameIndex: 0, renderSize: source.info.renderSize)
            // PNG/TIFF encode alpha with their own association convention.
            // Feed Core Image premultiplied pixels for both foreground modes
            // so partially transparent edges retain their original colour.
            if state.outputMode == .foregroundPlusMatte { state.outputMode = .processed }
            let result = try renderEngine.render(source: frame, state: state, renderTime: .zero)
            try Task.checkCancellation()
            guard let workingColorSpace = CGColorSpace(name: CGColorSpace.extendedSRGB),
                  let outputColorSpace = source.info.imageColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let image = CIImage(cvPixelBuffer: result.destinationPixelBuffer, options: [.colorSpace: workingColorSpace])
            let context = CIContext(mtlDevice: renderEngine.device)
            let data: Data?
            switch options.format {
            case .png:
                data = context.pngRepresentation(of: image, format: .RGBA16, colorSpace: outputColorSpace)
            case .tiff:
                data = context.tiffRepresentation(of: image, format: .RGBA16, colorSpace: outputColorSpace)
            }
            guard let data else { throw CocoaError(.fileWriteUnknown) }
            try Task.checkCancellation()
            try data.write(to: options.destination, options: .atomic)
            eventHandler(.frameWritten(frameIndex: 0))
            eventHandler(.completed(options.destination))
        } catch is CancellationError {
            eventHandler(.cancelled)
        } catch {
            eventHandler(.failed(error.localizedDescription))
        }
    }
}
