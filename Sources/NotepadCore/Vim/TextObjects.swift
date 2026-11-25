import Foundation

/// Vim's text objects, typed after an operator: `iw aw iW aW is as ip ap`, the quotes
/// `i" a" i' a' i` a``, and the blocks `i( a( ib ab i[ a[ i{ a{ iB aB i< a<`.
enum TextObject: Equatable {
    case word(inner: Bool, big: Bool)
    case sentence(inner: Bool)
    case paragraph(inner: Bool)
    case quote(UInt16, inner: Bool)
    case block(open: UInt16, close: UInt16, inner: Bool)

    private static let blocks: [Character: (open: UInt16, close: UInt16)] = [
        "(": (0x28, 0x29), ")": (0x28, 0x29), "b": (0x28, 0x29),
        "[": (0x5B, 0x5D), "]": (0x5B, 0x5D),
        "{": (0x7B, 0x7D), "}": (0x7B, 0x7D), "B": (0x7B, 0x7D),
        "<": (0x3C, 0x3E), ">": (0x3C, 0x3E),
    ]

    static func parse(_ keys: [VimKey]) -> KeyParse<TextObject> {
        guard let first = keys.first?.argumentCharacter, first == "i" || first == "a" else {
            return .unknown
        }
        guard keys.count > 1 else { return .incomplete }
        guard let second = keys[1].argumentCharacter else { return .unknown }
        let inner = first == "i"
        switch second {
        case "w": return .complete(.word(inner: inner, big: false))
        case "W": return .complete(.word(inner: inner, big: true))
        case "s": return .complete(.sentence(inner: inner))
        case "p": return .complete(.paragraph(inner: inner))
        case "\"", "'", "`":
            return .complete(.quote(second.utf16.first ?? 0, inner: inner))
        default:
            guard let pair = blocks[second] else { return .unknown }
            return .complete(.block(open: pair.open, close: pair.close, inner: inner))
        }
    }
}

/// Where a text object starts and ends, read like a motion from `start` to `end`.
struct TextObjectRange: Equatable {
    var start: Int
    var end: Int
    var kind: MotionKind
}

/// What `current_quote` reads from a Visual selection within one line, by column.
private struct QuoteSelection {
    let anchor: Int
    let cursor: Int
    /// The selection is exactly the inside of a string.
    let insideQuotes: Bool
    /// The selection holds a quote.
    let hasQuote: Bool

    init(anchor: Int, cursor: Int, _ quote: UInt16, _ unit: (Int) -> UInt16) {
        self.anchor = anchor
        self.cursor = cursor
        let low = min(anchor, cursor)
        let high = max(anchor, cursor)
        insideQuotes = anchor != cursor && low > 0 && unit(low - 1) == quote
            && unit(high) != 0 && unit(high + 1) == quote
        hasQuote = anchor != cursor && (low...high).contains { unit($0) == quote }
    }

    var isEmpty: Bool { anchor == cursor }
    var cursorAfterAnchor: Bool { anchor < cursor }

    /// Vim moves the selection's start to the string when it neither held a quote nor
    /// started on or just after one.
    func movesAnchor(_ quote: UInt16, _ unit: (Int) -> UInt16) -> Bool {
        !hasQuote && (insideQuotes || (unit(anchor) != quote
            && (anchor == 0 || unit(anchor - 1) != quote)))
    }

    func keepsAnchorAtQuote(_ quote: UInt16, _ unit: (Int) -> UInt16) -> Bool {
        !hasQuote && unit(anchor) != quote && (unit(anchor) == 0 || unit(anchor + 1) != quote)
    }
}

/// A Visual selection after a text object: Vim's `VIsual`, cursor and `VIsual_mode`.
struct VisualObjectSelection: Equatable {
    var anchor: Int
    var cursor: Int
    var mode: VimMode
}

/// Ports of Vim's `current_word`, `current_sent`, `current_par`, `current_quote` and
/// `current_block`, for an operator and in Visual mode.
enum TextObjects {
    static func find(_ object: TextObject, count: Int, from cursor: Int,
                     in b: VimBuffer) -> TextObjectRange? {
        switch object {
        case .word(let inner, let big):
            return word(cursor, count, include: !inner, big: big, anchor: nil, b)
        case .sentence(let inner): return sentence(cursor, count, include: !inner, b)
        case .paragraph(let inner): return paragraph(cursor, count, include: !inner, b)
        case .quote(let quote, let inner):
            return self.quote(quote, cursor, count, include: !inner, b)
        case .block(let open, let close, let inner):
            return block(open, close, cursor, count, include: !inner, b)
        }
    }

