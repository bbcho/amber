import Foundation

/// The text as lines while one ex command runs, so that `:g` can run many commands without
/// rebuilding the text. Lines keep their own line breaks, new lines take the document's,
/// and `edit()` gives the whole run as one replacement of the lines that changed.
///
/// The lines live in `storage` and `order` lists them by index, so that removing, inserting
/// and moving lines shifts only integers.
struct ExLines {
    struct Line {
        var content: String
        /// Empty only on a last line that has no line break.
        var lineBreak: String
        /// Set by `:g` on the lines it has still to visit.
        var marked = false
    }

    let original: VimBuffer
    /// The break that new lines take.
    let lineBreak: String
    private var storage: [Line]
    private var order: [Int]
    /// The first line that changed, and how many lines at the end never did.
    private var firstChanged: Int?
    private var unchangedSuffix: Int
    /// No marked line comes before this one. Like Vim's `lowest_marked`, it moves with the
    /// lines removed and inserted before it.
    private var markSearchStart = 0

    init(_ buffer: VimBuffer) {
        original = buffer
        lineBreak = buffer.lineBreak(near: 0)
        storage = (0..<buffer.lineCount).map { line in
            let content = buffer.contentRange(at: line)
            let end = NSMaxRange(buffer.lineRange(at: line))
            return Line(content: buffer.substring(content),
                        lineBreak: buffer.substring(NSMaxRange(content)..<end))
        }
        order = Array(storage.indices)
        unchangedSuffix = order.count
    }

    var count: Int { order.count }

    func line(_ index: Int) -> Line { storage[order[index]] }

    func content(_ index: Int) -> String { line(index).content }

    private mutating func modify(_ index: Int, _ change: (inout Line) -> Void) {
        change(&storage[order[index]])
    }

    private mutating func touch(_ index: Int, linesAfter: Int) {
        firstChanged = min(firstChanged ?? index, index)
        unchangedSuffix = min(unchangedSuffix, linesAfter)
    }

    mutating func mark(_ index: Int) {
        modify(index) { $0.marked = true }
        markSearchStart = min(markSearchStart, index)
    }

    /// The first marked line, which is then no longer marked.
    mutating func takeFirstMarked() -> Int? {
        guard let found = (markSearchStart..<count).first(where: { line($0).marked }) else {
            markSearchStart = count
            return nil
        }
        modify(found) { $0.marked = false }
        markSearchStart = found + 1
        return found
    }

    mutating func replace(_ index: Int, with content: String) {
        guard content != self.content(index) else { return }
        modify(index) { $0.content = content }
        touch(index, linesAfter: count - 1 - index)
    }

    /// Removes lines. Removing the last line takes the line break off the new last line
    /// when the removed one had none, and removing every line leaves one empty line.
    mutating func remove(_ lines: Range<Int>) {
        guard !lines.isEmpty else { return }
        let lastHadBreak = !line(count - 1).lineBreak.isEmpty
        order.removeSubrange(lines)
        markSearchStart -= max(min(lines.upperBound, markSearchStart) - lines.lowerBound, 0)
        if order.isEmpty {
            storage.append(Line(content: "", lineBreak: ""))
            order = [storage.count - 1]
            touch(0, linesAfter: 0)
            return
        }
        if lines.lowerBound == count && !lastHadBreak {
            modify(count - 1) { $0.lineBreak = "" }
            touch(count - 1, linesAfter: 0)
        }
        touch(min(lines.lowerBound, count - 1), linesAfter: count - lines.lowerBound)
    }

    /// Inserts lines before `index`; at `count`, after the last line, which then gets a line
    /// break if it had none.
    mutating func insert(_ contents: [String], at index: Int) {
        guard !contents.isEmpty else { return }
        var appendsToUnbrokenEnd = false
        if index == count, line(count - 1).lineBreak.isEmpty {
            let lineBreak = self.lineBreak
            modify(count - 1) { $0.lineBreak = lineBreak }
            touch(count - 1, linesAfter: 0)
            appendsToUnbrokenEnd = true
        }
        let first = storage.count
        storage += contents.map { Line(content: $0, lineBreak: lineBreak) }
        if appendsToUnbrokenEnd { storage[storage.count - 1].lineBreak = "" }
        order.insert(contentsOf: first..<storage.count, at: index)
        if index <= markSearchStart { markSearchStart += contents.count }
        touch(index, linesAfter: count - index - contents.count)
    }

