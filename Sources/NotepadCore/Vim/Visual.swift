import Foundation

/// A command typed in Visual mode after any count and register.
enum VisualCommand: Equatable {
    /// `v`, `V` or Control-V: switch to that mode, or leave it when it is the current one.
    case mode(VimMode)
    /// `o`, and `O`, which in block mode moves to the other corner on the cursor's line.
    case swapEnds(sameLine: Bool)
    case reselect
    case operate(Operator, VisualExtent)
    case replace(Character)
    case join(spaces: Bool)
    /// Block mode `I`, and `A` when `append`.
    case blockInsert(append: Bool)
    case textObject(TextObject)
    /// `p`, and `P` when `before`.
    case put(before: Bool)
    /// A motion, scroll, jump or mark, which moves the cursor and so extends the selection.
    case normal(NormalCommand)

    private static let singleKey: [Character: VisualCommand] = [
        "v": .mode(.visual), "V": .mode(.visualLine),
        "o": .swapEnds(sameLine: false), "O": .swapEnds(sameLine: true),
        "x": .operate(.delete, .selection), "s": .operate(.change, .selection),
        "X": .operate(.delete, .linesOutsideBlock), "Y": .operate(.yank, .linesOutsideBlock),
        "D": .operate(.delete, .linesOrToLineEnd), "C": .operate(.change, .linesOrToLineEnd),
        "S": .operate(.change, .lines), "R": .operate(.change, .lines),
        "~": .operate(.toggleCase, .selection), "u": .operate(.lowercase, .selection),
        "U": .operate(.uppercase, .selection),
        "J": .join(spaces: true), "I": .blockInsert(append: false),
        "A": .blockInsert(append: true), "p": .put(before: false), "P": .put(before: true),
    ]

    static func parse(_ keys: [VimKey]) -> KeyParse<VisualCommand> {
        guard let first = keys.first else { return .incomplete }
        if first == VimKey(.character("v"), control: true) {
            return .complete(.mode(.visualBlock))
        }
        guard !first.control, case .character(let character) = first.base else {
            return normalCommand(keys)
        }
        if let command = singleKey[character] { return .complete(command) }
        if let op = Operator.named([first]) { return .complete(.operate(op, .selection)) }
        if character == "i" || character == "a" {
            return TextObject.parse(keys).map { .textObject($0) }
        }
        guard character == "r" || character == "g" else { return normalCommand(keys) }
        guard keys.count > 1 else { return .incomplete }
        if character == "r" {
            return keys[1].argumentCharacter.map { .complete(.replace($0)) } ?? .unknown
        }
        if let op = Operator.named([first, keys[1]]) { return .complete(.operate(op, .selection)) }
        switch keys[1] {
        case VimKey(.character("v")): return .complete(.reselect)
        case VimKey(.character("J")): return .complete(.join(spaces: false))
        default: return normalCommand(keys)
        }
    }

    private static func normalCommand(_ keys: [VimKey]) -> KeyParse<VisualCommand> {
        switch NormalCommand.parse(keys) {
        case .incomplete: return .incomplete
        case .unknown: return .unknown
        case .complete(let command):
            switch command {
            case .motion, .scroll, .jumpOlder, .jumpNewer, .setMark, .record, .play:
                return .complete(.normal(command))
            case .operator, .operate, .edit, .startVisual, .reselectVisual:
                return .unknown
            }
        }
    }
}

/// How much text a Visual operator takes.
enum VisualExtent: Equatable {
    case selection
    /// Whole lines in every mode: `S` and `R`.
    case lines
    /// Whole lines, but the block itself in block mode: `X` and `Y`.
    case linesOutsideBlock
    /// Whole lines, but in block mode the block extended to every line's end: `D` and `C`.
    case linesOrToLineEnd
}

extension VimEngine {
    // MARK: Entering, leaving and moving

