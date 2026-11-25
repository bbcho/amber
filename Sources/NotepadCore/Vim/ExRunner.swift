import Foundation

/// Runs ex text commands on the text. A run gives at most one text edit, so one command,
/// however many lines it changes, is one undo step.
public enum ExRunner {
    /// Runs `command` over `range` (nil when none was typed) on `text`, which the window
    /// shows. `:normal`, alone or under `:g`, comes back as a `.replayLines` effect for the
    /// adapter to play. A failure comes back as a message and `.failure`, after the changes
    /// made before it, as `:g` keeps them.
    public static func run(_ command: ExTextCommand, range: ExRange?, window: VimWindowState,
                           session: VimSession, text: NSString,
                           clipboard: () -> String?) -> VimResult {
        withoutActuallyEscaping(clipboard) { clipboard in
            var run = ExRun(buffer: VimBuffer(text), window: window, session: session,
                            clipboard: clipboard)
            do {
                try run.execute(command, range: range)
            } catch {
                run.effects += [.message(error.localizedDescription), .failure]
            }
            return run.result()
        }
    }
}

/// What `:g` adds up while it runs its command, which then reports nothing itself.
struct GlobalTotals {
    var substitutions = 0
    var substitutedLines = 0
    var countOnly = false
}

/// One ex command in progress over the text's lines.
struct ExRun {
    var lines: ExLines
    var window: VimWindowState
    var session: VimSession
    let clipboard: () -> String?
    var effects: [VimEffect] = []
    /// The cursor's line, from 0, and its UTF-16 column.
    var cursor: (line: Int, column: Int)
    var global: GlobalTotals?
    private var regexes: [String: NSRegularExpression] = [:]

    /// Vim's `report` option: changes to more lines than this are reported.
    static let report = 2

    init(buffer: VimBuffer, window: VimWindowState, session: VimSession,
         clipboard: @escaping () -> String?) {
        lines = ExLines(buffer)
        self.window = window
        self.session = session
        self.clipboard = clipboard
        let mark = buffer.mark(at: window.cursor)
        cursor = (mark.line, mark.column)
    }

    mutating func execute(_ command: ExTextCommand, range: ExRange?) throws {
        switch command {
        case .goTo: try goTo(range)
        case .delete(let register, let count):
            delete(try lineRange(range, count: count), register: register)
        case .yank(let register, let count):
            yank(try lineRange(range, count: count), register: register)
        case .move(let target): try move(try lineRange(range), to: target)
        case .copy(let target): try copy(try lineRange(range), to: target)
        case .join(let spaces, let count): try join(range, spaces: spaces, count: count)
        case .shift(let left, let amount, let count):
            shift(try lineRange(range, count: count), left: left, amount: amount)
        case .substitute(let substitute): try self.substitute(substitute, range)
        case .global(let pattern, let matching, let command):
            try global(pattern, matching: matching, command: command, range)
        case .normal(let keys): try normal(keys, range)
        case .sort(let sort): try self.sort(sort, try lineRange(range, whole: true))
        case .retab(let bang): retab(try lineRange(range, whole: true), force: bang)
        case .noHighlight: effects.append(.highlightSearch(nil))
        case .undo: effects.append(.undo(1))
        case .redo: effects.append(.redo(1))
        case .put(let register, let above): try put(register, above: above, range)
        }
    }

    func result() -> VimResult {
        var result = VimResult(window: window, session: session, edits: [], selections: [],
                               effects: effects)
        if let edit = lines.edit() { result.edits = [edit] }
        let line = min(cursor.line, lines.count - 1)
        let content = lines.content(line)
        let length = content.utf16.count
        var column = min(cursor.column, length)
        if column == length && length > 0 {
            column -= VimEngine.lastCharacterLength(of: content)
        }
        let offset = lines.start(of: line) + column
        if offset != window.cursor || !result.edits.isEmpty { result.window.desiredColumn = nil }
        result.window.cursor = offset
        result.selections = [NSRange(location: result.window.cursor, length: 0)]
        return result
    }

    // MARK: Ranges

    /// The first and last line numbers of `range`, from 1, where 0 is the line before the
    /// first. Without a range: the cursor's line, or with `whole`, every line.
    mutating func lineNumbers(_ range: ExRange?, whole: Bool = false,
                              clampsToEnd: Bool = false) throws -> (first: Int, last: Int) {
        guard let range else {
            let line = cursor.line + 1
            return whole ? (1, lines.count) : (line, line)
        }
        var current = cursor.line + 1
        var values: [Int] = []
        for address in range.addresses {
            let value = try resolve(address, from: current)
            if address.movesCursor { current = value }
            values.append(clampsToEnd ? min(value, lines.count) : value)
        }
        let last = values[values.count - 1]
        let first = values.count > 1 ? values[values.count - 2] : last
        guard first <= lines.count, last <= lines.count else {
            throw VimError("E16: Invalid range")
        }
        guard first <= last else { throw VimError("E493: Backwards range given") }
        return (first, last)
    }