    /// The selection after a text object typed in Visual mode, which selects the object
    /// when the selection is one character and otherwise extends it, or nil when Vim fails.
    static func findVisual(_ object: TextObject, count: Int, anchor: Int, cursor: Int,
                           mode: VimMode, in b: VimBuffer) -> VisualObjectSelection? {
        let charwise: VimMode = mode == .visualLine ? .visual : mode
        switch object {
        case .word(let inner, let big):
            return word(cursor, count, include: !inner, big: big, anchor: anchor, b).map {
                VisualObjectSelection(anchor: $0.start, cursor: $0.end, mode: charwise)
            }
        case .sentence(let inner):
            return visualSentence(anchor, cursor, count, include: !inner, mode, b)
        case .paragraph(let inner):
            return visualParagraph(anchor, cursor, count, include: !inner, mode, b)
        case .quote(let quote, let inner):
            return visualQuote(quote, anchor, cursor, count, include: !inner, b).map {
                VisualObjectSelection(anchor: $0.anchor, cursor: $0.cursor, mode: charwise)
            }
        case .block(let open, let close, let inner):
            return visualBlock(open, close, anchor, cursor, count, include: !inner, b)
        }
    }

    // MARK: Words

    /// With an `anchor`, Visual mode: a selection of one character selects the word, and a
    /// longer one grows by `count` words at the cursor's end.
    private static func word(_ cursor: Int, _ count: Int, include: Bool, big: Bool,
                             anchor: Int?, _ b: VimBuffer) -> TextObjectRange? {
        var start = anchor ?? cursor
        var p = cursor
        var remaining = count
        var inclusive = true
        var includeWhite = false
        if anchor == nil || anchor == cursor {
            start = backInLine(cursor, big, b)
            p = start
            if (b.wordClass(p, big) == .blank) == include {
                guard Motions.endWord(&p, 1, big: big, stop: true, empty: true, b) else {
                    return nil
                }
            } else {
                _ = Motions.fwdWord(&p, 1, big: big, eol: true, b)
                if b.isLineStart(p) { _ = b.decl(&p) } else { _ = oneLeft(&p, b) }
                includeWhite = include
            }
            remaining -= 1
        }
        while remaining > 0 {
            inclusive = true
            let grown = anchor != nil && p < start
                ? wordBackward(&p, include: include, big: big, b)
                : wordForward(&p, include: include, big: big, last: remaining == 1, &inclusive, b)
            guard grown else { return nil }
            remaining -= 1
        }
        if includeWhite && (b.wordClass(p, big) != .blank || (b.isLineStart(p) && !inclusive)) {
            var before = start
            if oneLeft(&before, b) {
                before = backInLine(before, big, b)
                if b.wordClass(before, big) == .blank && !b.isLineStart(before) { start = before }
            }
        }
        return TextObjectRange(start: start, end: p, kind: inclusive ? .inclusive : .exclusive)
    }

    /// One more word or run of blanks after `p`. False when Vim's `current_word` fails.
    private static func wordForward(_ p: inout Int, include: Bool, big: Bool, last: Bool,
                                    _ inclusive: inout Bool, _ b: VimBuffer) -> Bool {
        guard b.incl(&p) != -1 else { return false }
        guard include != (b.wordClass(p, big) == .blank) else {
            return Motions.endWord(&p, 1, big: big, stop: true, empty: true, b)
        }
        if !Motions.fwdWord(&p, 1, big: big, eol: true, b) && !last { return false }
        if !oneLeft(&p, b) { inclusive = false }
        return true
    }

    /// One more word or run of blanks before `p`, when the cursor is at the selection's start.
    private static func wordBackward(_ p: inout Int, include: Bool, big: Bool,
                                     _ b: VimBuffer) -> Bool {
        guard b.decl(&p) != -1 else { return false }
        if include != (b.wordClass(p, big) != .blank) {
            return Motions.backWord(&p, 1, big: big, stop: true, b)
        }
        guard Motions.backWordEnd(&p, 1, big: big, eol: true, b) else { return false }
        _ = b.incl(&p)
        return true
    }

