import Foundation
import Testing
@testable import CorridorKeyToolboxLogic

@Suite("Subject tool selection")
struct OnScreenControlToolTests {
    @Test("Normal clicks use the explicitly selected tool", arguments: OnScreenControlTool.allCases)
    func explicitSelection(tool: OnScreenControlTool) {
        #expect(tool.overriding(option: false, command: false, shift: false) == tool)
        #expect(OnScreenControlTool(parameterDictionary: tool.parameterDictionary) == tool)
    }

    @Test("Off and unknown saved tools leave host gestures untouched")
    func disabledTools() {
        #expect(OnScreenControlTool.disabled.overriding(option: true, command: true, shift: true) == .disabled)
        #expect(OnScreenControlTool(parameterDictionary: nil) == .disabled)
        #expect(OnScreenControlTool(parameterDictionary: ["tool": 99]) == .disabled)
    }

    @Test("Modifiers override an active tool with erase taking priority")
    func optionalModifiers() {
        #expect(OnScreenControlTool.foregroundHint.overriding(option: true, command: true, shift: true) == .eraseHint)
        #expect(OnScreenControlTool.backgroundHint.overriding(option: false, command: true, shift: true) == .ignoreHint)
        #expect(OnScreenControlTool.ignoreHint.overriding(option: false, command: false, shift: true) == .backgroundHint)
    }
}
