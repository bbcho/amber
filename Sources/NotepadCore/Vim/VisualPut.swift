import Foundation

/// The new lines a Visual put writes, with the cursor and the `[` and `]` marks as an index
/// into `lines` and a UTF-16 column.
private struct PutLines {
    var lines: [String]
    var cursor: (line: Int, column: Int)
    var start: (line: Int, column: Int)
    var end: (line: Int, column: Int)
}

extension VimEngine {
    /// Visual `p` and `P`, after Vim's `nv_put`: the register replaces the selection. `p`
    /// puts the replaced text in the registers as a delete does; `P` leaves them alone.
    /// Afterwards `gv` selects the text that went in.
    static func visualPut(before: Bool, _ input: CommandInput, _ result: inout VimResult,
                          _ b: VimBuffer, _ clipboard: () -> String?) {
        let options = result.session.options
        let name = target(input.register, options) ?? "\""
        let value = result.session.registers.value(name, clipboard: clipboard)
        let selection = takeSelection(input, &result, b)
        let tabstop = options.tabstop
        guard let value else {
            deleteSelection(selection, register: before ? "_" : nil, &result, b)
            result.effects.append(.message("E353: Nothing in register \(name)"))
            result.effects.append(.failure)
            return
        }
        if !before { storeReplaced(selection, &result, b) }
        let count = max(input.count ?? 1, 1)
        let (range, put): (ClosedRange<Int>, PutLines)
        if selection.mode == .visualLine {
            let lines = repeated(lines(of: value), count)
            (range, put) = (selection.lines(b), linesPut(lines, from: 0, count: lines.count))
        } else if selection.mode == .visualBlock {
            (range, put) = putOverBlock(selection, value, count, before: before, b,
                                        tabstop: tabstop)
        } else {
            (range, put) = putOverCharacters(selection, value, count, b, tabstop: tabstop)
        }
        let (edit, starts) = replacing(range, with: put.lines, b)
        result.edits.append(edit)
        result.window.cursor = starts[put.cursor.line]
            + normalColumn(put.cursor.column, in: put.lines[put.cursor.line])
        let start = Mark(line: range.lowerBound + put.start.line, column: put.start.column)
        let end = Mark(line: range.lowerBound + put.end.line, column: put.end.column)
        setChangeMarks(start, end, &result.window)
        if !selection.repeating {
            result.window.lastVisual = LastVisual(mode: selection.mode, anchor: start, cursor: end)
        }
        result.session.lastChange = selection.change
    }

    private static func deleteSelection(_ selection: VisualTarget, register: Character?,
                                        _ result: inout VimResult, _ b: VimBuffer) {
        guard selection.mode != .visualBlock else {
            let block = selection.block(b, tabstop: result.session.options.tabstop)
            blockOperate(.delete, block, CommandInput(count: nil, register: register, keys: []),
                         &result, b)
            return
        }
        apply(.delete, to: span(of: selection, b),
              OperatorOptions(register: register, visual: true), &result, b)
    }

    /// The replaced text goes where a delete of the selection would put it.
    private static func storeReplaced(_ selection: VisualTarget, _ result: inout VimResult,
                                      _ b: VimBuffer) {
        guard selection.mode != .visualBlock else {
            let tabstop = result.session.options.tabstop
            let block = selection.block(b, tabstop: tabstop)
            let clipboard = result.session.registers.delete(
                blockValue(block, b, tabstop: tabstop),
                into: target(nil, result.session.options), small: block.lines.count == 1)
            if let clipboard { result.effects.append(.setClipboard(clipboard)) }
            return
        }
        storeDelete(span(of: selection, b).region, register: nil, false, &result, b)
    }

    private static func span(of selection: VisualTarget, _ b: VimBuffer) -> OperatorSpan {
        guard selection.mode != .visualLine else {
            let lines = selection.lines(b)
            return OperatorSpan(region: .lines(lines), start: b.lineStart(lines.lowerBound))
        }
        return OperatorSpan(region: .characters(characterRange(selection.start, selection.end,
                                                                b)),
                            start: selection.start)
    }

    private static func lines(of value: RegisterValue) -> [String] {
        var lines = value.text.components(separatedBy: "\n")
        if value.kind == .linewise && lines.last == "" { lines.removeLast() }
        return lines
    }

    private static func repeated(_ lines: [String], _ count: Int) -> [String] {
        Array(Array(repeating: lines, count: count).joined())
    }

    /// Lines put whole at index `first` of `newLines`, with the cursor on the first
    /// non-blank of the first.
    private static func linesPut(_ newLines: [String], from first: Int, count: Int) -> PutLines {
        let last = newLines[first + count - 1]
        return PutLines(lines: newLines,
                        cursor: (first, firstNonBlank(of: newLines[first], lineStart: 0)),
                        start: (first, 0),
                        end: (first + count - 1,
                              max(last.utf16.count - lastCharacterLength(of: last), 0)))
    }

