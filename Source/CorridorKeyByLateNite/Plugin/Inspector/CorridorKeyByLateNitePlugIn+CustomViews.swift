//
//  CorridorKeyToolboxPlugIn+CustomViews.swift
//  CorridorKey by LateNite
//
//  Hands Final Cut Pro the SwiftUI-backed inspector header for the header
//  custom-UI parameter. FxPlug takes ownership of the returned NSView via
//  `Unmanaged.passRetained` so we don't autorelease it out from under the
//  host.
//

import AppKit
import Foundation
import SwiftUI

/// NSHostingView subclass with two jobs: stop the header from stealing
/// first-responder when users click into the inspector, and own a strong
/// reference to the `CorridorKeyInspectorBridge` so the SwiftUI `@Observable`
/// subscription can't outlive its publisher if Final Cut Pro retains the
/// view longer than we expect.
@MainActor
private final class CorridorKeyHostingView<Content: View>: NSHostingView<Content>, @unchecked Sendable {
    /// Held so the bridge's lifetime is pinned to the hosting view FxPlug
    /// retains — without this, SwiftUI's view struct was the only thing
    /// keeping the bridge alive, and intermittent re-renders could drop it
    /// and leave the header blank.
    var retainedBridge: CorridorKeyInspectorBridge?

    override var acceptsFirstResponder: Bool { false }
    override func becomeFirstResponder() -> Bool { false }
}

extension CorridorKeyToolboxPlugIn {

    @objc(createViewForParameterID:)
    func createViewForParameter(_ parameterID: UInt32) -> NSView? {
        guard parameterID == ParameterIdentifier.headerSummary || parameterID == ParameterIdentifier.alphaHintControls else {
            return nil
        }

        nonisolated(unsafe) let apiManagerRef = apiManager
        nonisolated(unsafe) let pluginRef = self

        let hostingView: CorridorKeyHostingView<CorridorKeyInspectorRow> = MainActor.assumeIsolated {
            let bridge = pluginRef.inspectorBridge ?? CorridorKeyInspectorBridge(apiManager: apiManagerRef, plugin: pluginRef)
            pluginRef.inspectorBridge = bridge
            let row = CorridorKeyInspectorRow(bridge: bridge, parameterID: parameterID)
            let view = CorridorKeyHostingView(rootView: row)
            view.retainedBridge = bridge
            // FxPlug reserves the returned frame height. Do not measure an
            // unconstrained SwiftUI fittingSize: it lays prose on a single line.
            view.sizingOptions = []
            view.frame = NSRect(x: 0, y: 0, width: 320, height: row.height)
            view.autoresizingMask = [.width]
            return view
        }

        return Unmanaged.passRetained(hostingView).takeUnretainedValue()
    }
}

/// Fixed host bounds with a scrolling fallback for accessibility text sizes,
/// long filenames and errors. Normal content fits without scrolling.
@MainActor
private struct CorridorKeyInspectorRow: View {
    @State var bridge: CorridorKeyInspectorBridge
    let parameterID: UInt32

    var height: CGFloat { parameterID == ParameterIdentifier.headerSummary ? 210 : 150 }

    var body: some View {
        ScrollView {
            Group {
                if parameterID == ParameterIdentifier.headerSummary {
                    CorridorKeyHeaderView(bridge: bridge)
                } else {
                    CorridorKeyAlphaHintView(bridge: bridge)
                }
            }
            .padding()
        }
        .frame(height: height, alignment: .top)
        .task(id: ObjectIdentifier(bridge)) { await bridge.observeSnapshots() }
    }
}