    /// Vim's `back_in_line`: the start of the word or run of blanks under `offset`.
    private static func backInLine(_ offset: Int, _ big: Bool, _ b: VimBuffer) -> Int {
        let startClass = b.wordClass(offset, big)
        var p = offset
        while !b.isLineStart(p) {
            var before = p
            _ = b.dec(&before)
            if b.wordClass(before, big) != startClass { break }
            p = before
        }
        return p
    }

    private static func oneLeft(_ p: inout Int, _ b: VimBuffer) -> Bool {
        guard !b.isLineStart(p), let previous = b.previousGrapheme(before: p) else { return false }
        p = previous
        return true
    }

    // MARK: Sentences

    private static func isWhite(_ unit: UInt16) -> Bool { unit == 0x20 || unit == 0x09 }

    private static func sentence(_ cursor: Int, _ count: Int, include: Bool,
                                 _ b: VimBuffer) -> TextObjectRange? {
        var start = cursor
        var pos = cursor
        var end = Motions.findSentence(forward: true, 1, from: cursor, b) ?? cursor
        while isWhite(b.unit(at: pos)) { _ = b.incl(&pos) }
        let startBlank = pos == end
        if startBlank {
            firstBlank(&start, b)
        } else {
            end = Motions.findSentence(forward: false, 1, from: end, b) ?? end
            start = end
        }
        let sentences = include ? count * 2 : count - (startBlank ? 1 : 0)
        if sentences > 0 {
            forwardSentences(&end, sentences, atStart: true, b)
        } else {
            _ = b.decl(&end)
        }
        if include {
            if startBlank {
                firstBlank(&end, b)
                if isWhite(b.unit(at: end)) { _ = b.decl(&end) }
            } else if !isWhite(b.unit(at: end)) {
                firstBlank(&start, b)
            }
        }
        let inclusive = b.incl(&end) == -1
        return TextObjectRange(start: start, end: end, kind: inclusive ? .inclusive : .exclusive)
    }

    /// Vim's `find_first_blank`: back over the blanks before `pos`.
    private static func firstBlank(_ pos: inout Int, _ b: VimBuffer) {
        while b.decl(&pos) != -1 {
            if !isWhite(b.unit(at: pos)) {
                _ = b.incl(&pos)
                break
            }
        }
    }

    /// Vim's `findsent_forward`: `count` halves, each a sentence or the blanks after it.
    private static func forwardSentences(_ pos: inout Int, _ count: Int, atStart: Bool,
                                         _ b: VimBuffer) {
        var atStart = atStart
        for remaining in stride(from: count - 1, through: 0, by: -1) {
            pos = Motions.findSentence(forward: true, 1, from: pos, b) ?? pos
            if atStart { firstBlank(&pos, b) }
            if remaining == 0 || atStart { _ = b.decl(&pos) }
            atStart.toggle()
        }
    }

    // MARK: Paragraphs

    private static func paragraph(_ cursor: Int, _ count: Int, include: Bool,
                                  _ b: VimBuffer) -> TextObjectRange? {
        let last = b.lineCount - 1
        var startLine = b.lineIndex(of: cursor)
        let whiteInFront = b.isBlankLine(startLine)
        while startLine > 0 {
            if whiteInFront ? !b.isBlankLine(startLine - 1)
                : b.isBlankLine(startLine - 1) || b.startsParagraph(startLine) {
                break
            }
            startLine -= 1
        }
        var endLine = startLine
        while endLine <= last && b.isBlankLine(endLine) { endLine += 1 }
        endLine -= 1
        var remaining = count - (!include && whiteInFront ? 1 : 0)
        while remaining > 0 {
            remaining -= 1
            guard endLine < last else { return nil }
            let doWhite = !include && b.isBlankLine(endLine + 1)
            if include || !doWhite {
                endLine += 1
                while endLine < last && !b.isBlankLine(endLine + 1)
                        && !b.startsParagraph(endLine + 1) {
                    endLine += 1
                }
            }
            if remaining == 0 && whiteInFront && include { break }
            if include || doWhite {
                while endLine < last && b.isBlankLine(endLine + 1) { endLine += 1 }
            }
        }
        if !whiteInFront && !b.isBlankLine(endLine) && include {
            while startLine > 0 && b.isBlankLine(startLine - 1) { startLine -= 1 }
        }
        return TextObjectRange(start: b.lineStart(startLine), end: b.lineStart(endLine),
                               kind: .linewise)
    }

    // MARK: Quotes

