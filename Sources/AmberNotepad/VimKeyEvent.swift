import AppKit
import NotepadCore

/// How the adapter reads a key event.
enum VimKeyInput: Equatable {
    /// A key the engine understands.
    case key(VimKey)
    /// A Command shortcut, which AppKit handles in every mode.
    case shortcut
    /// A key with Option held that types a character; Insert mode lets AppKit have it.
    case optionChord
    /// A key the engine has no command for.
    case unmapped
}

extension NSEvent {
    private static let privateUseRange: ClosedRange<UInt32> = 0xF700...0xF8FF

    var vimInput: VimKeyInput {
        if keyCode == 53 || charactersIgnoringModifiers == "\u{1b}" {
            return .key(VimKey(.escape))
        }
        if modifierFlags.contains(.command) { return .shortcut }
        let control = modifierFlags.contains(.control)
        if let special = specialVimKey { return .key(VimKey(special, control: control)) }
        if modifierFlags.contains(.option) && !control { return .optionChord }
        let typed = control ? charactersIgnoringModifiers : characters
        guard let typed, typed.count == 1, let character = typed.first,
              !character.unicodeScalars.contains(where: Self.isFunctionKey)
        else { return .unmapped }
        if control {
            return .key(VimKey(.character(Character(character.lowercased())), control: true))
        }
        switch character {
        case "\r", "\u{3}": return .key(VimKey(.enter))
        case "\t": return .key(VimKey(.tab))
        case "\u{7f}": return .key(VimKey(.backspace))
        default: return .key(VimKey(.character(character)))
        }
    }

    private static func isFunctionKey(_ scalar: Unicode.Scalar) -> Bool {
        privateUseRange.contains(scalar.value)
    }

    private var specialVimKey: VimKey.Base? {
        switch specialKey {
        case .upArrow: return .up
        case .downArrow: return .down
        case .leftArrow: return .left
        case .rightArrow: return .right
        case .home: return .home
        case .end: return .end
        case .pageUp: return .pageUp
        case .pageDown: return .pageDown
        case .deleteForward: return .delete
        case .delete: return .backspace
        default: return keyCode == 51 ? .backspace : nil
        }
    }
}