    static func startVisual(_ mode: VimMode, count: Int?, _ result: inout VimResult,
                            _ b: VimBuffer) {
        if let count, let size = result.session.lastVisualSize {
            selectSameSize(size, count: count, &result, b)
            return
        }
        let cursor = result.window.cursor
        result.window.mode = mode
        result.window.visualAnchor = cursor
        guard let count, count > 1 else { return }
        let line = b.lineIndex(of: cursor)
        if mode == .visualLine {
            let target = min(line + count - 1, b.lineCount - 1)
            let column = b.displayColumn(of: cursor, tabstop: result.session.options.tabstop)
            result.window.cursor = b.offset(line: target, displayColumn: column,
                                            tabstop: result.session.options.tabstop)
            return
        }
        var offset = cursor
        for _ in 1..<count {
            guard offset < b.contentEnd(line), let next = b.nextGrapheme(after: offset) else {
                break
            }
            offset = next
        }
        result.window.cursor = offset
    }

    /// Selects as much text as `size` from the cursor, `count` times over, as `.` and a count
    /// before `v` do.
    static func selectSameSize(_ size: VisualSize, count: Int, _ result: inout VimResult,
                               _ b: VimBuffer) {
        let tabstop = result.session.options.tabstop
        let cursor = result.window.cursor
        let line = b.lineIndex(of: cursor)
        let startColumn = b.displayColumn(of: cursor, tabstop: tabstop)
        let (lines, linesOverflow) = size.lines.multipliedReportingOverflow(by: count)
        var endLine = line
        if size.mode != .visual || size.lines > 1 {
            endLine = linesOverflow || lines >= b.lineCount ? b.lineCount - 1
                : min(line + lines - 1, b.lineCount - 1)
        }
        let (columns, columnsOverflow) = size.columns.multipliedReportingOverflow(by: count)
        var want = startColumn
        if size.columns == Int.max || columnsOverflow {
            want = Int.max
        } else if size.mode == .visualBlock || (size.mode == .visual && size.lines <= 1) {
            want = startColumn + columns - 1
        } else if size.mode == .visual {
            want = size.columns
        }
        result.window.mode = size.mode
        result.window.visualAnchor = cursor
        result.window.cursor = want == Int.max ? b.contentEnd(endLine)
            : b.offset(line: endLine, displayColumn: want, tabstop: tabstop)
        result.window.desiredColumn = want == Int.max && size.mode != .visualLine ? Int.max : nil
    }

    static func endVisual(_ result: inout VimResult, _ b: VimBuffer) {
        let window = result.window
        if !window.repeatingVisual { result.window.lastVisual = currentSelection(window, b) }
        result.window.mode = .normal
        result.window.visualAnchor = nil
        result.window.repeatingVisual = false
        result.window.cursor = Motions.normalPosition(window.cursor, in: b)
    }

    /// The window's Visual selection, as `gv` keeps it.
    private static func currentSelection(_ window: VimWindowState,
                                         _ b: VimBuffer) -> LastVisual {
        LastVisual(mode: window.mode, anchor: b.mark(at: window.visualAnchor ?? window.cursor),
                   cursor: b.mark(at: window.cursor), toLineEnd: window.desiredColumn == Int.max)
    }

    /// `gv`: the last selection again. In Visual mode the current one takes its place.
    static func reselectVisual(_ result: inout VimResult, _ b: VimBuffer) {
        guard let last = result.window.lastVisual else {
            fail(&result)
            return
        }
        if result.window.mode.isVisual {
            result.window.lastVisual = currentSelection(result.window, b)
        }
        result.window.mode = last.mode
        result.window.visualAnchor = b.offset(of: last.anchor)
        result.window.cursor = b.offset(of: last.cursor)
        result.window.desiredColumn = last.toLineEnd ? Int.max : nil
    }

