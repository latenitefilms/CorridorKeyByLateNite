// Foreground, background and ignore points on Final Cut Pro's viewer.
// The same per-frame hint data drives the standalone editor and FxPlug key.

import Foundation
import CoreMedia
import Metal

@objc(CorridorKeyHintOSC)
class CorridorKeyHintOSC: NSObject, FxOnScreenControl_v4 {

    private let apiManager: any PROAPIAccessing
    /// Tolerance for option-click erase + nearest-hint highlight,
    /// in object-normalised units. Matches the Standalone Editor.
    private static let eraseTolerance = HintHitTesting.pointRadius
    /// Visible marker radius in OSC pixels. The fragment shader
    /// measures marker geometry in pixel space so badges remain
    /// circular regardless of the Final Cut Pro viewer aspect ratio.
    private static let markerVisualRadiusPixels: Float32 = 22.5

    @objc(initWithAPIManager:)
    required init?(apiManager: any PROAPIAccessing) {
        self.apiManager = apiManager
        super.init()
        PluginLog.notice("CorridorKeyHintOSC instantiated by FCP — OSC is registered.")
    }

    // MARK: - FxOnScreenControl_v4

    /// FxPlug decodes parameters against the active session's plug-in instance.
    /// The OSC has its own session, so the effect's class declaration is insufficient.
    /// Without this selector, FxPlug falls back to an unimplemented selector and
    /// reports "Unable to unarchive data ... due to error: (null)" for valid archives.
    @objc(classesForCustomParameterID:)
    func classes(forCustomParameterID parameterID: UInt32) -> Set<AnyHashable> {
        parameterID == ParameterIdentifier.headerSummary ? CustomParameterValue.allowedClassSet : []
    }

    @objc func drawingCoordinates() -> FxDrawingCoordinates {
        // Canvas pixel coordinates because the OSC API returns mouse
        // positions in canvas space; we round-trip into object-
        // normalised space when reading / writing parameters.
        return FxDrawingCoordinates(kFxDrawingCoordinates_CANVAS)
    }

    @objc(drawOSCWithWidth:height:activePart:destinationImage:atTime:)
    func drawOSC(
        withWidth width: Int,
        height: Int,
        activePart: Int,
        destinationImage: FxImageTile,
        at time: CMTime
    ) {
        let hints = acceptsManualHintInput(at: time) ? currentHintState()?.hints.points(at: time) ?? [] : []
        let screen = currentScreenColor(at: time)

        // Convert normalized image points into the host canvas, including its
        // letterboxing and viewer zoom. Point IDs are their packed index plus one.
        let packed = hints.map { hint in
            let mapped = self.objectToCanvasUV(
                objectX: hint.x,
                objectY: hint.y,
                tileWidth: Double(destinationImage.tilePixelBounds.right - destinationImage.tilePixelBounds.left),
                tileHeight: Double(destinationImage.tilePixelBounds.top - destinationImage.tilePixelBounds.bottom)
            )
            return PackedPoint(
                x: Float(mapped.canvasU),
                y: Float(mapped.canvasV),
                radius: Self.markerVisualRadiusPixels,
                kind: Int32(hint.kind.rawValue)
            )
        }
        do {
            try renderMarkers(
                destinationImage: destinationImage,
                points: packed,
                activePart: activePart,
                screenColor: screen
            )
        } catch {
            PluginLog.error("OSC draw failed: \(error.localizedDescription)")
        }
    }

