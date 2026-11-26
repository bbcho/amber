import Foundation

/// A read-only view of the text for the Vim engine. Offsets are UTF-16 offsets into the
/// `NSString`, which is retained rather than copied.
///
/// A line is an `NSString` logical line: it ends at LF, CRLF, CR, U+2028, U+2029 or U+0085.
/// As in Vim, a final line break ends the last line rather than starting another, and empty
/// text is one empty line. An offset at the very end belongs to the last line.
public struct VimBuffer {
    public enum WordClass: Equatable {
        case blank, word, punctuation
        /// Vim gives emoji a class of their own, so `w` stops before and after a run of them.
        case emoji
        /// A script Vim gives a class of its own, named by Vim's class number: 0x3040
        /// Hiragana, 0x30A0 Katakana, 0x4E00 CJK ideographs, 0xAC00 Hangul, 0x2800 Braille.
        case script(Int)
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
        if text.length > 0 { starts.removeLast() }
        lineStarts = starts
    }

    private init(text: NSString, lineStarts: [Int]) {
        self.text = text
        self.lineStarts = lineStarts
    }

    /// The buffer of the text after `edit`. Only the lines the edit touches are scanned, plus
    /// the line before it, which a carriage return there may join to a new line feed; the
    /// later lines keep their breaks and move by the edit's length change.
    public func applying(_ edit: TextEdit) -> VimBuffer {
        let start = edit.range.location
        let end = NSMaxRange(edit.range)
        let changed = text.mutableCopy() as! NSMutableString
        changed.replaceCharacters(in: edit.range, with: edit.replacement)
        let delta = changed.length - length
        let firstLine = lineIndex(of: max(start - 1, 0))
        let lastLine = lineIndex(of: end)
        let regionStart = lineStarts[firstLine]
        let regionEnd = NSMaxRange(lineRange(at: lastLine)) + delta
        var starts = Array(lineStarts[..<firstLine])
        var position = regionStart
        while position < regionEnd {
            starts.append(position)
            var next = 0
            changed.getLineStart(nil, end: &next, contentsEnd: nil,
                                 for: NSRange(location: position, length: 0))
            position = next
        }
        guard position == regionEnd else { return VimBuffer(changed) }
        starts += lineStarts[(lastLine + 1)...].map { $0 + delta }
        return VimBuffer(text: changed, lineStarts: changed.length == 0 ? [0] : starts)
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
        // Nothing below U+0300 extends a cluster, so an ASCII character followed by one is
        // a whole cluster. This keeps walks along a very long line fast.
        if text.character(at: offset) < 0x80,
           offset + 1 == length || text.character(at: offset + 1) < 0x300 {
            return offset + 1
        }
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
        var chunk = [unichar](repeating: 0, count: Self.chunkLength + 1)
        while position < offset {
            // Printable ASCII and tabs are one grapheme each unless a combining character
            // follows, so they are counted from a copied chunk; anything else takes the
            // grapheme walk, one cluster at a time.
            let wanted = min(Self.chunkLength, offset - position)
            let available = min(wanted + 1, length - position)
            text.getCharacters(&chunk, range: NSRange(location: position, length: available))
            var index = 0
            while index < wanted, chunk[index] == 0x09 || (0x20..<0x80).contains(chunk[index]),
                  index + 1 == available || chunk[index + 1] < 0x300 {
                column = chunk[index] == 0x09 ? (column / tabstop + 1) * tabstop : column + 1
                index += 1
            }
            position += index
            if index < wanted, let next = nextGrapheme(after: position) {
                column = advance(column, past: position, tabstop: tabstop)
                position = next
            } else if index < wanted {
                break
            }
        }
        return column
    }

    private static let chunkLength = 256

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

    /// The Vim character class of the grapheme at `offset`, from its first code point as
    /// Vim classifies it. With `bigWord`, every non-blank grapheme is `.word`. Line breaks
    /// and the end of the text are `.blank`.
    public func wordClass(at offset: Int, bigWord: Bool) -> WordClass {
        guard let end = nextGrapheme(after: offset),
              let character = text.substring(with: NSRange(location: offset, length: end - offset))
                  .first,
              !character.isNewline, let scalar = character.unicodeScalars.first
        else { return .blank }
        let vimClass = VimCharacterClasses.vimClass(of: scalar)
        if vimClass == 0 { return .blank }
        if bigWord { return .word }
        switch vimClass {
        case 1: return .punctuation
        case 2: return .word
        case 3: return .emoji
        default: return .script(vimClass)
        }
    }
}
