import Foundation

public enum VimMode: Equatable {
    case normal, insert, replace, visual, visualLine, visualBlock, operatorPending
    /// The footer prompt opened by `:`, `/` or `?`.
    case commandLine(Character)

    public var isVisual: Bool {
        switch self {
        case .visual, .visualLine, .visualBlock: return true
        case .normal, .insert, .replace, .operatorPending, .commandLine: return false
        }
    }
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
    /// Whether `$` extended the selection to the end of every line.
    public var toLineEnd: Bool

    public init(mode: VimMode, anchor: Mark, cursor: Mark, toLineEnd: Bool = false) {
        self.mode = mode
        self.anchor = anchor
        self.cursor = cursor
        self.toLineEnd = toLineEnd
    }
}

/// The size of a Visual selection that an operator used, which `.` and a count before `v`
/// select again from the cursor (Vim's `redo_VIsual` and `resel_VIsual`).
public struct VisualSize: Equatable {
    public var mode: VimMode
    public var lines: Int
    /// Within one line in `visual` mode, the number of screen columns; over several lines,
    /// the screen column of the last character. In `visualBlock` mode, the block's width.
    /// `Int.max` when `$` took every line to its end. Unused in `visualLine` mode.
    public var columns: Int

    public init(mode: VimMode, lines: Int, columns: Int) {
        self.mode = mode
        self.lines = lines
        self.columns = columns
    }
}

/// A change that `.` can repeat.
public struct RecordedChange: Equatable {
    public var register: Character?
    public var count: Int?
    /// The keys after the count and register. An insert's keys include the typed text and
    /// the closing Escape.
    public var keys: [VimKey]
    /// Set for a Visual operator, which `.` applies to a selection of this size.
    public var visual: VisualSize?

    public init(register: Character?, count: Int?, keys: [VimKey], visual: VisualSize? = nil) {
        self.register = register
        self.count = count
        self.keys = keys
        self.visual = visual
    }
}

/// A Visual block: lines and screen columns, both inclusive. With `toLineEnd`, `end` is the
/// end of the longest line.
public struct VisualBlock: Equatable {
    public var lines: ClosedRange<Int>
    public var start: Int
    public var end: Int
    public var toLineEnd: Bool

    public init(lines: ClosedRange<Int>, start: Int, end: Int, toLineEnd: Bool) {
        self.lines = lines
        self.start = start
        self.end = end
        self.toLineEnd = toLineEnd
    }
}

/// A Visual block `I`, `A` or `c`, whose text Escape copies to the block's other lines.
public struct BlockInsert: Equatable {
    public enum Kind: Equatable {
        case insert, append, change
    }

    public var kind: Kind
    public var block: VisualBlock
    /// Where typing started on the block's first line.
    public var start: Int
    /// Where the cursor goes after Escape; nil leaves it where Insert mode puts it.
    public var cursorAfter: Int?

    public init(kind: Kind, block: VisualBlock, start: Int, cursorAfter: Int?) {
        self.kind = kind
        self.block = block
        self.start = start
        self.cursorAfter = cursorAfter
    }
}

/// An Insert or Replace mode session, from the command that started it to Escape.
public struct InsertSession: Equatable {
    /// The keys that inserted text so far. They become the `.` register, and a count types
    /// them again.
    public var typed: [VimKey] = []
    /// How many times the text goes in: Escape types the keys `count - 1` more times, as
    /// `3ix<Esc>` inserts `xxx`.
    public var count: Int
    /// What goes before each extra copy: a line break and indent after `o` and `O`.
    public var repeatPrefix: String
    public var block: BlockInsert?

    public init(count: Int = 1, repeatPrefix: String = "", block: BlockInsert? = nil) {
        self.count = count
        self.repeatPrefix = repeatPrefix
        self.block = block
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
    /// Set while `.` repeats a Visual operator on a selection it made, which then leaves
    /// `lastVisual` alone, as Vim keeps `gv` on the selection the user made.
    public var repeatingVisual = false
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
    /// The size of the selection the last Visual operator used, for a count before `v`.
    public var lastVisualSize: VisualSize?
    public var recording: Recording?

    public init() {}
}