    /// Maps a marker's OBJECT-space position (0…1 in the source
    /// frame) to a canvas-uv suitable for the OSC fragment shader.
    /// Falls back to identity when the OSC API isn't available so
    /// the OSC stays drawable in degraded environments.
    private func objectToCanvasUV(
        objectX: Double,
        objectY: Double,
        tileWidth: Double,
        tileHeight: Double
    ) -> (canvasU: Double, canvasV: Double) {
        guard tileWidth > 0, tileHeight > 0,
              let oscAPI = apiManager.api(for: (any FxOnScreenControlAPI_v4).self) as? any FxOnScreenControlAPI_v4
        else {
            return (objectX, objectY)
        }
        var canvasX: Double = 0
        var canvasY: Double = 0
        oscAPI.convertPoint(
            fromSpace: FxDrawingCoordinates(kFxDrawingCoordinates_OBJECT),
            fromX: objectX,
            fromY: objectY,
            toSpace: FxDrawingCoordinates(kFxDrawingCoordinates_CANVAS),
            toX: &canvasX,
            toY: &canvasY
        )
        // Empirically, FxPlug's CANVAS/OBJECT spaces share the same
        // Y-down convention as Metal texture coordinates — even
        // though `FxOnScreenControl.h` documents Y-up. The proof is
        // the existing hint-point flow: clicks land at the user's
        // cursor position when stored as `(object.x, object.y)` and
        // drawn at `uv = (p.x, p.y)`, which is only consistent if
        // both axes count the same direction. Apple's FxShape
        // sample applies `destImageHeight - canvasY` for a separate
        // reason — it's converting CANVAS pixel coords to Metal
        // *NDC vertex* coords (which **are** Y-up post-viewport),
        // not to texture-coord uv. We're rendering with
        // texture-coord uv directly, so no additional Y flip is needed.
        let canvasU = canvasX / tileWidth
        let canvasV = canvasY / tileHeight
        return (canvasU, canvasV)
    }

    @objc(hitTestOSCAtMousePositionX:mousePositionY:activePart:atTime:)
    func hitTestOSC(
        atMousePositionX x: Double,
        mousePositionY y: Double,
        activePart: UnsafeMutablePointer<Int>,
        at time: CMTime
    ) {
        let object = objectPosition(forCanvasX: x, canvasY: y)

        let state = currentHintState()
        let allowsManualHints = acceptsManualHintInput(at: time) && (state?.tool ?? .disabled) != .disabled
        // Zero tells FxPlug that none of our controls was hit, so mouseDown
        // is never delivered. Empty image space needs its own nonzero target.
        activePart.pointee = HintHitTesting.target(
            at: SIMD2(object.x, object.y),
            hints: allowsManualHints ? state?.hints.points(at: time) ?? [] : [],
            allowsManualHints: allowsManualHints
        ).hostPartIdentifier
    }

    @objc(mouseDownAtPositionX:positionY:activePart:modifiers:forceUpdate:atTime:)
    func mouseDown(
        atPositionX x: Double,
        positionY y: Double,
        activePart: Int,
        modifiers: FxModifierKeys,
        forceUpdate: UnsafeMutablePointer<ObjCBool>,
        at time: CMTime
    ) {
        forceUpdate.pointee = ObjCBool(false)
        // Empty canvas (or over a hint with the option modifier) —
        // place / erase a hint point.
        let object = objectPosition(forCanvasX: x, canvasY: y)
        guard activePart != HintHitTarget.none.hostPartIdentifier,
              acceptsManualHintInput(at: time), HintHitTesting.contains(SIMD2(object.x, object.y)),
              let state = currentHintState(), state.tool != .disabled else { return }
        guard let timing = apiManager.api(for: (any FxTimingAPI_v4).self) as? any FxTimingAPI_v4 else { return }
        var duration = CMTime.invalid
        timing.frameDuration(&duration)
        guard let hintFrame = HintFrame(time: time, duration: duration) else { return }
        var hints = state.hints
        let action = state.tool.overriding(
            option: modifiers & FxModifierKeys(kFxModifierKey_OPTION) != 0,
            command: modifiers & FxModifierKeys(kFxModifierKey_COMMAND) != 0,
            shift: modifiers & FxModifierKeys(kFxModifierKey_SHIFT) != 0
        )
        switch action {
        case .disabled:
            return
        case .foregroundHint:
            hints.add(HintPoint(x: object.x, y: object.y, kind: .foreground, frame: hintFrame))
        case .ignoreHint:
            hints.add(HintPoint(x: object.x, y: object.y, kind: .ignore, frame: hintFrame))
        case .backgroundHint:
            hints.add(HintPoint(x: object.x, y: object.y, kind: .background, frame: hintFrame))
        case .eraseHint:
            let removed = hints.removeNearest(toX: object.x, y: object.y, tolerance: Self.eraseTolerance, at: time)
            if !removed {
                forceUpdate.pointee = ObjCBool(false)
                return
            }
        }
        guard writeHintSet(hints) else {
            PluginLog.error("Manual hint was not saved. Reset All or reapply the updated effect if parameter 50 cannot be read.")
            return
        }
        forceUpdate.pointee = ObjCBool(true)
    }