    private static let backslash: UInt16 = 0x5C

    /// Within the cursor's line only, as in Vim. A quote after a backslash does not count.
    private static func quote(_ quote: UInt16, _ cursor: Int, _ count: Int, include: Bool,
                              _ b: VimBuffer) -> TextObjectRange? {
        let (lineStart, unit) = lineUnits(cursor, b)
        let cursorColumn = cursor - lineStart
        var start: Int
        var end: Int
        if unit(cursorColumn) == quote {
            start = 0
            while true {
                start = nextQuote(unit, from: start, quote, escaped: false)
                guard start >= 0, start <= cursorColumn else { return nil }
                end = nextQuote(unit, from: start + 1, quote, escaped: true)
                guard end >= 0 else { return nil }
                if cursorColumn <= end { break }
                start = end + 1
            }
        } else {
            start = previousQuote(unit, from: cursorColumn, quote)
            if unit(start) != quote {
                start = nextQuote(unit, from: start, quote, escaped: false)
                guard start >= 0 else { return nil }
            }
            end = nextQuote(unit, from: start + 1, quote, escaped: true)
            guard end >= 0 else { return nil }
        }
        if include {
            if isWhite(unit(end + 1)) {
                while isWhite(unit(end + 1)) { end += 1 }
            } else {
                while start > 0 && isWhite(unit(start - 1)) { start -= 1 }
            }
        }
        if !include && count < 2 { start += 1 }
        let kind: MotionKind = include || count > 1 ? .inclusive : .exclusive
        return TextObjectRange(start: lineStart + start, end: lineStart + end, kind: kind)
    }

    /// The start of `offset`'s line and its UTF-16 units by column, 0 past its end as
    /// Vim's NUL.
    private static func lineUnits(_ offset: Int, _ b: VimBuffer) -> (Int, (Int) -> UInt16) {
        let lineStart = b.lineStart(b.lineIndex(of: offset))
        let length = b.contentEnd(b.lineIndex(of: offset)) - lineStart
        return (lineStart, { $0 >= 0 && $0 < length ? b.text.character(at: lineStart + $0) : 0 })
    }

    /// Vim's `find_next_quote`: the column of the next quote, or -1.
    private static func nextQuote(_ unit: (Int) -> UInt16, from column: Int, _ quote: UInt16,
                                  escaped: Bool) -> Int {
        var column = column
        while true {
            let c = unit(column)
            if c == 0 { return -1 }
            if escaped && c == backslash {
                column += 1
                if unit(column) == 0 { return -1 }
            } else if c == quote {
                return column
            }
            column += 1
        }
    }

    /// Vim's `find_prev_quote`: the column of the quote before `column`, skipping quotes
    /// after an odd number of backslashes, or 0.
    private static func previousQuote(_ unit: (Int) -> UInt16, from column: Int,
                                      _ quote: UInt16) -> Int {
        var column = column
        while column > 0 {
            column -= 1
            var backslashes = 0
            while column - backslashes > 0 && unit(column - backslashes - 1) == backslash {
                backslashes += 1
            }
            if backslashes % 2 == 1 {
                column -= backslashes
            } else if unit(column) == quote {
                break
            }
        }
        return column
    }

    // MARK: Blocks

    private static func block(_ open: UInt16, _ close: UInt16, _ cursor: Int, _ count: Int,
                              include: Bool, _ b: VimBuffer) -> TextObjectRange? {
        var pos = cursor
        if open == 0x7B {
            while inIndent(pos, extra: 1, b) {
                if b.inc(&pos) != 0 { break }
            }
        }
        if pos < b.length && b.text.character(at: pos) == open { pos += 1 }
        guard var begin = openingBracket(open, close, from: pos, count, b),
              var end = unmatched(close, from: begin, opening: open, closing: close, b)
        else { return nil }
        var startOfLine = false
        if !include {
            _ = b.incl(&begin)
            startOfLine = b.isLineStart(end)
            _ = b.decl(&end)
            while inIndent(end, extra: 1, b) {
                startOfLine = true
                if b.decl(&end) != 0 { break }
            }
        }
        if startOfLine {
            _ = b.incl(&end)
            return TextObjectRange(start: begin, end: end, kind: .exclusive)
        }
        if begin <= end { return TextObjectRange(start: begin, end: end, kind: .inclusive) }
        return TextObjectRange(start: begin, end: begin, kind: .exclusive)
    }

