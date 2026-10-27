import CoreMedia
import Foundation

/// Runs production OSC callbacks against the SDK's real custom-parameter decoder.
@main
struct ManualHintHostTests {
    static func main() throws {
        let host = FxPlugTestHost()
        let control = try require(CorridorKeyHintOSC(apiManager: host))
        host.plugin = control
        defer { host.plugin = nil }
        let retrieval = try require(host.api(for: (any FxParameterRetrievalAPI_v6).self) as? any FxParameterRetrievalAPI_v6)
        let originalArchive = host.archive

        // Reproduce the reported failure: a session instance without the class
        // selector yields YES plus nil, and the SDK logs "due to error: (null)".
        host.plugin = NSObject()
        precondition(HeaderCustomParameterStorage.storageDictionary(using: retrieval).dictionary == nil)
        precondition(!HeaderCustomParameterStorage.setDictionary(
            OnScreenControlTool.foregroundHint.parameterDictionary,
            for: HeaderStorageKey.subjectTool, using: host
        ))
        precondition(host.archive == originalArchive && host.writeCount == 0)

        host.plugin = control
        precondition(HeaderCustomParameterStorage.storageDictionary(using: retrieval).dictionary != nil)
        func select(_ tool: OnScreenControlTool) {
            precondition(HeaderCustomParameterStorage.setDictionary(
                tool.parameterDictionary, for: HeaderStorageKey.subjectTool, using: host
            ))
        }
        func points() -> HintPointSet {
            HintPointSet.fromParameterDictionary(HeaderCustomParameterStorage.dictionaryValue(
                for: HeaderStorageKey.subjectPoints, using: retrieval
            ))
        }
        func hit(at position: SIMD2<Double>, time: CMTime = .zero) -> Int {
            var part = 0
            control.hitTestOSC(atMousePositionX: position.x, mousePositionY: position.y, activePart: &part, at: time)
            return part
        }
        func click(at position: SIMD2<Double>, time: CMTime = .zero) {
            let part = hit(at: position, time: time)
            precondition(part != 0, "The host must route the first click on empty canvas")
            var update = ObjCBool(false)
            control.mouseDown(atPositionX: position.x, positionY: position.y, activePart: part,
                              modifiers: 0, forceUpdate: &update, at: time)
            precondition(update.boolValue, "A successful edit requests a viewer refresh")
        }

        precondition(hit(at: SIMD2(250, 500)) == 0)
        select(.foregroundHint)
        click(at: SIMD2(250, 500))
        precondition(points().points.first?.kind == .foreground)
        precondition(points().points.first?.x == 0.25)
        precondition(host.hintMode == Int32(HintMode.manual.rawValue))
        select(.backgroundHint)
        click(at: SIMD2(750, 500))
        select(.ignoreHint)
        click(at: SIMD2(500, 250), time: CMTime(value: 1, timescale: 25))
        precondition(points().points(at: .zero).map(\.kind) == [.foreground, .background])
        precondition(points().points(at: CMTime(value: 1, timescale: 25)).map(\.kind) == [.ignore])
        select(.eraseHint)
        click(at: SIMD2(250, 500))
        precondition(points().points(at: .zero).map(\.kind) == [.background])
        precondition(points().points.count == 2)

        host.useAlphaHint = true
        precondition(hit(at: SIMD2(750, 500)) == 0)
        host.useAlphaHint = false
        select(.disabled)
        precondition(hit(at: SIMD2(750, 500)) == 0)

        // A new OSC session must retrieve this clip's saved points independently.
        let reopenedControl = try require(CorridorKeyHintOSC(apiManager: host))
        host.plugin = reopenedControl
        precondition(points().points.count == 2)
        print("PASS: real FxPlug decoder, failed-read preservation, tool selection, first-click routing, foreground/background/ignore, frame isolation, erase, Off, external mask and reopened session.")
    }

    private static func require<Value>(_ value: Value?) throws -> Value {
        guard let value else { throw CocoaError(.coderValueNotFound) }
        return value
    }
}
