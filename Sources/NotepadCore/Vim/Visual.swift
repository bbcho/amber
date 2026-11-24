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
        "A": .blockInsert(append: true),
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
            case .motion, .scroll, .jumpOlder, .jumpNewer, .setMark:
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

/// What an operation does with one line of a block, which decides how `blockLine` treats
/// a tab cut by the block's edges (Vim's `is_del` and `op_type` in `block_prep`).
enum BlockPurpose: Equatable {
    /// Yanking and case changes: the text inside the block.
    case read
    /// Deleting, changing and showing the selection: a cut tab is taken whole.
    case delete
    case replace, insert, append
}

/// One line of a block, a port of Vim's `struct block_def` as `block_prep` fills it.
struct BlockLine: Equatable {
    /// UTF-16 offsets of the text the purpose takes (Vim's `textcol` and `textlen`).
    var textStart: Int
    var textEnd: Int
    /// Columns of a cut tab to write as spaces before and after that text.
    var startSpaces = 0
    var endSpaces = 0
    var isShort = false
    /// The line ends before the block's first column.
    var endsBefore = false
    /// The columns where `textStart` and the scan past the block end.
    var startColumn: Int
    var endColumn: Int
    /// The widths of the characters at the block's edges.
    var startCharacterColumns = 0
    var endCharacterColumns = 0
    /// The width and UTF-16 length of the blanks just before the block.
    var blanksBefore = 0
    var blanksBeforeLength = 0
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
        if !window.repeatingVisual {
            result.window.lastVisual = LastVisual(
                mode: window.mode, anchor: b.mark(at: window.visualAnchor ?? window.cursor),
                cursor: b.mark(at: window.cursor), toLineEnd: window.desiredColumn == Int.max)
        }
        result.window.mode = .normal
        result.window.visualAnchor = nil
        result.window.repeatingVisual = false
        result.window.cursor = Motions.normalPosition(window.cursor, in: b)
    }

    /// `gv`: the last selection again. In Visual mode the current one takes its place.
    static func reselectVisual(_ result: inout VimResult, _ b: VimBuffer) {
        guard let last = result.window.lastVisual else {
            fail(&result)
            return
        }
        let window = result.window
        if window.mode.isVisual {
            result.window.lastVisual = LastVisual(
                mode: window.mode, anchor: b.mark(at: window.visualAnchor ?? window.cursor),
                cursor: b.mark(at: window.cursor), toLineEnd: window.desiredColumn == Int.max)
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

    // MARK: Geometry

    private static func visualBlock(_ anchor: Int, _ cursor: Int, toLineEnd: Bool,
                                    _ b: VimBuffer, tabstop: Int) -> VisualBlock {
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

    private static func currentBlock(_ window: VimWindowState, toLineEnd: Bool, _ b: VimBuffer,
                                     tabstop: Int) -> VisualBlock {
        visualBlock(window.visualAnchor ?? window.cursor, window.cursor, toLineEnd: toLineEnd, b,
                    tabstop: tabstop)
    }

    /// A characterwise selection from `start` through the character at `end`. Ending after
    /// the last character takes the line break, except on the last line.
    private static func characterRange(_ start: Int, _ end: Int, _ b: VimBuffer) -> NSRange {
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
            let block = currentBlock(window, toLineEnd: window.desiredColumn == Int.max, b,
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

    private static func visualOperate(_ op: Operator, _ extent: VisualExtent,
                                      _ input: CommandInput, _ result: inout VimResult,
                                      _ b: VimBuffer) {
        if let name = input.register, op == .delete || op == .change || op == .yank,
           !VimRegisters.isWritable(name) && name != "\"" {
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
        let tabstop = result.session.options.tabstop
        let anchor = result.window.visualAnchor ?? result.window.cursor
        let cursor = result.window.cursor
        let change = recordVisualChange(input, visualSize(mode, anchor, cursor,
                                                          toLineEnd: toLineEnd, b,
                                                          tabstop: tabstop), &result)
        endVisual(&result, b)
        result.window.desiredColumn = nil
        if mode == .visualBlock {
            let block = visualBlock(anchor, cursor, toLineEnd: toLineEnd, b, tabstop: tabstop)
            blockOperate(op, block, input, &result, b)
        } else {
            let lines = b.lineIndex(of: min(anchor, cursor))...b.lineIndex(of: max(anchor, cursor))
            let start = mode == .visualLine ? b.lineStart(lines.lowerBound) : min(anchor, cursor)
            let onLines = mode == .visualLine
                || [.shiftLeft, .shiftRight, .reindent, .format].contains(op)
            let region: Region = onLines ? .lines(lines)
                : .characters(characterRange(start, max(anchor, cursor), b))
            operate(op, OperatorSpan(region: region, start: start), input, &result, b)
        }
        if op == .change {
            result.window.changeInProgress = change
        } else if op.changesText {
            result.session.lastChange = change
        }
    }

    /// The change `.` repeats for a Visual command, keeping the size of the selection that
    /// `.` itself made, as Vim does.
    private static func recordVisualChange(_ input: CommandInput, _ size: VisualSize,
                                           _ result: inout VimResult) -> RecordedChange {
        var change = input.change
        if result.window.repeatingVisual {
            change.visual = result.session.lastChange?.visual ?? size
        } else {
            change.visual = size
            result.session.lastVisualSize = size
        }
        return change
    }

    private static func operate(_ op: Operator, _ span: OperatorSpan, _ input: CommandInput,
                                _ result: inout VimResult, _ b: VimBuffer) {
        switch op {
        case .delete: delete(span, register: input.register, false, visual: true, &result, b)
        case .change: change(span, register: input.register, false, &result, b)
        case .yank: yank(span, register: input.register, &result, b)
        case .shiftLeft, .shiftRight:
            shift(span, left: op == .shiftLeft, amount: shiftAmount(input), &result, b)
        case .lowercase: changeCase(span, .lower, &result, b)
        case .uppercase: changeCase(span, .upper, &result, b)
        case .toggleCase: changeCase(span, .toggle, &result, b)
        case .rot13: changeCase(span, .rot13, &result, b)
        case .reindent: reindent(span, &result, b)
        case .format: format(span, &result, b)
        }
    }

    /// A count before a Visual `<` or `>` shifts that many times, capped so that the indent
    /// stays a reasonable size.
    private static func shiftAmount(_ input: CommandInput) -> Int {
        min(max(input.count ?? 1, 1), 1000)
    }

    private static func visualReplace(_ character: Character, _ input: CommandInput,
                                      _ result: inout VimResult, _ b: VimBuffer) {
        let mode = result.window.mode
        let tabstop = result.session.options.tabstop
        let anchor = result.window.visualAnchor ?? result.window.cursor
        let cursor = result.window.cursor
        let toLineEnd = result.window.desiredColumn == Int.max
        let change = recordVisualChange(input, visualSize(mode, anchor, cursor,
                                                          toLineEnd: toLineEnd, b,
                                                          tabstop: tabstop), &result)
        endVisual(&result, b)
        result.window.desiredColumn = nil
        if mode == .visualBlock {
            let block = visualBlock(anchor, cursor, toLineEnd: toLineEnd, b, tabstop: tabstop)
            blockReplace(character, block, &result, b)
        } else {
            let start = min(anchor, cursor)
            let range = mode == .visualLine ? nil : characterRange(start, max(anchor, cursor), b)
            let lines = b.lineIndex(of: start)...b.lineIndex(of: max(anchor, cursor))
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
            let cursorStart = mode == .visualLine ? b.lineStart(lines.lowerBound) : start
            result.window.cursor = Motions.normalPosition(cursorStart, in: b)
        }
        result.session.lastChange = change
    }

    private static func visualJoin(spaces: Bool, _ input: CommandInput,
                                   _ result: inout VimResult, _ b: VimBuffer) {
        let anchor = result.window.visualAnchor ?? result.window.cursor
        let cursor = result.window.cursor
        let tabstop = result.session.options.tabstop
        let mode = result.window.mode
        let change = recordVisualChange(input, visualSize(mode, anchor, cursor, toLineEnd: false,
                                                          b, tabstop: tabstop), &result)
        endVisual(&result, b)
        let first = b.lineIndex(of: min(anchor, cursor))
        let lineCount = b.lineIndex(of: max(anchor, cursor)) - first + 1
        result.window.cursor = b.lineStart(first)
        let join = CommandInput(count: max(lineCount, 2), register: nil, keys: input.keys)
        if self.join(spaces: spaces, join, &result, b) { result.session.lastChange = change }
    }

    // MARK: Block operators

    private static func blockOperate(_ op: Operator, _ block: VisualBlock,
                                     _ input: CommandInput, _ result: inout VimResult,
                                     _ b: VimBuffer) {
        let tabstop = result.session.options.tabstop
        let top = block.lines.lowerBound
        let topLeft = b.offset(line: top, displayColumn: block.start, tabstop: tabstop)
        let span = OperatorSpan(region: .lines(block.lines), start: topLeft)
        switch op {
        case .yank:
            let clipboard = result.session.registers.yank(
                blockValue(block, b, tabstop: tabstop),
                into: target(input.register, result.session.options))
            if let clipboard { result.effects.append(.setClipboard(clipboard)) }
            result.window.cursor = Motions.normalPosition(topLeft, in: b)
            let bottom = block.lines.upperBound
            let bottomRight = b.offset(line: bottom, displayColumn: block.end, tabstop: tabstop)
            setChangeMarks(b.mark(at: topLeft), b.mark(at: bottomRight), &result.window)
        case .delete, .change:
            blockDelete(block, register: input.register, change: op == .change, &result, b)
        case .shiftLeft, .shiftRight:
            blockShift(block, left: op == .shiftLeft, amount: shiftAmount(input), &result, b)
        case .lowercase: blockCase(.lower, block, topLeft, &result, b)
        case .uppercase: blockCase(.upper, block, topLeft, &result, b)
        case .toggleCase: blockCase(.toggle, block, topLeft, &result, b)
        case .rot13: blockCase(.rot13, block, topLeft, &result, b)
        case .reindent: reindent(span, &result, b)
        case .format: format(span, &result, b)
        }
    }

    /// Vim's yank of a block: each line's text in the block, with spaces for a cut tab.
    private static func blockValue(_ block: VisualBlock, _ b: VimBuffer,
                                   tabstop: Int) -> RegisterValue {
        let lines = block.lines.map { line -> String in
            let part = blockLine(line, block, .read, b, tabstop: tabstop)
            return spaces(part.startSpaces) + b.substring(part.textStart..<part.textEnd)
                + spaces(part.endSpaces)
        }
        let width = block.toLineEnd ? block.end - block.start : block.end - block.start + 1
        return RegisterValue(text: lines.joined(separator: "\n"),
                             kind: .blockwise(width: max(width, 0)))
    }

    /// Deletes the block, turning a cut tab into the spaces outside the block. With `change`,
    /// Insert mode starts where the block was on its first line.
    private static func blockDelete(_ block: VisualBlock, register: Character?, change: Bool,
                                    _ result: inout VimResult, _ b: VimBuffer) {
        let tabstop = result.session.options.tabstop
        let clipboard = result.session.registers.delete(
            blockValue(block, b, tabstop: tabstop),
            into: target(register, result.session.options), small: block.lines.count == 1)
        if let clipboard { result.effects.append(.setClipboard(clipboard)) }
        let parts = block.lines.map { blockLine($0, block, .delete, b, tabstop: tabstop) }
        let contents = zip(block.lines, parts).map { line, part -> String in
            guard part.textEnd > part.textStart else {
                return b.substring(b.contentRange(at: line))
            }
            return b.substring(b.lineStart(line)..<part.textStart)
                + spaces(part.startSpaces + part.endSpaces)
                + b.substring(part.textEnd..<b.contentEnd(line))
        }
        if let edit = rewrite(block.lines, as: contents, b) { result.edits.append(edit) }
        let top = block.lines.lowerBound
        let lineStart = b.lineStart(top)
        let at = parts[0].textStart + parts[0].startSpaces
        let column = b.offset(line: top, displayColumn: block.start, tabstop: tabstop) - lineStart
        setChangeMarks(Mark(line: top, column: column),
                       Mark(line: block.lines.upperBound, column: column), &result.window)
        guard !change else {
            let insert = BlockInsert(kind: .change, block: block, start: at, cursorAfter: nil)
            result.window.mode = .insert
            result.window.cursor = at
            result.window.insertSession = InsertSession(block: insert)
            return
        }
        result.window.cursor = lineStart + normalColumn(at - lineStart, in: contents[0])
    }

    private static func blockReplace(_ character: Character, _ block: VisualBlock,
                                     _ result: inout VimResult, _ b: VimBuffer) {
        let tabstop = result.session.options.tabstop
        let contents = block.lines.map { line -> String in
            let part = blockLine(line, block, .replace, b, tabstop: tabstop)
            var count = block.end - block.start + 1
            if part.isShort { count -= block.end - part.endColumn + 1 }
            guard part.textEnd > part.textStart, count > 0 else {
                return b.substring(b.contentRange(at: line))
            }
            return b.substring(b.lineStart(line)..<part.textStart) + spaces(part.startSpaces)
                + String(repeating: String(character), count: count)
                + (part.isShort ? "" : spaces(part.endSpaces))
                + b.substring(part.textEnd..<b.contentEnd(line))
        }
        if let edit = rewrite(block.lines, as: contents, b) { result.edits.append(edit) }
        let top = block.lines.lowerBound
        let topLeft = b.offset(line: top, displayColumn: block.start, tabstop: tabstop)
        result.window.cursor = b.lineStart(top)
            + normalColumn(topLeft - b.lineStart(top), in: contents[0])
    }

    private static func blockCase(_ change: CaseChange, _ block: VisualBlock, _ topLeft: Int,
                                  _ result: inout VimResult, _ b: VimBuffer) {
        let tabstop = result.session.options.tabstop
        let contents = block.lines.map { line -> String in
            let part = blockLine(line, block, .read, b, tabstop: tabstop)
            return b.substring(b.lineStart(line)..<part.textStart)
                + change.apply(to: b.substring(part.textStart..<part.textEnd))
                + b.substring(part.textEnd..<b.contentEnd(line))
        }
        if let edit = rewrite(block.lines, as: contents, b) { result.edits.append(edit) }
        result.window.cursor = Motions.normalPosition(topLeft, in: b)
    }

    /// Vim's `shift_block`. `>` widens the blanks around the block's left edge; `<` removes
    /// blanks from the left edge up to the first non-blank. Lines that end before the block
    /// are left alone.
    private static func blockShift(_ block: VisualBlock, left: Bool, amount: Int,
                                   _ result: inout VimResult, _ b: VimBuffer) {
        let options = result.session.options
        let width = amount * (options.shiftwidth > 0 ? options.shiftwidth : options.tabstop)
        let contents = block.lines.map { line -> String in
            let part = blockLine(line, block, .read, b, tabstop: options.tabstop)
            guard !part.endsBefore else { return b.substring(b.contentRange(at: line)) }
            return left ? shiftedLeft(line, part, by: width, block, b, options)
                : shiftedRight(line, part, by: width, b, options)
        }
        if let edit = rewrite(block.lines, as: contents, b) { result.edits.append(edit) }
        let column = displayOffset(block.start, in: contents[0], tabstop: options.tabstop)
        result.window.cursor = b.lineStart(block.lines.lowerBound)
            + normalColumn(column, in: contents[0])
    }

    private static func shiftedRight(_ line: Int, _ part: BlockLine, by width: Int,
                                     _ b: VimBuffer, _ options: VimOptions) -> String {
        let runStart = part.textStart - part.blanksBeforeLength
        let fromColumn = part.startColumn - part.blanksBefore
        var total = width + part.blanksBefore
        var offset = part.textStart
        var column = part.startColumn
        while offset < b.contentEnd(line), b.isBlankCharacter(at: offset) {
            let step = b.columnWidth(at: offset, column: column, tabstop: options.tabstop)
            total += step
            column += step
            offset += 1
        }
        return b.substring(b.lineStart(line)..<runStart)
            + blanks(from: fromColumn, to: fromColumn + total, options)
            + b.substring(offset..<b.contentEnd(line))
    }

    private static func shiftedLeft(_ line: Int, _ part: BlockLine, by width: Int,
                                    _ block: VisualBlock, _ b: VimBuffer,
                                    _ options: VimOptions) -> String {
        let tabstop = options.tabstop
        var nonBlank = part.textStart
        var nonBlankColumn = part.startColumn
        while nonBlank < b.contentEnd(line), b.isBlankCharacter(at: nonBlank) {
            nonBlankColumn += b.columnWidth(at: nonBlank, column: nonBlankColumn,
                                            tabstop: tabstop)
            nonBlank += 1
        }
        let destination = nonBlankColumn - min(nonBlankColumn - block.start, width)
        var kept = b.lineStart(line)
        var keptColumn = 0
        while kept < nonBlank, let next = b.nextGrapheme(after: kept) {
            let step = b.columnWidth(at: kept, column: keptColumn, tabstop: tabstop)
            guard keptColumn + step <= destination else { break }
            keptColumn += step
            kept = next
        }
        return b.substring(b.lineStart(line)..<kept) + spaces(destination - keptColumn)
            + b.substring(nonBlank..<b.contentEnd(line))
    }

    /// Blanks from screen column `from` to `to`: spaces under `expandtab`, otherwise tabs to
    /// each tabstop and spaces after the last one.
    private static func blanks(from: Int, to: Int, _ options: VimOptions) -> String {
        guard !options.expandtab, options.tabstop > 0 else { return spaces(to - from) }
        var text = ""
        var column = from
        while (column / options.tabstop + 1) * options.tabstop <= to {
            text += "\t"
            column = (column / options.tabstop + 1) * options.tabstop
        }
        return text + spaces(to - column)
    }

    // MARK: Block I, A and c

    private static func startBlockInsert(append: Bool, _ input: CommandInput,
                                         _ result: inout VimResult, _ b: VimBuffer) {
        let tabstop = result.session.options.tabstop
        let block = currentBlock(result.window, toLineEnd: result.window.desiredColumn == Int.max,
                                 b, tabstop: tabstop)
        let anchor = result.window.visualAnchor ?? result.window.cursor
        let change = recordVisualChange(input, visualSize(.visualBlock, anchor,
                                                          result.window.cursor,
                                                          toLineEnd: block.toLineEnd, b,
                                                          tabstop: tabstop), &result)
        endVisual(&result, b)
        let top = block.lines.lowerBound
        let topLeft = b.offset(line: top, displayColumn: block.start, tabstop: tabstop)
        var at = topLeft
        if append {
            let part = blockLine(top, block, .append, b, tabstop: tabstop)
            at = min(part.textEnd, b.contentEnd(top))
            if part.isShort && !block.toLineEnd && part.endSpaces > 0 {
                result.edits.append(TextEdit(range: NSRange(location: at, length: 0),
                                             replacement: spaces(part.endSpaces)))
                at += part.endSpaces
            }
        }
        let insert = BlockInsert(kind: append ? .append : .insert, block: block, start: at,
                                 cursorAfter: topLeft)
        result.window.mode = .insert
        result.window.cursor = at
        result.window.desiredColumn = nil
        result.window.insertSession = InsertSession(block: insert)
        result.window.changeInProgress = change
    }

    /// Escape after block `I`, `A` or `c`: the text typed on the first line goes into the
    /// block's other lines, unless typing left that line.
    static func finishBlockInsert(_ insert: BlockInsert, typedUpTo cursor: Int,
                                  _ result: inout VimResult, _ b: VimBuffer) {
        let top = insert.block.lines.lowerBound
        guard b.lineIndex(of: cursor) == top else { return }
        if let after = insert.cursorAfter { result.window.cursor = after }
        guard cursor > insert.start, top < insert.block.lines.upperBound else { return }
        let typed = b.substring(insert.start..<cursor)
        let lines = (top + 1)...insert.block.lines.upperBound
        let tabstop = result.session.options.tabstop
        let contents = lines.map { blockInserted(typed, into: $0, insert, b, tabstop: tabstop) }
        if let edit = rewrite(lines, as: contents, b) { result.edits.append(edit) }
    }

    /// A port of Vim's `block_insert`, and of the loop in `op_change` for `c`.
    private static func blockInserted(_ typed: String, into line: Int, _ insert: BlockInsert,
                                      _ b: VimBuffer, tabstop: Int) -> String {
        let block = insert.block
        let lineStart = b.lineStart(line)
        let lineEnd = b.contentEnd(line)
        let unchanged = b.substring(lineStart..<lineEnd)
        let pad: Int
        let offset: Int
        let tabColumns: Int
        let part: BlockLine
        switch insert.kind {
        case .change:
            part = blockLine(line, block, .delete, b, tabstop: tabstop)
            guard !part.isShort else { return unchanged }
            return b.substring(lineStart..<part.textStart) + typed
                + b.substring(part.textStart..<lineEnd)
        case .insert:
            part = blockLine(line, block, .insert, b, tabstop: tabstop)
            guard !part.isShort else { return unchanged }
            (pad, offset, tabColumns) = (part.startSpaces, part.textStart,
                                         part.startCharacterColumns)
        case .append:
            part = blockLine(line, block, .append, b, tabstop: tabstop)
            tabColumns = part.endCharacterColumns
            if part.isShort {
                pad = block.toLineEnd ? 0 : block.end - part.endColumn + 1
                offset = part.textEnd
            } else {
                pad = part.endSpaces > 0 ? tabColumns - part.endSpaces : 0
                offset = part.textEnd - (pad > 0 ? 1 : 0)
            }
        }
        var rest = offset
        var after = ""
        if pad > 0, !part.isShort, rest < lineEnd, b.text.character(at: rest) == 0x09 {
            after = spaces(tabColumns - pad)
            rest += 1
        }
        return b.substring(lineStart..<offset) + spaces(pad) + typed + after
            + b.substring(rest..<lineEnd)
    }

    // MARK: Block line geometry

    /// A port of Vim's `block_prep` for one line.
    private static func blockLine(_ line: Int, _ block: VisualBlock, _ purpose: BlockPurpose,
                                  _ b: VimBuffer, tabstop: Int) -> BlockLine {
        let deletes = purpose != .read
        let lineEnd = b.contentEnd(line)
        var column = 0
        var position = b.lineStart(line)
        var previous = position
        var step = 0
        var blanks = (width: 0, length: 0)
        while column < block.start, position < lineEnd {
            step = b.columnWidth(at: position, column: column, tabstop: tabstop)
            column += step
            let next = b.nextGrapheme(after: position) ?? lineEnd
            blanks = b.isBlankCharacter(at: position)
                ? (blanks.width + step, blanks.length + next - position) : (0, 0)
            previous = position
            position = next
        }
        var part = BlockLine(textStart: position, textEnd: position, startColumn: column,
                             endColumn: column, startCharacterColumns: step,
                             blanksBefore: blanks.width, blanksBeforeLength: blanks.length)
        guard column >= block.start else {
            part.isShort = true
            part.endsBefore = true
            if !deletes || purpose == .append { part.endSpaces = block.end - block.start + 1 }
            return part
        }
        part.startSpaces = column - block.start
        if deletes && part.startSpaces > 0 { part.startSpaces = step - part.startSpaces }
        var end = position
        if column > block.end {
            oneCharacter(&part, block, purpose, width: step)
        } else {
            var previousEnd = end
            while part.endColumn <= block.end, end < lineEnd {
                previousEnd = end
                step = b.columnWidth(at: end, column: part.endColumn, tabstop: tabstop)
                part.endColumn += step
                end = b.nextGrapheme(after: end) ?? lineEnd
            }
            if part.endColumn <= block.end, !deletes || purpose == .append
                || purpose == .replace {
                part.isShort = true
                part.endSpaces = purpose == .append ? block.end - part.endColumn + 1 : 0
            } else if part.endColumn > block.end {
                part.endSpaces = part.endColumn - block.end - 1
                if !deletes && part.endSpaces > 0 {
                    part.endSpaces = step - part.endSpaces
                    if end != position { end = previousEnd }
                }
            }
        }
        part.endCharacterColumns = step
        if deletes && part.startSpaces > 0 { part.textStart = previous }
        part.textEnd = end
        return part
    }

    /// `block_prep` when one character, a tab, covers the whole block.
    private static func oneCharacter(_ part: inout BlockLine, _ block: VisualBlock,
                                     _ purpose: BlockPurpose, width: Int) {
        let blockWidth = block.end - block.start + 1
        switch purpose {
        case .insert:
            part.endSpaces = width - part.startSpaces
        case .append:
            part.startSpaces += blockWidth
            part.endSpaces = width - part.startSpaces
        case .read:
            part.startSpaces = blockWidth
        case .delete, .replace:
            part.startSpaces = width - (part.startColumn - block.start)
            part.endSpaces = part.startColumn - block.end - 1
        }
    }

    // MARK: Putting a block

    /// A port of the blockwise part of Vim's `do_put`: each line of the register goes in at
    /// the same screen column of the next lines, padded to the block's width when text
    /// follows, adding lines at the end of the text as needed.
    static func putBlock(_ text: String, width: Int, _ count: Int, _ put: Edit.Put,
                         _ result: inout VimResult, _ b: VimBuffer) {
        let tabstop = result.session.options.tabstop
        let cursor = result.window.cursor
        let first = b.lineIndex(of: cursor)
        let column = !put.before && !b.isLineEnd(cursor)
            ? b.columns(at: cursor, tabstop: tabstop).upperBound + 1
            : b.displayColumn(of: cursor, tabstop: tabstop)
        let pieces = text.components(separatedBy: "\n")
        let last = first + pieces.count - 1
        let puts = pieces.enumerated().map { index, piece -> PutLine in
            let line = first + index
            let old = line < b.lineCount ? b.substring(b.contentRange(at: line)) : ""
            return putPiece(piece, into: old, at: column, width: width, count, tabstop: tabstop)
        }
        let contents = puts.map(\.content)
        let (edit, lineStarts) = replacingLines(first...last, with: contents, b)
        result.edits.append(edit)
        let firstPut = puts[0]
        let lastPut = puts[puts.count - 1]
        setChangeMarks(Mark(line: first, column: firstPut.start),
                       Mark(line: last, column: lastPut.lastCharacter), &result.window)
        if put.cursorAfter {
            result.window.cursor = lineStarts[lineStarts.count - 1] + lastPut.end
        } else {
            result.window.cursor = lineStarts[0] + normalColumn(firstPut.start, in: contents[0])
        }
    }

    /// One line after a block put, with UTF-16 columns: where the put text starts, where
    /// what went in ends, and Vim's `']` column, on the last character that went in.
    private struct PutLine {
        var content: String
        var start: Int
        var end: Int
        var lastCharacter: Int
    }

    /// One line of a block put: `old` with `piece` put in at screen column `column`.
    private static func putPiece(_ piece: String, into old: String, at column: Int, width: Int,
                                 _ count: Int, tabstop: Int) -> PutLine {
        let characters = Array(old)
        var index = 0
        var offset = 0
        var reached = 0
        var step = 0
        while reached < column, index < characters.count {
            step = characters[index] == "\t" ? tabstop - reached % tabstop : 1
            reached += step
            offset += String(characters[index]).utf16.count
            index += 1
        }
        var insertAt = offset
        var before = 0
        var after = 0
        var removed = 0
        let short = reached < column || (reached == column && index == characters.count)
        if reached < column {
            before = column - reached
        } else if reached > column, characters[index - 1] == "\t" {
            after = reached - column
            before = step - after
            insertAt -= 1
            removed = 1
        }
        let pieceWidth = piece.reduce(0) { $0 + ($1 == "\t" ? tabstop : 1) }
        let fill = max(width - pieceWidth, 0)
        var inserted = ""
        for copy in 0..<count {
            inserted += piece
            if copy < count - 1 || !short { inserted += spaces(fill) }
        }
        let nsOld = old as NSString
        let middle = spaces(before) + inserted + spaces(after)
        let end = insertAt + middle.utf16.count
        let last = middle.isEmpty ? 1 : lastCharacterLength(of: middle)
        return PutLine(content: nsOld.substring(to: insertAt) + middle
                           + nsOld.substring(from: insertAt + removed),
                       start: insertAt + before, end: end, lastCharacter: max(end - last, 0))
    }

    /// One edit that gives `lines` the new `contents`, keeping each line's own line break
    /// and adding lines past the end with the text's line break, and the new start of each
    /// line.
    private static func replacingLines(_ lines: ClosedRange<Int>, with contents: [String],
                                       _ b: VimBuffer) -> (TextEdit, [Int]) {
        let start = b.lineStart(lines.lowerBound)
        let lastExisting = min(lines.upperBound, b.lineCount - 1)
        let appending = lines.upperBound > lastExisting
        let lineBreak = b.lineBreak(near: lastExisting)
        let endsWithBreak = b.contentEnd(lastExisting) < NSMaxRange(b.lineRange(at: lastExisting))
        var replacement = ""
        var starts: [Int] = []
        for (index, content) in contents.enumerated() {
            let line = lines.lowerBound + index
            if line > lastExisting && !endsWithBreak { replacement += lineBreak }
            starts.append(start + replacement.utf16.count)
            replacement += content
            if line < lastExisting || (appending && line == lastExisting) {
                replacement += b.substring(b.contentEnd(line)..<NSMaxRange(b.lineRange(at: line)))
            } else if line > lastExisting && endsWithBreak {
                replacement += lineBreak
            }
        }
        let end = appending ? b.length : b.contentEnd(lastExisting)
        return (TextEdit(range: NSRange(location: start, length: end - start),
                         replacement: replacement), starts)
    }

    // MARK: Helpers

    private static func spaces(_ count: Int) -> String {
        String(repeating: " ", count: max(count, 0))
    }

    /// The UTF-16 offset in `content` of the character covering screen column `column`, or
    /// the end of `content` when it is narrower.
    private static func displayOffset(_ column: Int, in content: String, tabstop: Int) -> Int {
        var reached = 0
        var offset = 0
        for character in content {
            let next = character == "\t" ? (reached / tabstop + 1) * tabstop : reached + 1
            if column < next { return offset }
            reached = next
            offset += String(character).utf16.count
        }
        return offset
    }

    /// `offset` within a line whose new content is `content`, moved back onto its last
    /// character when it is past it, as Normal mode requires.
    private static func normalColumn(_ offset: Int, in content: String) -> Int {
        let length = content.utf16.count
        guard offset >= length else { return offset }
        return max(length - lastCharacterLength(of: content), 0)
    }
}

extension VimBuffer {
    /// The screen columns the character at `offset` covers; at a line's end, its column.
    func columns(at offset: Int, tabstop: Int) -> ClosedRange<Int> {
        let start = displayColumn(of: offset, tabstop: tabstop)
        guard !isLineEnd(offset), text.character(at: offset) == 0x09 else { return start...start }
        return start...((start / tabstop + 1) * tabstop - 1)
    }

    /// How many screen columns the character at `offset` takes when it starts at `column`.
    func columnWidth(at offset: Int, column: Int, tabstop: Int) -> Int {
        text.character(at: offset) == 0x09 ? tabstop - column % tabstop : 1
    }
}