    /// The `count`th unmatched `open` before `pos`, or when `pos` is in no block, the
    /// `count`th one after it.
    private static func openingBracket(_ open: UInt16, _ close: UInt16, from pos: Int,
                                       _ count: Int, _ b: VimBuffer) -> Int? {
        var start: Int?
        let enclosing = unmatched(open, from: pos, opening: open, closing: close, b) != nil
        for _ in 0..<count {
            let found = enclosing
                ? unmatched(open, from: start ?? pos, opening: open, closing: close, b)
                : nextOpening(from: start ?? pos, open, close, b)
            guard let found else { return nil }
            start = found
        }
        return start
    }

    /// Vim's `inindent`: only blanks come before `pos` on its line, and `extra` more.
    private static func inIndent(_ pos: Int, extra: Int, _ b: VimBuffer) -> Bool {
        let line = b.lineIndex(of: pos)
        return b.firstNonBlank(line: line) - b.lineStart(line) >= pos - b.lineStart(line) + extra
    }

    /// Vim's `findmatch` for an unmatched `target` bracket, searching back from `pos` for an
    /// opening one and forward for a closing one. Quotes do not count, as with `%` in
    /// `cpoptions`; a bracket after an odd number of backslashes is skipped.
    private static func unmatched(_ target: UInt16, from pos: Int, opening: UInt16,
                                  closing: UInt16, _ b: VimBuffer) -> Int? {
        let backward = target == opening
        let other = backward ? closing : opening
        var depth = 0
        var offset = pos
        while true {
            offset += backward ? -1 : 1
            guard offset >= 0, offset < b.length else { return nil }
            let unit = b.text.character(at: offset)
            guard unit == target || unit == other, !isEscaped(offset, b) else { continue }
            if unit == other {
                depth += 1
            } else if depth == 0 {
                return offset
            } else {
                depth -= 1
            }
        }
    }

    /// Vim's forward `findmatchlimit` for an opening bracket after the cursor, used when the
    /// cursor is in no block.
    private static func nextOpening(from pos: Int, _ open: UInt16, _ close: UInt16,
                                    _ b: VimBuffer) -> Int? {
        var depth = 0
        var offset = pos
        while offset + 1 < b.length {
            offset += 1
            let unit = b.text.character(at: offset)
            guard unit == open || unit == close, !isEscaped(offset, b) else { continue }
            if unit == close {
                depth += 1
            } else if depth == 0 {
                return offset
            } else {
                depth -= 1
            }
        }
        return nil
    }

    private static func isEscaped(_ offset: Int, _ b: VimBuffer) -> Bool {
        var backslashes = 0
        let lineStart = b.lineStart(b.lineIndex(of: offset))
        while offset - backslashes > lineStart
                && b.text.character(at: offset - backslashes - 1) == backslash {
            backslashes += 1
        }
        return backslashes % 2 == 1
    }

    // MARK: Visual mode

    /// `current_sent` in Visual mode. A selection of one character selects sentences from
    /// the cursor; a longer one grows at the cursor's end (Vim's `extend` label).
    private static func visualSentence(_ anchor: Int, _ cursor: Int, _ count: Int,
                                       include: Bool, _ mode: VimMode,
                                       _ b: VimBuffer) -> VisualObjectSelection? {
        guard anchor == cursor else {
            let next = Motions.findSentence(forward: true, 1, from: cursor, b) ?? cursor
            return extendSentences(cursor, next, anchor, count, include: include, mode, b)
        }
        guard let found = sentence(cursor, count, include: include, b) else { return nil }
        var end = found.end
        if found.kind == .exclusive { _ = b.decl(&end) }
        guard found.start != end else {
            return extendSentences(found.start, end, anchor, count, include: include, mode, b)
        }
        return VisualObjectSelection(anchor: found.start, cursor: end, mode: .visual)
    }