    static func visual(_ command: VisualCommand, _ input: CommandInput,
                       _ result: inout VimResult, _ b: VimBuffer, _ screen: ScreenGeometry,
                       _ clipboard: () -> String?) {
        switch command {
        case .mode(let mode):
            if mode == result.window.mode { endVisual(&result, b) } else {
                result.window.mode = mode
            }
        case .swapEnds(let sameLine): swapEnds(sameLine: sameLine, &result, b)
        case .reselect: reselectVisual(&result, b)
        case .operate(let op, let extent): visualOperate(op, extent, input, &result, b)
        case .replace(let character): visualReplace(character, input, &result, b)
        case .join(let spaces): visualJoin(spaces: spaces, input, &result, b)
        case .blockInsert(let append):
            guard result.window.mode == .visualBlock else {
                fail(&result)
                return
            }
            startBlockInsert(append: append, input, &result, b)
        case .textObject(let object): visualTextObject(object, input, &result, b)
        case .put(let before): visualPut(before: before, input, &result, b, clipboard)
        case .normal(let command): complete(command, input, &result, b, screen, clipboard)
        }
    }

    /// Vim's `v_swap_corners` for block `O`; otherwise the cursor and anchor change places.
    private static func swapEnds(sameLine: Bool, _ result: inout VimResult, _ b: VimBuffer) {
        let anchor = result.window.visualAnchor ?? result.window.cursor
        let cursor = result.window.cursor
        guard sameLine, result.window.mode == .visualBlock else {
            result.window.visualAnchor = cursor
            result.window.cursor = anchor
            result.window.desiredColumn = nil
            return
        }
        let tabstop = result.session.options.tabstop
        let block = visualBlock(anchor, cursor, toLineEnd: false, b, tabstop: tabstop)
        let anchorLine = b.lineIndex(of: anchor)
        let cursorLine = b.lineIndex(of: cursor)
        var left = block.start
        var right = block.end
        if b.offset(line: cursorLine, displayColumn: right, tabstop: tabstop) == cursor {
            swap(&left, &right)
        }
        result.window.visualAnchor = b.offset(line: anchorLine, displayColumn: left,
                                              tabstop: tabstop)
        result.window.cursor = b.offset(line: cursorLine, displayColumn: right, tabstop: tabstop)
        result.window.desiredColumn = right
    }

    private static func visualTextObject(_ object: TextObject, _ input: CommandInput,
                                         _ result: inout VimResult, _ b: VimBuffer) {
        let window = result.window
        guard let found = TextObjects.findVisual(
            object, count: max(input.count ?? 1, 1), anchor: window.visualAnchor ?? window.cursor,
            cursor: window.cursor, mode: window.mode, in: b) else {
            fail(&result)
            return
        }
        result.window.visualAnchor = found.anchor
        result.window.cursor = found.cursor
        result.window.mode = found.mode
        result.window.desiredColumn = nil
    }

    // MARK: Geometry

    static func visualBlock(_ anchor: Int, _ cursor: Int, toLineEnd: Bool, _ b: VimBuffer,
                            tabstop: Int) -> VisualBlock {
        let first = min(b.lineIndex(of: anchor), b.lineIndex(of: cursor))
        let last = max(b.lineIndex(of: anchor), b.lineIndex(of: cursor))
        let a = b.columns(at: anchor, tabstop: tabstop)
        let c = b.columns(at: cursor, tabstop: tabstop)
        var end = max(a.upperBound, c.upperBound)
        if toLineEnd {
            end = (first...last).map {
                b.displayColumn(of: b.contentEnd($0), tabstop: tabstop)
            }.max() ?? end
        }
        return VisualBlock(lines: first...last, start: min(a.lowerBound, c.lowerBound), end: end,
                           toLineEnd: toLineEnd)
    }

    /// A characterwise selection from `start` through the character at `end`. Ending after
    /// the last character takes the line break, except on the last line.
    static func characterRange(_ start: Int, _ end: Int, _ b: VimBuffer) -> NSRange {
        let line = b.lineIndex(of: end)
        let after: Int
        if end < b.contentEnd(line) {
            after = b.nextGrapheme(after: end) ?? end
        } else {
            after = line + 1 < b.lineCount ? b.lineStart(line + 1) : end
        }
        return NSRange(location: start, length: after - start)
    }