    /// Characters put between `prefix` and `suffix` on one line. The cursor goes on the last
    /// one, or for text with line breaks on the first.
    private static func charactersPut(_ text: String, prefix: String, suffix: String,
                                      then following: [String]) -> PutLines {
        let pieces = text.components(separatedBy: "\n")
        let lastPiece = pieces[pieces.count - 1]
        let endColumn = (pieces.count == 1 ? prefix.utf16.count : 0) + lastPiece.utf16.count
            - lastCharacterLength(of: lastPiece)
        let start = (line: 0, column: prefix.utf16.count)
        let end = (line: pieces.count - 1, column: max(endColumn, 0))
        let lines = (prefix + text + suffix).components(separatedBy: "\n") + following
        return PutLines(lines: lines, cursor: pieces.count == 1 ? end : start, start: start,
                        end: end)
    }

    private static func putOverCharacters(_ selection: VisualTarget, _ value: RegisterValue,
                                          _ count: Int, _ b: VimBuffer,
                                          tabstop: Int) -> (ClosedRange<Int>, PutLines) {
        let range = characterRange(selection.start, selection.end, b)
        let first = b.lineIndex(of: range.location)
        let last = b.lineIndex(of: NSMaxRange(range))
        let prefix = b.substring(b.lineStart(first)..<range.location)
        let suffix = b.substring(NSMaxRange(range)..<b.contentEnd(last))
        switch value.kind {
        case .characterwise:
            let text = String(repeating: value.text, count: count)
            return (first...last, charactersPut(text, prefix: prefix, suffix: suffix, then: []))
        case .linewise:
            let put = repeated(lines(of: value), count)
            return (first...last, linesPut([prefix] + put + [suffix], from: 1, count: put.count))
        case .blockwise(let width):
            let column = TextFormat.displayWidth(Array(prefix), tabstop: tabstop)
            return blockPut(lines(of: value), width: width, count, into: [prefix + suffix],
                            lines: first...last, column: column, b, tabstop: tabstop)
        }
    }

    /// After the block is deleted, a block register or one line of characters goes in at
    /// the block's column on each line, other characters at its top left, and lines below
    /// the block for `p` or above it for `P`.
    private static func putOverBlock(_ selection: VisualTarget, _ value: RegisterValue,
                                     _ count: Int, before: Bool, _ b: VimBuffer,
                                     tabstop: Int) -> (ClosedRange<Int>, PutLines) {
        let block = selection.block(b, tabstop: tabstop)
        let top = block.lines.lowerBound
        let parts = block.lines.map { blockLine($0, block, .delete, b, tabstop: tabstop) }
        let deleted = deletedContents(block, parts, b)
        switch value.kind {
        case .blockwise(let width):
            return blockPut(lines(of: value), width: width, count, into: deleted,
                            lines: block.lines, column: block.start, b, tabstop: tabstop)
        case .characterwise where !value.text.contains("\n"):
            let pieces = Array(repeating: value.text, count: block.lines.count)
            let (range, initial) = blockPut(
                pieces, width: pieceWidth(value.text, tabstop: tabstop), count, into: deleted,
                lines: block.lines, column: block.start, b, tabstop: tabstop)
            var put = initial
            let firstEnd = put.start.column + String(repeating: value.text, count: count)
                .utf16.count - lastCharacterLength(of: value.text)
            put.cursor = (0, firstEnd)
            put.end = (0, firstEnd)
            return (range, put)
        case .characterwise:
            let column = parts[0].textStart - b.lineStart(top) + parts[0].startSpaces
            let line = deleted[0] as NSString
            let put = charactersPut(String(repeating: value.text, count: count),
                                    prefix: line.substring(to: column),
                                    suffix: line.substring(from: column),
                                    then: Array(deleted.dropFirst()))
            return (block.lines, put)
        case .linewise:
            let put = repeated(lines(of: value), count)
            let lines = before ? put + deleted : deleted + put
            return (block.lines, linesPut(lines, from: before ? 0 : deleted.count,
                                          count: put.count))
        }
    }

    /// `pieces` put as a block at screen column `column` of `contents`, the new text of
    /// `lines`, with the cursor where the first one went in.
    private static func blockPut(_ pieces: [String], width: Int, _ count: Int,
                                 into contents: [String], lines: ClosedRange<Int>, column: Int,
                                 _ b: VimBuffer, tabstop: Int) -> (ClosedRange<Int>, PutLines) {
        let (range, newLines, puts) = putPieces(pieces, width: width, count, into: contents,
                                                lines: lines, column: column, b,
                                                tabstop: tabstop)
        let start = (line: 0, column: puts[0].start)
        return (range, PutLines(lines: newLines, cursor: start, start: start,
                                end: (puts.count - 1, puts[puts.count - 1].lastCharacter)))
    }
}