    private static func extendSentences(_ start: Int, _ current: Int, _ anchor: Int,
                                        _ count: Int, include: Bool, _ mode: VimMode,
                                        _ b: VimBuffer) -> VisualObjectSelection {
        let back: (Int) -> Int = { Motions.findSentence(forward: false, 1, from: $0, b) ?? $0 }
        var cursor = current
        var pos = start
        var atStart: Bool
        if start < anchor {
            atStart = onlyBlanks(from: &pos, before: cursor, b)
            if !atStart {
                cursor = back(cursor)
                if cursor == start {
                    atStart = true
                } else {
                    cursor = Motions.findSentence(forward: true, 1, from: cursor, b) ?? cursor
                }
            }
            for _ in 0..<(include ? count * 2 : count) {
                if atStart { firstBlank(&cursor, b) }
                if !atStart || (!include && !isWhite(b.unit(at: cursor))) { cursor = back(cursor) }
                atStart.toggle()
            }
        } else {
            _ = b.incl(&pos)
            atStart = true
            if pos != cursor {
                atStart = !onlyBlanks(from: &pos, before: cursor, b)
                cursor = atStart ? back(cursor) : start
            }
            forwardSentences(&cursor, include ? count * 2 : count, atStart: atStart, b)
        }
        return VisualObjectSelection(anchor: anchor, cursor: cursor, mode: mode)
    }

    /// Whether only blanks lie from `pos` up to `end`, moving `pos` past them.
    private static func onlyBlanks(from pos: inout Int, before end: Int, _ b: VimBuffer) -> Bool {
        while pos < end {
            if !isWhite(b.unit(at: pos)) { return false }
            if b.incl(&pos) == -1 { break }
        }
        return true
    }

    /// `current_par` in Visual mode: a selection within one line selects paragraphs as lines;
    /// a longer one grows by paragraphs at the cursor's end.
    private static func visualParagraph(_ anchor: Int, _ cursor: Int, _ count: Int,
                                        include: Bool, _ mode: VimMode,
                                        _ b: VimBuffer) -> VisualObjectSelection? {
        let anchorLine = b.lineIndex(of: anchor)
        var line = b.lineIndex(of: cursor)
        if anchorLine == line {
            guard let found = paragraph(cursor, count, include: include, b) else { return nil }
            let first = b.lineIndex(of: found.start)
            if mode != .visualLine || first != line {
                return VisualObjectSelection(anchor: anchorLine == first ? anchor : found.start,
                                             cursor: found.end, mode: .visualLine)
            }
            line = first
        }
        let direction = line < anchorLine ? -1 : 1
        let edge = direction < 0 ? 0 : b.lineCount - 1
        for _ in 0..<count {
            guard line != edge else { return nil }
            line = nextParagraphEdge(from: line, direction, edge: edge, include: include, b)
        }
        return VisualObjectSelection(anchor: anchor, cursor: b.lineStart(line), mode: mode)
    }

    /// One paragraph or run of blank lines past `line`, and with `include` the run after it.
    private static func nextParagraphEdge(from line: Int, _ direction: Int, edge: Int,
                                          include: Bool, _ b: VimBuffer) -> Int {
        var line = line
        var previousBlank: Bool?
        for _ in 0..<2 {
            line += direction
            let blank = b.isBlankLine(line)
            if previousBlank == blank { return line - direction }
            while line != edge, b.isBlankLine(line + direction) == blank,
                  blank || !b.startsParagraph(line + (direction > 0 ? 1 : 0)) {
                line += direction
            }
            if !include || line == edge { break }
            previousBlank = blank
        }
        return line
    }

    /// `current_block` in Visual mode. When `i(` would not grow the selection, it takes the
    /// block around it instead. A block whose end is alone on its line takes the line break.
    private static func visualBlock(_ open: UInt16, _ close: UInt16, _ anchor: Int,
                                    _ cursor: Int, _ count: Int, include: Bool,
                                    _ b: VimBuffer) -> VisualObjectSelection? {
        var oldStart = cursor
        var oldEnd = cursor
        var pos = cursor
        if anchor == cursor {
            if open == 0x7B {
                while inIndent(pos, extra: 1, b) {
                    if b.inc(&pos) != 0 { break }
                }
            }
            if pos < b.length && b.text.character(at: pos) == open { pos += 1 }
        } else if anchor < cursor {
            oldStart = anchor
            pos = anchor
        } else {
            oldEnd = anchor
        }
        guard var begin = openingBracket(open, close, from: pos, count, b),
              var end = unmatched(close, from: begin, opening: open, closing: close, b)
        else { return nil }
        var startOfLine = false
        while !include {
            _ = b.incl(&begin)
            startOfLine = b.isLineStart(end)
            _ = b.decl(&end)
            while inIndent(end, extra: 1, b) {
                startOfLine = true
                if b.decl(&end) != 0 { break }
            }
            guard begin >= oldStart, oldEnd >= end, begin != end else { break }
            var before = oldStart
            _ = b.decl(&before)
            guard let outer = unmatched(open, from: before, opening: open, closing: close, b),
                  let outerEnd = unmatched(close, from: outer, opening: open, closing: close, b)
            else { return nil }
            (begin, end) = (outer, outerEnd)
        }
        if startOfLine && !b.isLineEnd(end) { _ = b.inc(&end) }
        return VisualObjectSelection(anchor: begin, cursor: end, mode: .visual)
    }

