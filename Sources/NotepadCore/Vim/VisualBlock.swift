import Foundation

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
    // MARK: Block operators

    static func blockOperate(_ op: Operator, _ block: VisualBlock, _ input: CommandInput,
                             _ result: inout VimResult, _ b: VimBuffer) {
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
            blockShift(block, left: op == .shiftLeft, amount: shiftAmount(input.count), &result,
                       b)
        case .lowercase: blockCase(.lower, block, topLeft, &result, b)
        case .uppercase: blockCase(.upper, block, topLeft, &result, b)
        case .toggleCase: blockCase(.toggle, block, topLeft, &result, b)
        case .rot13: blockCase(.rot13, block, topLeft, &result, b)
        case .reindent: reindent(span, &result, b)
        case .format: format(span, &result, b)
        }
    }

    /// Vim's yank of a block: each line's text in the block, with spaces for a cut tab.
    static func blockValue(_ block: VisualBlock, _ b: VimBuffer, tabstop: Int) -> RegisterValue {
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
        let contents = deletedContents(block, parts, b)
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
            result.window.insertSession = InsertSession(start: at, block: insert)
            return
        }
        result.window.cursor = lineStart + normalColumn(at - lineStart, in: contents[0])
    }

    /// Each line of `block` with its part deleted, a cut tab left as the spaces outside.
    static func deletedContents(_ block: VisualBlock, _ parts: [BlockLine],
                                _ b: VimBuffer) -> [String] {
        zip(block.lines, parts).map { line, part -> String in
            guard part.textEnd > part.textStart else {
                return b.substring(b.contentRange(at: line))
            }
            return b.substring(b.lineStart(line)..<part.textStart)
                + spaces(part.startSpaces + part.endSpaces)
                + b.substring(part.textEnd..<b.contentEnd(line))
        }
    }

    static func blockReplace(_ character: Character, _ block: VisualBlock,
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

    static func startBlockInsert(append: Bool, _ input: CommandInput,
                                 _ result: inout VimResult, _ b: VimBuffer) {
        let tabstop = result.session.options.tabstop
        let selection = takeSelection(input, &result, b)
        let block = selection.block(b, tabstop: tabstop)
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
        result.window.insertSession = InsertSession(start: at, block: insert)
        result.window.changeInProgress = selection.change
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
    static func blockLine(_ line: Int, _ block: VisualBlock, _ purpose: BlockPurpose,
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
        if column > block.end {
            oneCharacter(&part, block, purpose, width: step)
            part.endCharacterColumns = step
        } else {
            scanToBlockEnd(&part, line, block, purpose, b, tabstop: tabstop)
        }
        if deletes && part.startSpaces > 0 { part.textStart = previous }
        return part
    }

    /// The rest of `block_prep`: from the block's first character to past its last column,
    /// noting a short line or a tab cut by the block's right edge.
    private static func scanToBlockEnd(_ part: inout BlockLine, _ line: Int,
                                       _ block: VisualBlock, _ purpose: BlockPurpose,
                                       _ b: VimBuffer, tabstop: Int) {
        let lineEnd = b.contentEnd(line)
        let deletes = purpose != .read
        var end = part.textStart
        var previousEnd = end
        var step = part.startCharacterColumns
        while part.endColumn <= block.end, end < lineEnd {
            previousEnd = end
            step = b.columnWidth(at: end, column: part.endColumn, tabstop: tabstop)
            part.endColumn += step
            end = b.nextGrapheme(after: end) ?? lineEnd
        }
        part.endCharacterColumns = step
        part.textEnd = end
        let cut = part.endColumn - block.end - 1
        if part.endColumn <= block.end, !deletes || purpose == .append || purpose == .replace {
            part.isShort = true
            part.endSpaces = purpose == .append ? block.end - part.endColumn + 1 : 0
        } else if part.endColumn > block.end {
            part.endSpaces = deletes || cut == 0 ? cut : step - cut
            if !deletes && cut > 0 && end != part.textStart { part.textEnd = previousEnd }
        }
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
        let (lines, contents, puts) = putPieces(
            pieces, width: width, count, into: [b.substring(b.contentRange(at: first))],
            lines: first...first, column: column, b, tabstop: tabstop)
        let (edit, lineStarts) = replacing(lines, with: contents, b)
        result.edits.append(edit)
        let firstPut = puts[0]
        let lastPut = puts[puts.count - 1]
        setChangeMarks(Mark(line: first, column: firstPut.start),
                       Mark(line: first + puts.count - 1, column: lastPut.lastCharacter),
                       &result.window)
        if put.cursorAfter {
            result.window.cursor = lineStarts[puts.count - 1] + lastPut.end
        } else {
            result.window.cursor = lineStarts[0] + normalColumn(firstPut.start, in: contents[0])
        }
    }

    /// `pieces` put as a block at screen column `column` of `contents`, the new text of
    /// `lines`, continuing onto the lines after them and past the end of the text. Returns
    /// the lines rewritten, their new text and what went into each.
    static func putPieces(_ pieces: [String], width: Int, _ count: Int,
                          into contents: [String], lines: ClosedRange<Int>, column: Int,
                          _ b: VimBuffer,
                          tabstop: Int) -> (ClosedRange<Int>, [String], [PutLine]) {
        var contents = contents
        var last = lines.upperBound
        while contents.count < pieces.count {
            let following = last + 1 < b.lineCount
            if following { last += 1 }
            contents.append(following ? b.substring(b.contentRange(at: last)) : "")
        }
        let puts = pieces.indices.map {
            putPiece(pieces[$0], into: contents[$0], at: column, width: width, count,
                     tabstop: tabstop)
        }
        for index in puts.indices { contents[index] = puts[index].content }
        return (lines.lowerBound...last, contents, puts)
    }

    /// One line after a block put, with UTF-16 columns: where the put text starts, where
    /// what went in ends, and Vim's `']` column, on the last character that went in.
    struct PutLine {
        var content: String
        var start: Int
        var end: Int
        var lastCharacter: Int
    }

    /// The width Vim's `do_put` gives a line of a block register: each character measured
    /// from column 0, so a tab counts as `tabstop`.
    static func pieceWidth(_ piece: String, tabstop: Int) -> Int {
        piece.reduce(0) { $0 + ($1 == "\t" ? tabstop : 1) }
    }

    /// One line of a block put: `old` with `piece` put in at screen column `column`.
    static func putPiece(_ piece: String, into old: String, at column: Int, width: Int,
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
        let fill = max(width - pieceWidth(piece, tabstop: tabstop), 0)
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

    /// One edit that replaces whole `lines` with `newLines`, joined by the text's line break,
    /// keeping the line break after the last of `lines`; and where each new line starts.
    static func replacing(_ lines: ClosedRange<Int>, with newLines: [String],
                          _ b: VimBuffer) -> (TextEdit, [Int]) {
        let start = b.lineStart(lines.lowerBound)
        let lineBreak = b.lineBreak(near: lines.lowerBound)
        var starts: [Int] = []
        var replacement = ""
        for (index, line) in newLines.enumerated() {
            if index > 0 { replacement += lineBreak }
            starts.append(start + replacement.utf16.count)
            replacement += line
        }
        let end = b.contentEnd(lines.upperBound)
        return (TextEdit(range: NSRange(location: start, length: end - start),
                         replacement: replacement), starts)
    }

    // MARK: Helpers

    static func spaces(_ count: Int) -> String {
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
    static func normalColumn(_ offset: Int, in content: String) -> Int {
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
