import Foundation

/// One key press, written in Vim's key notation by tests, `:norm` and macro registers.
public struct VimKey: Hashable {
    public enum Base: Hashable {
        case character(Character)
        case escape, enter, backspace, tab
        case up, down, left, right
        case home, end, pageUp, pageDown, delete
    }

    public let base: Base
    public let control: Bool

    public init(_ base: Base, control: Bool = false) {
        self.base = base
        self.control = control
    }

    private static let names: [(name: String, base: Base)] = [
        ("Esc", .escape), ("CR", .enter), ("Enter", .enter), ("Return", .enter),
        ("BS", .backspace), ("Tab", .tab), ("Up", .up), ("Down", .down),
        ("Left", .left), ("Right", .right), ("Home", .home), ("End", .end),
        ("PageUp", .pageUp), ("PageDown", .pageDown), ("Del", .delete),
        ("lt", .character("<")), ("Space", .character(" ")),
    ]

    /// Parses notation such as `dd<Esc>` or `<C-r>a`. Names are case-insensitive, as in Vim.
    public static func parse(_ notation: String) throws -> [VimKey] {
        var keys: [VimKey] = []
        var rest = Substring(notation)
        while let first = rest.first {
            guard first == "<" else {
                keys.append(VimKey(.character(first)))
                rest = rest.dropFirst()
                continue
            }
            let afterOpen = rest.index(after: rest.startIndex)
            guard let close = rest.firstIndex(of: ">"),
                  let key = key(named: String(rest[afterOpen..<close])) else {
                throw VimError("E474: Invalid key notation: \(rest)")
            }
            keys.append(key)
            rest = rest[rest.index(after: close)...]
        }
        return keys
    }

    private static func key(named name: String) -> VimKey? {
        if name.lowercased().hasPrefix("c-") {
            let rest = String(name.dropFirst(2))
            if rest.count == 1, let letter = rest.lowercased().first {
                return VimKey(.character(letter), control: true)
            }
            return key(named: rest).map { VimKey($0.base, control: true) }
        }
        return names.first { $0.name.lowercased() == name.lowercased() }
            .map { VimKey($0.base) }
    }

    /// The notation that `parse` turns back into this key.
    public var notation: String {
        let body: String
        switch base {
        case .character(let character):
            if character == "<" { body = "lt" }
            else if control { body = String(character) }
            else { return String(character) }
        case .escape: body = "Esc"
        case .enter: body = "CR"
        case .backspace: body = "BS"
        case .tab: body = "Tab"
        case .up: body = "Up"
        case .down: body = "Down"
        case .left: body = "Left"
        case .right: body = "Right"
        case .home: body = "Home"
        case .end: body = "End"
        case .pageUp: body = "PageUp"
        case .pageDown: body = "PageDown"
        case .delete: body = "Del"
        }
        return control ? "<C-\(body)>" : "<\(body)>"
    }
}