    /// The lines of `range` from 0, with line 0 taken as the first line. A count starts at
    /// the range's last line, as in Vim.
    mutating func lineRange(_ range: ExRange?, count: Int? = nil,
                            whole: Bool = false) throws -> ClosedRange<Int> {
        var (first, last) = try lineNumbers(range, whole: whole)
        if let count {
            first = last
            last = min(last + count - 1, lines.count)
        }
        return (max(first, 1) - 1)...(max(last, 1) - 1)
    }

    private mutating func resolve(_ address: ExAddress, from current: Int) throws -> Int {
        var line: Int
        switch address.base {
        case .current: line = current
        case .last: line = lines.count
        case .line(let number): line = number
        case .mark(let name): line = try markLine(name) + 1
        case .search(let searches):
            line = current
            for search in searches { line = try find(search, after: line) + 1 }
        }
        let (sum, overflow) = line.addingReportingOverflow(address.offset)
        guard !overflow, sum >= 0 else { throw VimError("E16: Invalid range") }
        return sum
    }

    private func markLine(_ name: Character) throws -> Int {
        let line: Int?
        switch name {
        case "<", ">":
            line = window.lastVisual.map { visual in
                name == "<" ? min(visual.anchor.line, visual.cursor.line)
                    : max(visual.anchor.line, visual.cursor.line)
            }
        case "`": line = window.marks["'"]?.line
        default: line = window.marks[name]?.line
        }
        guard let line else { throw VimError("E20: Mark not set") }
        return min(line, lines.count - 1)
    }

    /// The line (from 0) of the next match of `search` after `line` (from 1), or before it
    /// when searching backwards, wrapping around under `wrapscan`.
    private mutating func find(_ search: ExSearch, after line: Int) throws -> Int {
        let pattern = try searchPattern(search.pattern)
        rememberSearch(pattern, forward: search.forward)
        let regex = try compile(pattern, ignoreCase: nil)
        let wraps = session.options.wrapscan
        let candidates = Self.searchOrder(from: line - 1, count: lines.count,
                                          forward: search.forward, wraps: wraps)
        if let found = candidates.first(where: {
            Self.firstMatch(regex, in: lines.content($0)) != nil
        }) {
            return found
        }
        if wraps { throw VimError("E486: Pattern not found: \(pattern)") }
        throw VimError(search.forward
                       ? "E385: Search hit BOTTOM without match for: \(pattern)"
                       : "E384: Search hit TOP without match for: \(pattern)")
    }

    /// The lines after `current` (from 0; -1 for line 0) and then from the top, or the
    /// lines before it and then from the bottom.
    private static func searchOrder(from current: Int, count: Int, forward: Bool,
                                    wraps: Bool) -> [Int] {
        let split = min(max(forward ? current + 1 : current, 0), count)
        let ahead = forward ? Array(split..<count) : Array((0..<split).reversed())
        guard wraps else { return ahead }
        return ahead + (forward ? Array(0..<split) : Array((split..<count).reversed()))
    }

    // MARK: Patterns

    /// `pattern`, or for an empty one, the last search pattern.
    func searchPattern(_ pattern: String) throws -> String {
        guard pattern.isEmpty else { return pattern }
        guard let last = session.lastSearch?.pattern else {
            throw VimError("E35: No previous regular expression")
        }
        return last
    }

    /// `ignoreCase` true or false overrides `ignorecase` and turns `smartcase` off.
    mutating func compile(_ pattern: String, ignoreCase: Bool?,
                          smartCase: Bool = true) throws -> NSRegularExpression {
        let options = session.options
        let ignoring = ignoreCase ?? options.ignorecase
        let smart = ignoreCase == nil && smartCase && options.smartcase
        let previous = session.lastSubstitute?.replacement
        let key = "\(ignoring) \(smart) \(previous ?? "")\u{0}\(pattern)"
        if let regex = regexes[key] { return regex }
        let regex = try VimPattern.regex(pattern, ignoreCase: ignoring, smartCase: smart,
                                         previousSubstitute: previous)
        regexes[key] = regex
        return regex
    }