    @objc(mouseDraggedAtPositionX:positionY:activePart:modifiers:forceUpdate:atTime:)
    func mouseDragged(
        atPositionX x: Double,
        positionY y: Double,
        activePart: Int,
        modifiers: FxModifierKeys,
        forceUpdate: UnsafeMutablePointer<ObjCBool>,
        at time: CMTime
    ) {
        // Hints are click-to-place, matching the standalone Subject tools.
        forceUpdate.pointee = ObjCBool(false)
    }

    @objc(mouseUpAtPositionX:positionY:activePart:modifiers:forceUpdate:atTime:)
    func mouseUp(
        atPositionX x: Double,
        positionY y: Double,
        activePart: Int,
        modifiers: FxModifierKeys,
        forceUpdate: UnsafeMutablePointer<ObjCBool>,
        at time: CMTime
    ) {
        forceUpdate.pointee = ObjCBool(false)
    }

    @objc(keyDownAtPositionX:positionY:keyPressed:modifiers:forceUpdate:didHandle:atTime:)
    func keyDown(
        atPositionX x: Double,
        positionY y: Double,
        keyPressed asciiKey: UInt16,
        modifiers: FxModifierKeys,
        forceUpdate: UnsafeMutablePointer<ObjCBool>,
        didHandle: UnsafeMutablePointer<ObjCBool>,
        at time: CMTime
    ) {
        didHandle.pointee = ObjCBool(false)
        forceUpdate.pointee = ObjCBool(false)
    }

    @objc(keyUpAtPositionX:positionY:keyPressed:modifiers:forceUpdate:didHandle:atTime:)
    func keyUp(
        atPositionX x: Double,
        positionY y: Double,
        keyPressed asciiKey: UInt16,
        modifiers: FxModifierKeys,
        forceUpdate: UnsafeMutablePointer<ObjCBool>,
        didHandle: UnsafeMutablePointer<ObjCBool>,
        at time: CMTime
    ) {
        didHandle.pointee = ObjCBool(false)
        forceUpdate.pointee = ObjCBool(false)
    }

    // MARK: - Parameter I/O

    /// Selecting a Subject tool allows the first point even when Generated Hint is None.
    /// As in the standalone editor, adding that point selects manual mode.
    private func acceptsManualHintInput(at time: CMTime) -> Bool {
        guard let retrieval = apiManager.api(for: (any FxParameterRetrievalAPI_v6).self) as? any FxParameterRetrievalAPI_v6 else {
            return false
        }
        var externalHint = ObjCBool(false)
        return retrieval.getBoolValue(&externalHint, fromParameter: ParameterIdentifier.useAlphaHint, at: time)
            && !externalHint.boolValue
    }

    /// Reads the active Screen Colour parameter so the background-hint
    /// markers can be tinted with the same green / blue swatch the
    /// Standalone Editor's `HintPointMarker.backgroundMarker` uses —
    /// otherwise the FxPlug's marker visually disagrees with the
    /// Standalone Editor's icon styling and the user has to remember
    /// which colour means "drop this region" on each surface.
    private func currentScreenColor(at time: CMTime) -> ScreenColor {
        guard let retrieval = apiManager.api(for: (any FxParameterRetrievalAPI_v6).self) as? any FxParameterRetrievalAPI_v6 else {
            return .green
        }
        var raw: Int32 = Int32(ScreenColor.green.rawValue)
        retrieval.getIntValue(&raw, fromParameter: ParameterIdentifier.screenColor, at: time)
        return ScreenColor(rawValue: Int(raw)) ?? .green
    }