    /// Gives `lines` the new contents, keeping the breaks of the lines that remain.
    mutating func replace(_ lines: Range<Int>, with contents: [String]) {
        let kept = min(lines.count, contents.count)
        for offset in 0..<kept { replace(lines.lowerBound + offset, with: contents[offset]) }
        if contents.count > kept {
            insert(Array(contents[kept...]), at: lines.lowerBound + kept)
        } else {
            remove((lines.lowerBound + kept)..<lines.upperBound)
        }
    }

    // MARK: The result

    private var changedSpan: (first: Int, oldEnd: Int, newEnd: Int)? {
        guard let firstChanged else { return nil }
        return (firstChanged, original.lineCount - unchangedSuffix, count - unchangedSuffix)
    }

    private func originalStart(_ line: Int) -> Int {
        line < original.lineCount ? original.lineStart(line) : original.length
    }

    private func newText(_ lines: Range<Int>) -> String {
        var text = ""
        for index in lines {
            let line = self.line(index)
            text += line.content
            text += line.lineBreak
        }
        return text
    }

    /// One replacement for every change, or nil when the text is the same.
    func edit() -> TextEdit? {
        guard let span = changedSpan else { return nil }
        let start = originalStart(span.first)
        let range = NSRange(location: start, length: originalStart(span.oldEnd) - start)
        let replacement = newText(span.first..<span.newEnd)
        guard original.substring(range) != replacement else { return nil }
        return TextEdit(range: range, replacement: replacement)
    }

    /// Where `line` starts once `edit()` is applied.
    func start(of line: Int) -> Int {
        guard let span = changedSpan, line >= span.first else { return original.lineStart(line) }
        let start = originalStart(span.first)
        if line <= span.newEnd { return start + newText(span.first..<line).utf16.count }
        let newLength = newText(span.first..<span.newEnd).utf16.count
        let oldLength = originalStart(span.oldEnd) - start
        return original.lineStart(line - count + original.lineCount) + newLength - oldLength
    }
}

/// The lines a `:g` with `:normal` still has to visit, followed through the edits the
/// replayed keys make, as Vim's line marks are. The adapter makes one from
/// `LineReplay.Lines.marked`, puts the cursor at each `next()` offset in turn, and calls
/// `update` with every edit before applying it.
///
/// Each mark is kept as its distance from the end of the text, so an edit moves only the
/// marks it reaches or passes: those after it keep their distance.
public struct ExLineMarks: Equatable {
    /// The distances of the remaining line starts from the end, nearest the end first, so
    /// the next line to visit is last.
    private var distances: [Int]
    private var length: Int

    public init(lines: [Int], in buffer: VimBuffer) {
        length = buffer.length
        distances = lines.reversed().map { buffer.length - buffer.lineRange(at: $0).location }
    }

    /// The start of the next line to visit, which is no longer marked.
    public mutating func next() -> Int? {
        distances.popLast().map { length - $0 }
    }

    /// Moves the marks past `edit`, which applies to `text`. A line goes when the edit
    /// covers it whole or joins it to the line before; a line the edit only changes keeps
    /// its mark.
    public mutating func update(after edit: TextEdit, in text: NSString) {
        let a = edit.range.location
        let b = NSMaxRange(edit.range)
        let inserted = (edit.replacement as NSString).length
        let endsWithBreak = inserted > 0
            && Self.isBreak((edit.replacement as NSString).character(at: inserted - 1))
        let newLength = length + inserted - (b - a)
        var reached = distances.count
        while reached > 0, length - distances[reached - 1] <= b { reached -= 1 }
        let moved = distances[reached...].compactMap { distance -> Int? in
            let start = length - distance
            let newStart: Int
            if start < a || (start == a && b > a
                             && NSMaxRange(text.lineRange(for: NSRange(location: start,
                                                                       length: 0))) > b) {
                newStart = start
            } else if start < b {
                return nil
            } else if a == b {
                newStart = endsWithBreak ? start + inserted : start
            } else {
                let lineStart = inserted > 0 ? endsWithBreak
                    : a == 0 || Self.isBreak(text.character(at: a - 1))
                guard lineStart else { return nil }
                newStart = a + inserted
            }
            return newLength - newStart
        }
        distances.replaceSubrange(reached..., with: moved)
        length = newLength
    }

    private static func isBreak(_ unit: unichar) -> Bool {
        unit == 0x0A || unit == 0x0D || unit == 0x2028 || unit == 0x2029 || unit == 0x85
    }
}