    /// What the adapter highlights: one range, or in block mode one per line.
    static func visualSelections(_ window: VimWindowState, _ b: VimBuffer,
                                 tabstop: Int) -> [NSRange] {
        let anchor = window.visualAnchor ?? window.cursor
        let start = min(anchor, window.cursor)
        let end = max(anchor, window.cursor)
        switch window.mode {
        case .visual:
            return [characterRange(start, end, b)]
        case .visualLine:
            let first = b.lineStart(b.lineIndex(of: start))
            return [NSRange(location: first,
                            length: NSMaxRange(b.lineRange(at: b.lineIndex(of: end))) - first)]
        case .visualBlock:
            let block = visualBlock(anchor, window.cursor,
                                    toLineEnd: window.desiredColumn == Int.max, b,
                                    tabstop: tabstop)
            return block.lines.map { line in
                let part = blockLine(line, block, .delete, b, tabstop: tabstop)
                return NSRange(location: part.textStart, length: part.textEnd - part.textStart)
            }
        case .normal, .insert, .replace, .operatorPending, .commandLine:
            return [NSRange(location: window.cursor, length: 0)]
        }
    }

    /// The size `.` and a count before `v` select again (Vim's `resel_VIsual_vcol`).
    private static func visualSize(_ mode: VimMode, _ anchor: Int, _ cursor: Int,
                                   toLineEnd: Bool, _ b: VimBuffer, tabstop: Int) -> VisualSize {
        let start = min(anchor, cursor)
        let end = max(anchor, cursor)
        let lines = b.lineIndex(of: end) - b.lineIndex(of: start) + 1
        let columns: Int
        if toLineEnd {
            columns = Int.max
        } else if mode == .visualBlock {
            let block = visualBlock(anchor, cursor, toLineEnd: false, b, tabstop: tabstop)
            columns = block.end - block.start + 1
        } else if lines == 1 {
            columns = b.columns(at: end, tabstop: tabstop).upperBound
                - b.displayColumn(of: start, tabstop: tabstop) + 1
        } else {
            columns = b.columns(at: end, tabstop: tabstop).upperBound
        }
        return VisualSize(mode: mode, lines: lines, columns: mode == .visualLine ? 0 : columns)
    }

    // MARK: Operators

    /// Ends Visual mode for a command that acts on the selection, recording the change `.`
    /// repeats, and returns the selection. `mode` and `toLineEnd` replace the window's when a
    /// command such as `D` widens the selection.
    static func takeSelection(_ input: CommandInput, mode: VimMode? = nil,
                              toLineEnd: Bool? = nil, _ result: inout VimResult,
                              _ b: VimBuffer) -> VisualTarget {
        let window = result.window
        let mode = mode ?? window.mode
        let toLineEnd = toLineEnd ?? (window.desiredColumn == Int.max)
        let anchor = window.visualAnchor ?? window.cursor
        let size = visualSize(mode, anchor, window.cursor, toLineEnd: toLineEnd, b,
                              tabstop: result.session.options.tabstop)
        var change = input.change
        if window.repeatingVisual {
            change.visual = result.session.lastChange?.visual ?? size
        } else {
            change.visual = size
            result.session.lastVisualSize = size
        }
        endVisual(&result, b)
        result.window.desiredColumn = nil
        return VisualTarget(mode: mode, anchor: anchor, cursor: window.cursor,
                            toLineEnd: toLineEnd, change: change,
                            repeating: window.repeatingVisual)
    }