    /// One host read supplies both the selected tool and its frame annotations.
    private func currentHintState() -> (tool: OnScreenControlTool, hints: HintPointSet)? {
        guard let retrieval = apiManager.api(for: (any FxParameterRetrievalAPI_v6).self) as? any FxParameterRetrievalAPI_v6 else { return nil }
        let storage = HeaderCustomParameterStorage.storageDictionary(using: retrieval)
        guard storage.dictionary != nil else { return nil }
        let tool = OnScreenControlTool(parameterDictionary: HeaderCustomParameterStorage.dictionaryValue(
            for: HeaderStorageKey.subjectTool, using: retrieval, storage: storage
        ))
        let hints = HintPointSet.fromParameterDictionary(HeaderCustomParameterStorage.dictionaryValue(
            for: HeaderStorageKey.subjectPoints, using: retrieval, storage: storage
        ))
        return (tool, hints)
    }

    /// Host mouse callbacks already own the parameter-write action scope.
    /// Report success only when both the points and their generated-hint mode were saved.
    private func writeHintSet(_ hints: HintPointSet) -> Bool {
        guard let setting = apiManager.api(for: (any FxParameterSettingAPI_v5).self) as? any FxParameterSettingAPI_v5,
              HeaderCustomParameterStorage.setDictionary(
                hints.asParameterDictionary(), for: HeaderStorageKey.subjectPoints, using: apiManager
              ) else { return false }
        return hints.isEmpty || setting.setIntValue(
            Int32(HintMode.manual.rawValue), toParameter: ParameterIdentifier.hintMode, at: .zero
        )
    }

    // MARK: - Coordinate conversion

    /// Translates canvas pixel coordinates into object-normalised
    /// `(0…1)` so we can write source-relative hint points.
    private func objectPosition(forCanvasX x: Double, canvasY y: Double) -> (x: Double, y: Double) {
        guard let oscAPI = apiManager.api(for: (any FxOnScreenControlAPI_v4).self) as? any FxOnScreenControlAPI_v4 else {
            return (x, y)
        }
        var objectX: Double = 0
        var objectY: Double = 0
        oscAPI.convertPoint(
            fromSpace: FxDrawingCoordinates(kFxDrawingCoordinates_CANVAS),
            fromX: x,
            fromY: y,
            toSpace: FxDrawingCoordinates(kFxDrawingCoordinates_OBJECT),
            toX: &objectX,
            toY: &objectY
        )
        return (objectX, objectY)
    }

    // MARK: - Drawing

    /// One rendered hint. Kind is foreground, background or ignore, matching
    /// HintPointKind. Radius is measured in canvas pixels.
    private struct PackedPoint {
        var x: Float32
        var y: Float32
        var radius: Float32
        var kind: Int32
    }

