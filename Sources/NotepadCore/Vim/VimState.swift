import Foundation

public enum VimMode: Equatable {
    case normal, insert, replace, visual, visualLine, visualBlock, operatorPending
    /// The footer prompt opened by `:`, `/` or `?`.
    case commandLine(Character)
}

/// A position that survives edits elsewhere in the text: a line, counted from 0, and a
/// UTF-16 offset from the start of that line.
public struct Mark: Equatable {
    public var line: Int
    public var column: Int

    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }
}

/// `f`, `F`, `t` and `T`.
public enum FindKind: Equatable {
    case forward, backward, tillForward, tillBackward
}

public struct LastFind: Equatable {
    public var character: Character
    public var kind: FindKind

    public init(character: Character, kind: FindKind) {
        self.character = character
        self.kind = kind
    }
}

public struct LastSearch: Equatable {
    public var pattern: String
    public var forward: Bool

    public init(pattern: String, forward: Bool) {
        self.pattern = pattern
        self.forward = forward
    }
}

public struct LastSubstitute: Equatable {
    public var pattern: String
    public var replacement: String

    public init(pattern: String, replacement: String) {
        self.pattern = pattern
        self.replacement = replacement
    }
}

public struct Recording: Equatable {
    public var register: Character
    public var keys: [VimKey]

    public init(register: Character, keys: [VimKey]) {
        self.register = register
        self.keys = keys
    }
}

/// The last Visual selection, for `gv`, `'<` and `'>`.
public struct LastVisual: Equatable {
    public var mode: VimMode
    public var anchor: Mark
    public var cursor: Mark

    public init(mode: VimMode, anchor: Mark, cursor: Mark) {
        self.mode = mode
        self.anchor = anchor
        self.cursor = cursor
    }
}

/// A change that `.` can repeat.
public struct RecordedChange: Equatable {
    public var register: Character?
    public var count: Int?
    /// The keys after the count and register. An insert's keys include the typed text and
    /// the closing Escape.
    public var keys: [VimKey]

    public init(register: Character?, count: Int?, keys: [VimKey]) {
        self.register = register
        self.count = count
        self.keys = keys
    }
}

/// An Insert or Replace mode session, from the command that started it to Escape.
public struct InsertSession: Equatable {
    /// The text the session has inserted so far, which becomes the `.` register.
    public var inserted = ""
    /// How many times the text goes in: Escape adds `count - 1` more copies, as `3ix<Esc>`
    /// inserts `xxx`.
    public var count: Int
    /// What goes before each extra copy: a line break and indent after `o` and `O`.
    public var repeatPrefix: String

    public init(count: Int = 1, repeatPrefix: String = "") {
        self.count = count
        self.repeatPrefix = repeatPrefix
    }
}

/// What Vim keeps per window. The adapter stores one per editor window and passes it back
/// with every key.
public struct VimWindowState: Equatable {
    public var mode: VimMode = .normal
    /// Keys of a command that is not complete yet, after any count, register and operator.
    public var pendingKeys: [VimKey] = []
    /// The count being typed.
    public var count: Int?
    /// The product of the counts typed before a register name or an operator. It multiplies
    /// the count typed after them, so `2"a3x` deletes six characters.
    public var leadingCount: Int?
    public var register: Character?
    /// The operator waiting for a motion or text object, as typed (`d`, `gU`). It is not
    /// empty exactly when the mode is operator-pending.
    public var operatorKeys: [VimKey] = []
    /// UTF-16 offset of the cursor.
    public var cursor = 0
    /// Vim's `curswant`: the screen column `j` and `k` aim for. `Int.max` means the end of
    /// the line, as after `$`. Nil means the cursor's own column.
    public var desiredColumn: Int?
    public var visualAnchor: Int?
    public var lastVisual: LastVisual?
    /// Marks `a`-`z`, `[`, `]`, and `'`, the position before the latest jump, which starts
    /// at the top of the text as in Vim.
    public var marks: [Character: Mark] = ["'": Mark(line: 0, column: 0)]
    public var jumpList: [Mark] = []
    /// The position in `jumpList` that Control-O and Control-I move from. It equals the
    /// list's length until the first Control-O after a jump.
    public var jumpIndex = 0
    /// Vim's window-local `scroll` option: the lines Control-D and Control-U move, set by
    /// a count on either and capped at the page height. Nil means half the page.
    public var scrollAmount: Int?
    /// The insert in progress; nil outside Insert and Replace mode.
    public var insertSession: InsertSession?
    /// The change that entered Insert or Replace mode. The keys typed there are added to it,
    /// and it becomes `VimSession.lastChange` at Escape.
    public var changeInProgress: RecordedChange?

    public init(cursor: Int = 0) {
        self.cursor = cursor
    }
}

/// What one Vim process shares between all its windows. The app owns a single value.
public struct VimSession: Equatable {
    public var registers = VimRegisters()
    public var options = VimOptions()
    public var lastSearch: LastSearch?
    public var lastSubstitute: LastSubstitute?
    public var lastFind: LastFind?
    /// The change `.` repeats.
    public var lastChange: RecordedChange?
    public var recording: Recording?

    public init() {}
}