    private static func visualOperate(_ op: Operator, _ extent: VisualExtent,
                                      _ input: CommandInput, _ result: inout VimResult,
                                      _ b: VimBuffer) {
        guard accepts(input.register, op) else {
            fail(&result)
            return
        }
        var mode = result.window.mode
        var toLineEnd = result.window.desiredColumn == Int.max
        switch extent {
        case .selection: break
        case .lines: mode = .visualLine
        case .linesOutsideBlock: if mode != .visualBlock { mode = .visualLine }
        case .linesOrToLineEnd:
            if mode == .visualBlock { toLineEnd = true } else { mode = .visualLine }
        }
        let selection = takeSelection(input, mode: mode, toLineEnd: toLineEnd, &result, b)
        if mode == .visualBlock {
            blockOperate(op, selection.block(b, tabstop: result.session.options.tabstop), input,
                         &result, b)
        } else {
            let onLines = mode == .visualLine
                || [.shiftLeft, .shiftRight, .reindent, .format].contains(op)
            let start = mode == .visualLine ? b.lineStart(selection.lines(b).lowerBound)
                : selection.start
            let region: Region = onLines ? .lines(selection.lines(b))
                : .characters(characterRange(start, selection.end, b))
            let options = OperatorOptions(register: input.register, visual: true,
                                          shiftAmount: shiftAmount(input.count))
            apply(op, to: OperatorSpan(region: region, start: start), options, &result, b)
        }
        record(op, selection.change, &result)
    }

    /// A count before a Visual `<` or `>` shifts that many times, capped so that the indent
    /// stays a reasonable size.
    static func shiftAmount(_ count: Int?) -> Int {
        min(max(count ?? 1, 1), 1000)
    }

    private static func visualReplace(_ character: Character, _ input: CommandInput,
                                      _ result: inout VimResult, _ b: VimBuffer) {
        let selection = takeSelection(input, &result, b)
        defer { result.session.lastChange = selection.change }
        guard selection.mode != .visualBlock else {
            blockReplace(character, selection.block(b, tabstop: result.session.options.tabstop),
                         &result, b)
            return
        }
        let range = selection.mode == .visualLine ? nil
            : characterRange(selection.start, selection.end, b)
        let lines = selection.lines(b)
        let contents = lines.map { line -> String in
            let content = b.contentRange(at: line)
            let from = range.map { max($0.location, content.location) } ?? content.location
            let to = range.map { min(NSMaxRange($0), NSMaxRange(content)) }
                ?? NSMaxRange(content)
            let old = b.substring(from..<max(from, to))
            return b.substring(content.location..<from)
                + String(repeating: String(character), count: old.count)
                + b.substring(max(from, to)..<NSMaxRange(content))
        }
        if let edit = rewrite(lines, as: contents, b) { result.edits.append(edit) }
        let cursorStart = selection.mode == .visualLine ? b.lineStart(lines.lowerBound)
            : selection.start
        result.window.cursor = Motions.normalPosition(cursorStart, in: b)
    }

    private static func visualJoin(spaces: Bool, _ input: CommandInput,
                                   _ result: inout VimResult, _ b: VimBuffer) {
        let selection = takeSelection(input, toLineEnd: false, &result, b)
        let lines = selection.lines(b)
        result.window.cursor = b.lineStart(lines.lowerBound)
        let join = CommandInput(count: max(lines.count, 2), register: nil, keys: input.keys)
        if self.join(spaces: spaces, join, &result, b) {
            result.session.lastChange = selection.change
        }
    }
}

/// The selection a Visual command acts on, taken as Visual mode ends.
struct VisualTarget {
    var mode: VimMode
    var anchor: Int
    var cursor: Int
    var toLineEnd: Bool
    /// What `.` repeats.
    var change: RecordedChange
    /// `.` made this selection.
    var repeating: Bool

    var start: Int { min(anchor, cursor) }
    var end: Int { max(anchor, cursor) }

    func lines(_ b: VimBuffer) -> ClosedRange<Int> {
        b.lineIndex(of: start)...b.lineIndex(of: end)
    }

    func block(_ b: VimBuffer, tabstop: Int) -> VisualBlock {
        VimEngine.visualBlock(anchor, cursor, toLineEnd: toLineEnd, b, tabstop: tabstop)
    }
}