    /// `current_quote` in Visual mode, within the cursor's line. Typed again on a selection
    /// that spans a string's inside, `i"` takes the quotes and `a"` the next string.
    private static func visualQuote(_ quote: UInt16, _ anchor: Int, _ cursor: Int,
                                    _ count: Int, include: Bool,
                                    _ b: VimBuffer) -> (anchor: Int, cursor: Int)? {
        guard b.lineIndex(of: anchor) == b.lineIndex(of: cursor) else { return nil }
        let (lineStart, unit) = lineUnits(cursor, b)
        let cursorColumn = cursor - lineStart
        let anchorColumn = anchor - lineStart
        let selection = QuoteSelection(anchor: anchorColumn, cursor: cursorColumn, quote, unit)
        guard var (start, end) = quoteColumns(selection, quote, unit) else { return nil }
        if include {
            if isWhite(unit(end + 1)) {
                while isWhite(unit(end + 1)) { end += 1 }
            } else {
                while start > 0 && isWhite(unit(start - 1)) { start -= 1 }
            }
        }
        if !include && count < 2 && (selection.isEmpty || !selection.insideQuotes) { start += 1 }
        let keepsEnd = include || count > 1 || (!selection.isEmpty && selection.insideQuotes)
        let last = keepsEnd ? end : end - 1
        var newAnchor = anchorColumn
        var newCursor = last
        if selection.isEmpty || selection.cursorAfterAnchor {
            if selection.isEmpty || selection.movesAnchor(quote, unit) { newAnchor = start }
        } else {
            if selection.insideQuotes || selection.keepsAnchorAtQuote(quote, unit) {
                newAnchor = last
            }
            newCursor = start
        }
        return (lineStart + newAnchor, lineStart + newCursor)
    }

    /// The quotes around the string `visualQuote` selects: the next or previous string when
    /// the selection already ends on a quote, otherwise the string around it.
    private static func quoteColumns(_ selection: QuoteSelection, _ quote: UInt16,
                                     _ unit: (Int) -> UInt16) -> (Int, Int)? {
        let column = selection.cursor
        if !selection.isEmpty && unit(column) == quote {
            return selection.cursorAfterAnchor ? nextString(after: column, quote, unit)
                : previousString(before: column, quote, unit)
        }
        guard unit(column) == quote || !selection.isEmpty else {
            var start = previousQuote(unit, from: column, quote)
            if unit(start) != quote {
                start = nextQuote(unit, from: start, quote, escaped: false)
                guard start >= 0 else { return nil }
            }
            let end = nextQuote(unit, from: start + 1, quote, escaped: true)
            return end >= 0 ? (start, end) : nil
        }
        var first = column
        if !selection.isEmpty {
            first = selection.cursorAfterAnchor
                ? nextQuote(unit, from: column, quote, escaped: false)
                : previousQuote(unit, from: column, quote)
        }
        var start = 0
        while true {
            start = nextQuote(unit, from: start, quote, escaped: false)
            guard start >= 0, start <= first else { return nil }
            let end = nextQuote(unit, from: start + 1, quote, escaped: true)
            guard end >= 0 else { return nil }
            if first <= end { return (start, end) }
            start = end + 1
        }
    }

    private static func nextString(after column: Int, _ quote: UInt16,
                                   _ unit: (Int) -> UInt16) -> (Int, Int)? {
        let start = nextQuote(unit, from: column + 1, quote, escaped: false)
        guard start >= 0 else { return nil }
        let end = nextQuote(unit, from: start + 1, quote, escaped: true)
        return end < 0 ? (column, start) : (start, end)
    }

    private static func previousString(before column: Int, _ quote: UInt16,
                                       _ unit: (Int) -> UInt16) -> (Int, Int)? {
        let end = previousQuote(unit, from: column, quote)
        guard unit(end) == quote else { return nil }
        let start = previousQuote(unit, from: end, quote)
        return unit(start) == quote ? (start, end) : (end, column)
    }
}
