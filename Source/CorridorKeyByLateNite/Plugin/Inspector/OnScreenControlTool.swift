import Foundation

/// The same explicit Subject tools are available in both viewers.
enum OnScreenControlTool: Int, Hashable, Sendable, CaseIterable, Identifiable {
    case disabled = 0
    case foregroundHint = 1
    case backgroundHint = 2
    case ignoreHint = 3
    case eraseHint = 4

    var id: Self { self }

    /// Short label used by editor controls.
    var displayName: String {
        switch self {
        case .disabled: "Off"
        case .foregroundHint: "Foreground"
        case .backgroundHint: "Background"
        case .ignoreHint: "Ignore"
        case .eraseHint: "Erase"
        }
    }

    /// Action wording shared by both Subject menus.
    var menuDisplayName: String {
        switch self {
        case .disabled: "Off"
        case .foregroundHint: "Mark Foreground"
        case .backgroundHint: "Mark Background"
        case .ignoreHint: "Mark Ignore"
        case .eraseHint: "Erase Nearest Hint"
        }
    }

    /// The closed menu communicates the selected click action.
    var menuTitle: String {
        switch self {
        case .disabled: "Subject"
        case .foregroundHint: "Marking Foreground"
        case .backgroundHint: "Marking Background"
        case .ignoreHint: "Marking Ignore"
        case .eraseHint: "Erasing"
        }
    }

    var systemImage: String {
        switch self {
        case .disabled: "circle.slash"
        case .foregroundHint: "person.fill.badge.plus"
        case .backgroundHint: "rectangle.fill.badge.minus"
        case .ignoreHint: "xmark.circle.fill"
        case .eraseHint: "eraser"
        }
    }

    var menuImage: String { self == .disabled ? "person.crop.rectangle" : systemImage }

    /// FxPlug stores the selection with the clip, so OSC and inspector instances agree.
    var parameterDictionary: NSDictionary { ["tool": NSNumber(value: rawValue)] }

    /// Missing or unknown tools leave viewer clicks to the host.
    init(parameterDictionary: NSDictionary?) {
        self = (parameterDictionary?["tool"] as? NSNumber)
            .flatMap { Self(rawValue: $0.intValue) } ?? .disabled
    }

    /// Modifiers remain optional shortcuts. Off never intercepts host gestures.
    func overriding(option: Bool, command: Bool, shift: Bool) -> Self {
        guard self != .disabled else { return .disabled }
        if option { return .eraseHint }
        if command { return .ignoreHint }
        if shift { return .backgroundHint }
        return self
    }
}
