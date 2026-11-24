import Foundation

/// A read-only view of the text for the Vim engine. Offsets are UTF-16 offsets into the
/// `NSString`, which is retained rather than copied.
///
/// A line is an `NSString` logical line: it ends at LF, CRLF, CR, U+2028, U+2029 or U+0085.
/// Like a text view, the buffer has a final empty line when the text is empty or ends with a
/// line break, so every offset from 0 through `length` belongs to exactly one line.
public struct VimBuffer {
    public enum WordClass: Equatable {
        case blank, word, punctuation
    }

    public let text: NSString
    private let lineStarts: [Int]

    public init(_ text: NSString) {
        self.text = text
        var starts = [0]
        var position = 0
        while position < text.length {
            var end = 0
            text.getLineStart(nil, end: &end, contentsEnd: nil,
                              for: NSRange(location: position, length: 0))
            position = end
            starts.append(end)
        }
        if text.length > 0 && !Self.endsWithBreak(text) { starts.removeLast() }
        lineStarts = starts
    }

    private static func endsWithBreak(_ text: NSString) -> Bool {
        var contentsEnd = 0
        var end = 0
        text.getLineStart(nil, end: &end, contentsEnd: &contentsEnd,
                          for: NSRange(location: text.length - 1, length: 0))
        return contentsEnd < end
    }

    public var length: Int { text.length }
    public var lineCount: Int { lineStarts.count }

    /// The line holding `offset`, which is clamped to `0...length`.
    public func lineIndex(of offset: Int) -> Int {
        let target = min(max(offset, 0), length)
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lineStarts[middle] <= target { low = middle } else { high = middle - 1 }
        }
        return low
    }

    /// The line including its line break.
    public func lineRange(at line: Int) -> NSRange {
        let start = lineStarts[line]
        let end = line + 1 < lineStarts.count ? lineStarts[line + 1] : length
        return NSRange(location: start, length: end - start)
    }

    /// The line without its line break.
    public func contentRange(at line: Int) -> NSRange {
        let range = lineRange(at: line)
        guard range.length > 0 else { return range }
        var contentsEnd = 0
        text.getLineStart(nil, end: nil, contentsEnd: &contentsEnd,
                          for: NSRange(location: range.location, length: 0))
        return NSRange(location: range.location, length: contentsEnd - range.location)
    }

    /// The offset after the grapheme cluster that starts at `offset`, or nil at the end.
    public func nextGrapheme(after offset: Int) -> Int? {
        guard offset >= 0, offset < length else { return nil }
        if isCRLF(at: offset) { return offset + 2 }
        return NSMaxRange(text.rangeOfComposedCharacterSequence(at: offset))
    }

    /// The offset where the grapheme cluster ending at `offset` starts, or nil at 0.
    public func previousGrapheme(before offset: Int) -> Int? {
        guard offset > 0, offset <= length else { return nil }
        if isCRLF(at: offset - 2) { return offset - 2 }
        return text.rangeOfComposedCharacterSequence(at: offset - 1).location
    }

    /// `NSString` treats CR and LF as separate clusters, but Vim sees one line break.
    private func isCRLF(at offset: Int) -> Bool {
        offset >= 0 && offset + 1 < length
            && text.character(at: offset) == 0x0D && text.character(at: offset + 1) == 0x0A
    }

    /// The first character of the line that is not a space or tab. A blank line gives the
    /// end of its content.
    public func firstNonBlank(line: Int) -> Int {
        let content = contentRange(at: line)
        var offset = content.location
        while offset < NSMaxRange(content) {
            let unit = text.character(at: offset)
            if unit != 0x20 && unit != 0x09 { return offset }
            offset += 1
        }
        return offset
    }

    /// The screen column of `offset` within its line: a tab reaches the next multiple of
    /// `tabstop` and every other grapheme is one column.
    public func displayColumn(of offset: Int, tabstop: Int) -> Int {
        let line = lineIndex(of: offset)
        var column = 0
        var position = lineRange(at: line).location
        while position < offset, let next = nextGrapheme(after: position) {
            column = advance(column, past: position, tabstop: tabstop)
            position = next
        }
        return column
    }

    /// The offset of the grapheme that covers `displayColumn` on `line`, or the end of the
    /// line's content when the line is shorter.
    public func offset(line: Int, displayColumn: Int, tabstop: Int) -> Int {
        let content = contentRange(at: line)
        var column = 0
        var position = content.location
        while position < NSMaxRange(content), let next = nextGrapheme(after: position) {
            let after = advance(column, past: position, tabstop: tabstop)
            if displayColumn < after { return position }
            column = after
            position = next
        }
        return NSMaxRange(content)
    }

    private func advance(_ column: Int, past position: Int, tabstop: Int) -> Int {
        guard text.character(at: position) == 0x09 else { return column + 1 }
        return (column / tabstop + 1) * tabstop
    }

    /// The Vim character class of the grapheme at `offset`. With `bigWord`, every non-blank
    /// grapheme is `.word`. The end of the text is `.blank`.
    public func wordClass(at offset: Int, bigWord: Bool) -> WordClass {
        guard let end = nextGrapheme(after: offset),
              let character = text.substring(with: NSRange(location: offset, length: end - offset))
                  .first
        else { return .blank }
        if character.isWhitespace { return .blank }
        if bigWord { return .word }
        return character.isLetter || character.isNumber || character == "_" ? .word : .punctuation
    }
}