    /// Makes `pattern` the last search, as `:s`, `:g` and search addresses do.
    mutating func rememberSearch(_ pattern: String, forward: Bool) {
        session.lastSearch = LastSearch(pattern: pattern, forward: forward)
        session.registers.setReadOnly("/", pattern)
        let highlight = VimEffect.highlightSearch(pattern)
        if session.options.hlsearch && !effects.contains(highlight) { effects.append(highlight) }
    }

    static let matchBounds: NSRegularExpression.MatchingOptions = [
        .withTransparentBounds, .withoutAnchoringBounds,
    ]

    /// The first match in `line` from `start` whose ends are both on grapheme boundaries,
    /// so that no edit splits a grapheme cluster.
    static func firstMatch(_ regex: NSRegularExpression, in line: String,
                           from start: Int = 0) -> NSTextCheckingResult? {
        let text = line as NSString
        var position = start
        while position <= text.length {
            let rest = NSRange(location: position, length: text.length - position)
            guard let match = regex.firstMatch(in: line, options: matchBounds, range: rest)
            else { return nil }
            if isBoundary(match.range.location, text) && isBoundary(NSMaxRange(match.range), text) {
                return match
            }
            position = match.range.location + 1
        }
        return nil
    }

    private static func isBoundary(_ offset: Int, _ text: NSString) -> Bool {
        offset >= text.length || text.rangeOfComposedCharacterSequence(at: offset).location
            == offset
    }

    // MARK: Cursor and messages

    mutating func moveCursor(toFirstNonBlankOf line: Int) {
        cursor = (line, VimEngine.firstNonBlank(of: lines.content(line), lineStart: 0))
    }

    /// Vim's `msgmore`: more or fewer lines than `report`.
    mutating func reportChange(_ delta: Int) {
        guard global == nil, abs(delta) > Self.report else { return }
        effects.append(.message("\(abs(delta)) \(delta > 0 ? "more" : "fewer") lines"))
    }

    mutating func report(_ message: String, lines count: Int) {
        if global == nil && count > Self.report { effects.append(.message(message)) }
    }

    static func plural(_ count: Int, _ word: String, _ plural: String) -> String {
        "\(count) \(count == 1 ? word : plural)"
    }
}

// MARK: Line commands

extension ExRun {
    private mutating func goTo(_ range: ExRange?) throws {
        let (_, last) = try lineNumbers(range, clampsToEnd: true)
        VimEngine.recordJump(&window, lines.original)
        moveCursor(toFirstNonBlankOf: max(last, 1) - 1)
    }

    private func registerValue(_ range: ClosedRange<Int>) -> RegisterValue {
        RegisterValue(text: range.map { lines.content($0) + "\n" }.joined(), kind: .linewise)
    }

    private mutating func delete(_ range: ClosedRange<Int>, register: Character?) {
        let clipboardText = session.registers.delete(
            registerValue(range), into: VimEngine.target(register, session.options),
            small: false)
        if let clipboardText { effects.append(.setClipboard(clipboardText)) }
        lines.remove(range.lowerBound..<(range.upperBound + 1))
        moveCursor(toFirstNonBlankOf: min(range.lowerBound, lines.count - 1))
        reportChange(-range.count)
    }

    private mutating func yank(_ range: ClosedRange<Int>, register: Character?) {
        let clipboardText = session.registers.yank(
            registerValue(range), into: VimEngine.target(register, session.options))
        if let clipboardText { effects.append(.setClipboard(clipboardText)) }
        report("\(range.count) lines yanked", lines: range.count)
    }

    /// The line number (from 1) that `:m` and `:t` put lines below; 0 puts them first.
    private mutating func destination(_ target: ExAddress) throws -> Int {
        try lineNumbers(ExRange(addresses: [target])).last
    }

    private mutating func move(_ range: ClosedRange<Int>, to target: ExAddress) throws {
        let destination = try destination(target)
        let (first, last) = (range.lowerBound + 1, range.upperBound + 1)
        if destination >= first && destination < last {
            throw VimError("E134: Cannot move a range of lines into itself")
        }
        let contents = range.map(lines.content)
        let removed = range.lowerBound..<(range.upperBound + 1)
        let lastMoved: Int
        if destination >= last {
            lines.insert(contents, at: destination)
            lines.remove(removed)
            lastMoved = destination - 1
        } else {
            lines.remove(removed)
            lines.insert(contents, at: destination)
            lastMoved = destination + contents.count - 1
        }
        moveCursor(toFirstNonBlankOf: lastMoved)
        report("\(range.count) lines moved", lines: range.count)
    }