    /// Renders every supplied marker via the shared
    /// `corridorKeyDrawOSCFragment` shader. Active-part tracking
    /// matches the array index so hover highlight follows whichever
    /// marker `hitTestOSC` reported. `screenColor` is forwarded to
    /// the shader so the background-hint swatch is drawn in the
    /// user's chosen screen colour.
    private func renderMarkers(
        destinationImage: FxImageTile,
        points: [PackedPoint],
        activePart: Int,
        screenColor: ScreenColor
    ) throws {

        let deviceCache = MetalDeviceCache.shared
        guard let device = deviceCache.device(forRegistryID: destinationImage.deviceRegistryID) else {
            throw MetalDeviceCacheError.unknownDevice(destinationImage.deviceRegistryID)
        }
        let entry = try deviceCache.entry(for: device)
        guard let commandQueue = entry.borrowCommandQueue() else {
            throw MetalDeviceCacheError.queueExhausted
        }
        defer { entry.returnCommandQueue(commandQueue) }
        guard let texture = destinationImage.metalTexture(for: device) else {
            throw MetalDeviceCacheError.unknownDevice(destinationImage.deviceRegistryID)
        }
        let renderPipelines = try entry.renderPipelines(for: texture.pixelFormat)
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw MetalDeviceCacheError.commandBufferCreationFailed
        }
        commandBuffer.label = "CorridorKey by LateNite OSC"

        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = texture
        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        passDescriptor.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            throw MetalDeviceCacheError.commandEncoderCreationFailed
        }
        encoder.label = "OSC Markers"
        // Clearing is still required after the last hint is removed or its mode
        // is disabled, otherwise the host can reuse stale overlay pixels.
        guard !points.isEmpty else {
            encoder.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilScheduled()
            return
        }

        let tileWidth = Float(destinationImage.tilePixelBounds.right - destinationImage.tilePixelBounds.left)
        let tileHeight = Float(destinationImage.tilePixelBounds.top - destinationImage.tilePixelBounds.bottom)
        let halfW = tileWidth * 0.5
        let halfH = tileHeight * 0.5
        var vertices: [CKVertex2D] = [
            CKVertex2D(position: SIMD2<Float>(halfW, -halfH), textureCoordinate: SIMD2<Float>(1, 1)),
            CKVertex2D(position: SIMD2<Float>(-halfW, -halfH), textureCoordinate: SIMD2<Float>(0, 1)),
            CKVertex2D(position: SIMD2<Float>(halfW, halfH), textureCoordinate: SIMD2<Float>(1, 0)),
            CKVertex2D(position: SIMD2<Float>(-halfW, halfH), textureCoordinate: SIMD2<Float>(0, 0))
        ]
        var viewportSize = SIMD2<UInt32>(UInt32(tileWidth), UInt32(tileHeight))

        encoder.setViewport(MTLViewport(
            originX: 0, originY: 0,
            width: Double(tileWidth), height: Double(tileHeight),
            znear: -1, zfar: 1
        ))
        encoder.setRenderPipelineState(renderPipelines.drawOSC)
        encoder.setVertexBytes(
            &vertices,
            length: MemoryLayout<CKVertex2D>.stride * vertices.count,
            index: Int(CKVertexInputIndexVertices.rawValue)
        )
        encoder.setVertexBytes(
            &viewportSize,
            length: MemoryLayout<SIMD2<UInt32>>.size,
            index: Int(CKVertexInputIndexViewportSize.rawValue)
        )

        var packed = points
        var pointCount: Int32 = Int32(packed.count)
        var activePart32: Int32 = Int32(activePart)
        var screenColourLinear = Self.linearScreenColour(for: screenColor)
        packed.withUnsafeMutableBytes { rawBytes in
            if let base = rawBytes.baseAddress {
                encoder.setFragmentBytes(base, length: rawBytes.count, index: 0)
            }
        }
        encoder.setFragmentBytes(&pointCount, length: MemoryLayout<Int32>.size, index: 1)
        encoder.setFragmentBytes(&activePart32, length: MemoryLayout<Int32>.size, index: 2)
        // SIMD3<Float> has a 16-byte stride on Metal — the shader
        // reads it as `float3` (also 16-byte aligned), so the layout
        // matches once we hand over the in-memory representation.
        encoder.setFragmentBytes(&screenColourLinear, length: MemoryLayout<SIMD3<Float>>.stride, index: 3)
        encoder.setFragmentBytes(
            &viewportSize,
            length: MemoryLayout<SIMD2<UInt32>>.size,
            index: 4
        )

        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilScheduled()
    }

    /// Background-hint swatch colours. Values mirror the SwiftUI
    /// `screenColorSwatch` palette in `OnScreenControlOverlay` so the
    /// FxPlug OSC and the Standalone Editor mark out a "drop this
    /// region" tile in identical green / blue.
    private static func linearScreenColour(for screenColor: ScreenColor) -> SIMD3<Float> {
        switch screenColor {
        case .green, .automatic, .custom:
            return SIMD3<Float>(0.20, 0.78, 0.30)
        case .blue:
            return SIMD3<Float>(0.20, 0.42, 0.95)
        }
    }
}
