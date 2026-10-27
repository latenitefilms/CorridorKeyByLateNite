//
//  CorridorKeyToolboxPlugIn+CustomViews.swift
//  CorridorKey by LateNite
//
//  Hands Final Cut Pro the SwiftUI-backed branding, Controls, Analysis Details
//  Alpha Hint and Manual Hint rows. FxPlug takes ownership of the returned NSView via
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

    /// The SwiftUI root measures its natural height at the host's actual width.
    var onWidthChange: ((CGFloat) -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        let previousWidth = frame.width
        super.setFrameSize(newSize)
        if newSize.width > 0, abs(previousWidth - newSize.width) > 0.5 {
            onWidthChange?(newSize.width)
        }
    }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        updateContentHeight(intrinsicContentSize.height)
    }

    /// Reports content changes through AppKit layout, without a delayed task or
    /// run-loop hop. FxPlug receives the same height in the frame and intrinsic size.
    func updateContentHeight(_ measuredHeight: CGFloat) {
        guard measuredHeight.isFinite, measuredHeight > 0 else { return }
        // Auto Layout hosts consume the intrinsic size themselves. Changing their
        // frame here would fight their constraints; manual FxPlug rows need it set.
        guard translatesAutoresizingMaskIntoConstraints else { return }
        // Preserve subpixel sizing. Rounding up fights the parent's Auto Layout
        // result on Retina displays and can repeatedly invalidate layout.
        guard abs(measuredHeight - frame.height) > 0.5 else { return }
        setFrameSize(NSSize(width: frame.width, height: measuredHeight))
        superview?.needsLayout = true
    }

    override var acceptsFirstResponder: Bool { false }
    override func becomeFirstResponder() -> Bool { false }
}

extension CorridorKeyToolboxPlugIn {

    @objc(createViewForParameterID:)
    func createViewForParameter(_ parameterID: UInt32) -> NSView? {
        guard [ParameterIdentifier.headerSummary, ParameterIdentifier.analysisControls,
               ParameterIdentifier.analysisDetails,
               ParameterIdentifier.alphaHintControls, ParameterIdentifier.manualHintControls].contains(parameterID) else {
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
            // Measure at a known width before returning the view. Subsequent
            // host resizes and status changes update the measured content height.
            view.sizingOptions = [.intrinsicContentSize]
            view.frame = NSRect(x: 0, y: 0, width: row.availableWidth, height: 1)
            view.autoresizingMask = [.width]
            view.onWidthChange = { [weak view] width in
                view?.rootView.availableWidth = width
            }
            view.updateContentHeight(view.fittingSize.height)
            return view
        }

        return Unmanaged.passRetained(hostingView).takeUnretainedValue()
    }
}

/// The root has no fixed vertical extent or nested vertical scroll view.
/// Text, errors and filenames contribute exactly the height they need.
@MainActor
private struct CorridorKeyInspectorRow: View {
    @State var bridge: CorridorKeyInspectorBridge
    let parameterID: UInt32
    var availableWidth: CGFloat = 320

    var body: some View {
        Group {
            switch parameterID {
            case ParameterIdentifier.headerSummary:
                CorridorKeyBrandingView()
            case ParameterIdentifier.analysisControls:
                CorridorKeyControlsView(bridge: bridge)
            case ParameterIdentifier.analysisDetails:
                CorridorKeyAnalysisDetailsView(bridge: bridge)
            case ParameterIdentifier.alphaHintControls:
                CorridorKeyAlphaHintView(bridge: bridge)
            default:
                CorridorKeyManualHintView(bridge: bridge)
            }
        }
        .padding(.horizontal)
        // The native section heading already provides the space above Subject.
        .padding(.top, parameterID == ParameterIdentifier.manualHintControls ? 0 : 4)
        .padding(.bottom, 4)
        .frame(width: availableWidth, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .task(id: ObjectIdentifier(bridge)) {
            // The static branding row needs no host polling.
            if parameterID != ParameterIdentifier.headerSummary {
                await bridge.observeSnapshots()
            }
        }
    }
}
