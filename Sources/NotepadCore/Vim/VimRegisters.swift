import Foundation

/// What a register holds. Linewise text always ends with a line break.
public struct RegisterValue: Equatable {
    public enum Kind: Equatable {
        case characterwise
        case linewise
        case blockwise([String])
    }

    public var text: String
    public var kind: Kind

    public init(text: String, kind: Kind) {
        self.text = text
        self.kind = kind
    }
}

/// Vim's registers, shared by every window: unnamed, `0`, `1`-`9`, `-`, `a`-`z`, the
/// read-only `.` `:` `/`, and the system clipboard behind `+` and `*`.
public struct VimRegisters: Equatable {
    private var unnamed: RegisterValue?
    private var stored: [Character: RegisterValue] = [:]

    public init() {}

    /// Whether `name` can be the target of a yank or delete. The black hole `_` counts: it
    /// accepts the text and discards it.
    public static func isWritable(_ name: Character) -> Bool {
        guard let ascii = name.asciiValue else { return false }
        return Self.isLetter(ascii) || (0x30...0x39).contains(ascii) || "-_+*".contains(name)
    }

    private static func isLetter(_ ascii: UInt8) -> Bool {
        (0x61...0x7A).contains(ascii) || (0x41...0x5A).contains(ascii)
    }

    /// The contents of `name`, or nil when it is empty or not a register. `+` and `*` read
    /// the system clipboard through `clipboard`; text ending in a line break is linewise.
    public func value(_ name: Character, clipboard: () -> String?) -> RegisterValue? {
        switch name {
        case "\"": return unnamed
        case "+", "*":
            guard let text = clipboard(), !text.isEmpty else { return nil }
            let kind: RegisterValue.Kind = text.hasSuffix("\n") ? .linewise : .characterwise
            return RegisterValue(text: text, kind: kind)
        case "_": return nil
        default: return stored[Character(name.lowercased())]
        }
    }

    /// Yanks into `name`, or into the unnamed register and `0` when `name` is nil or `"`.
    /// An uppercase name appends. Returns the text to place on the system clipboard when the
    /// target is `+` or `*`.
    @discardableResult
    public mutating func yank(_ value: RegisterValue, into name: Character?) -> String? {
        guard let target = Self.target(name) else {
            stored["0"] = value
            unnamed = value
            return nil
        }
        return write(value, to: target)
    }

    /// Records a delete. Without a register name, a `small` delete (within one line) goes to
    /// `-`; any other delete shifts `1`-`9` down and fills `1`. A named register takes the
    /// text and `1` takes it too, whatever the size (checked against Vim 9.1). With
    /// `alsoNumbered`, as for Vim's `d%`, a small delete fills `1` as well as `-`. The black
    /// hole changes nothing.
    @discardableResult
    public mutating func delete(_ value: RegisterValue, into name: Character?,
                                small: Bool, alsoNumbered: Bool = false) -> String? {
        var clipboardText: String?
        let target = Self.target(name)
        if let target {
            guard Self.isWritable(target), target != "_" else { return nil }
            clipboardText = write(value, to: target)
        }
        if target == nil && small {
            stored["-"] = value
            unnamed = value
            guard alsoNumbered else { return nil }
        }
        for number in stride(from: 9, to: 1, by: -1) {
            stored[Character(String(number))] = stored[Character(String(number - 1))]
        }
        stored["1"] = value
        if target == nil { unnamed = value }
        return clipboardText
    }

    /// Sets `.`, `:` or `/`, which only the engine writes.
    public mutating func setReadOnly(_ name: Character, _ text: String) {
        precondition(".:/".contains(name), "\(name) is not a read-only register")
        stored[name] = RegisterValue(text: text, kind: .characterwise)
    }

    private static func target(_ name: Character?) -> Character? {
        guard let name, name != "\"" else { return nil }
        return name
    }

    private mutating func write(_ value: RegisterValue, to name: Character) -> String? {
        guard Self.isWritable(name), name != "_" else { return nil }
        if name == "+" || name == "*" {
            unnamed = value
            return value.text
        }
        let key = Character(name.lowercased())
        let result = name.isUppercase ? Self.appending(value, to: stored[key]) : value
        stored[key] = result
        unnamed = result
        return nil
    }

    /// Appending a line to characterwise text, or characters to a line, makes the result
    /// linewise. A blockwise value on either side is appended as plain characters.
    private static func appending(_ value: RegisterValue, to old: RegisterValue?) -> RegisterValue {
        guard let old else { return value }
        let oldLinewise = old.kind == .linewise
        let newLinewise = value.kind == .linewise
        guard oldLinewise || newLinewise else {
            return RegisterValue(text: old.text + value.text, kind: .characterwise)
        }
        let first = oldLinewise ? old.text : old.text + "\n"
        let second = newLinewise ? value.text : value.text + "\n"
        return RegisterValue(text: first + second, kind: .linewise)
    }
}