    private mutating func copy(_ range: ClosedRange<Int>, to target: ExAddress) throws {
        let destination = try destination(target)
        lines.insert(range.map(lines.content), at: destination)
        moveCursor(toFirstNonBlankOf: destination + range.count - 1)
        reportChange(range.count)
    }

    /// `:j` joins the range, or a line and the next. A range of one given line does
    /// nothing, and the last line alone fails.
    private mutating func join(_ range: ExRange?, spaces: Bool, count: Int?) throws {
        var (first, last) = try lineNumbers(range)
        (first, last) = (max(first, 1), max(last, 1))
        if let count {
            first = last
            last = min(last + count - 1, lines.count)
        }
        if first == last {
            let addresses = (range?.addresses.count ?? 0) + (count == nil ? 0 : 1)
            if addresses > 1 { return }
            guard last < lines.count else {
                effects.append(.failure)
                return
            }
            last += 1
        }
        let contents = ((first - 1)...(last - 1)).map(lines.content)
        lines.replace((first - 1)..<last, with: [TextFormat.join(contents, spaces: spaces).text])
        moveCursor(toFirstNonBlankOf: first - 1)
    }

    private mutating func shift(_ range: ClosedRange<Int>, left: Bool, amount: Int) {
        let options = session.options
        let width = amount * (options.shiftwidth > 0 ? options.shiftwidth : options.tabstop)
        for line in range {
            let content = lines.content(line)
            guard !content.isEmpty else { continue }
            let indent = TextFormat.leadingBlanks(of: content)
            let current = TextFormat.displayWidth(indent, tabstop: options.tabstop)
            let shifted = left ? max(current - width, 0) : current + width
            lines.replace(line, with: VimEngine.indentText(width: shifted, options)
                + content.dropFirst(indent.count))
        }
        moveCursor(toFirstNonBlankOf: range.upperBound)
        let times = Self.plural(amount, "time", "times")
        report("\(range.count) lines \(left ? "<" : ">")ed \(times)", lines: range.count)
    }

    private mutating func put(_ register: Character?, above: Bool, _ range: ExRange?) throws {
        let (_, line) = try lineNumbers(range)
        let name = VimEngine.target(register, session.options) ?? "\""
        guard let value = session.registers.value(name, clipboard: clipboard) else {
            throw VimError("E353: Nothing in register \(register ?? "\"")")
        }
        var contents = value.text.components(separatedBy: "\n")
        if value.kind == .linewise && contents.last == "" { contents.removeLast() }
        let index = above ? max(line - 1, 0) : line
        lines.insert(contents, at: index)
        moveCursor(toFirstNonBlankOf: index + contents.count - 1)
        reportChange(contents.count)
    }

    /// Vim's `:retab` with the current tabstop: each run of blanks holding a tab, and with
    /// `force` each run of two or more spaces, is rewritten as tabs and spaces under
    /// `noexpandtab`, or as spaces under `expandtab`.
    private mutating func retab(_ range: ClosedRange<Int>, force: Bool) {
        let options = session.options
        for line in range {
            lines.replace(line, with: Self.retabbed(lines.content(line), tabstop: options.tabstop,
                                                    expandtab: options.expandtab, force: force))
        }
    }

    static func retabbed(_ content: String, tabstop: Int, expandtab: Bool,
                         force: Bool) -> String {
        var out = ""
        var column = 0
        var runStart = 0
        var run = ""
        var spaces = 0
        var gotTab = false
        for character in content.map(Optional.some) + [nil] {
            if let blank = character, blank == " " || blank == "\t" {
                if !gotTab && spaces == 0 {
                    runStart = column
                    run = ""
                }
                run.append(blank)
                if blank == " " { spaces += 1 } else { gotTab = true }
            } else {
                if gotTab || (force && spaces > 1) {
                    out += retabbedRun(width: column - runStart, start: runStart,
                                       tabstop: tabstop, expandtab: expandtab,
                                       gotTab: gotTab) ?? run
                } else {
                    out += run
                }
                run = ""
                spaces = 0
                gotTab = false
                guard let character else { break }
                out.append(character)
            }
            column += character == "\t" ? tabstop - column % tabstop : 1
        }
        return out
    }

    /// The blanks that fill `width` columns from `start`, or nil when Vim keeps the run.
    private static func retabbedRun(width: Int, start: Int, tabstop: Int, expandtab: Bool,
                                    gotTab: Bool) -> String? {
        var spaces = width
        var tabs = 0
        if !expandtab {
            let toStop = tabstop - start % tabstop
            if spaces >= toStop {
                spaces -= toStop
                tabs += 1
            }
            tabs += spaces / tabstop
            spaces %= tabstop
        }
        guard expandtab || gotTab || spaces + tabs < width else { return nil }
        return String(repeating: "\t", count: tabs) + String(repeating: " ", count: spaces)
    }
}

// MARK: :g and :normal

extension ExRun {
    /// The keys `:normal` types: its characters, with control characters as control keys.
    static func keys(typing text: String) -> [VimKey] {
        text.map { character in
            switch character {
            case "\u{1B}": return VimKey(.escape)
            case "\r", "\r\n": return VimKey(.enter)
            case "\t": return VimKey(.tab)
            case "\u{8}", "\u{7F}": return VimKey(.backspace)
            default:
                guard let value = character.asciiValue, (1...26).contains(value) else {
                    return VimKey(.character(character))
                }
                return VimKey(.character(Character(UnicodeScalar(value + 0x60))),
                              control: true)
            }
        }
    }

    private mutating func normal(_ keys: String, _ range: ExRange?) throws {
        guard global == nil else {
            throw VimError(":normal with a range is not supported under :global")
        }
        let lines: LineReplay.Lines = range == nil ? .cursor : .numbers(try lineRange(range))
        effects.append(.replayLines(LineReplay(keys: Self.keys(typing: keys), lines: lines)))
    }

    /// The command `:g` runs, or nil to list the lines, as `:p` does.
    private func globalCommand(_ text: String) throws -> (ExRange?, ExTextCommand)? {
        let trimmed = String(text.drop(while: { $0 == " " || $0 == "\t" }))
        guard !trimmed.isEmpty else { return nil }
        guard case .text(let range, let command) = try ExCommand.parse(trimmed) else {
            throw VimError("E492: Not an editor command: \(trimmed)")
        }
        return (range, command)
    }

    /// `:g` marks the matching lines first, then runs the command on each line still
    /// marked, top to bottom, stopping at the first error. `:normal` goes to the adapter.
    private mutating func global(_ pattern: String, matching: Bool, command: String,
                                 _ range: ExRange?) throws {
        if global != nil {
            return try nestedGlobal(pattern, matching: matching, command: command, range)
        }
        let span = try lineRange(range, whole: true)
        let used = try searchPattern(pattern)
        let regex = try compile(used, ignoreCase: nil)
        rememberSearch(used, forward: session.lastSearch?.forward ?? true)
        let marked = span.filter { (Self.firstMatch(regex, in: lines.content($0)) != nil)
            == matching }
        guard let lastMarked = marked.last else {
            let message = matching ? "Pattern not found: \(used)"
                : "Pattern found in every line: \(used)"
            effects.append(.message(message))
            return
        }
        guard let (innerRange, inner) = try globalCommand(command) else {
            effects.append(.message(marked.map(lines.content).joined(separator: "\n")))
            moveCursor(toFirstNonBlankOf: lastMarked)
            return
        }
        if case .normal(let keys) = inner, innerRange == nil {
            let replay = LineReplay(keys: Self.keys(typing: keys), lines: .marked(marked))
            effects.append(.replayLines(replay))
            return
        }
        try runMarked(marked, inner, innerRange)
    }

    private mutating func runMarked(_ marked: [Int], _ command: ExTextCommand,
                                    _ range: ExRange?) throws {
        VimEngine.recordJump(&window, lines.original)
        for line in marked { lines.mark(line) }
        let before = lines.count
        global = GlobalTotals()
        while let line = lines.takeFirstMarked() {
            cursor = (line, 0)
            try execute(command, range: range)
        }
        let totals = global ?? GlobalTotals()
        global = nil
        reportChange(lines.count - before)
        reportSubstitutions(totals.substitutions, lines: totals.substitutedLines,
                            countOnly: totals.countOnly)
    }

    /// `:g` inside `:g` looks at the current line only, as in Vim.
    private mutating func nestedGlobal(_ pattern: String, matching: Bool, command: String,
                                       _ range: ExRange?) throws {
        guard range == nil else {
            throw VimError("E147: Cannot do :global recursive with a range")
        }
        let used = try searchPattern(pattern)
        let regex = try compile(used, ignoreCase: nil)
        rememberSearch(used, forward: session.lastSearch?.forward ?? true)
        let line = cursor.line
        guard (Self.firstMatch(regex, in: lines.content(line)) != nil) == matching else { return }
        guard let (innerRange, inner) = try globalCommand(command) else {
            effects.append(.message(lines.content(line)))
            return
        }
        try execute(inner, range: innerRange)
    }
}
