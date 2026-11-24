import Foundation

/// Vim's operators: `d c y < > gu gU g~ g? = gq`.
enum Operator: Equatable {
    case delete, change, yank, shiftLeft, shiftRight
    case lowercase, uppercase, toggleCase, rot13
    /// `=`, which copies the indent of the line above instead of Vim's C indenting.
    case reindent
    case format

    private static let singleKey: [Character: Operator] = [
        "d": .delete, "c": .change, "y": .yank, "<": .shiftLeft, ">": .shiftRight,
        "=": .reindent,
    ]

    private static let afterG: [Character: Operator] = [
        "u": .lowercase, "U": .uppercase, "~": .toggleCase, "?": .rot13, "q": .format,
    ]

    /// The operator that `keys` name exactly, such as `d` or `gU`.
    static func named(_ keys: [VimKey]) -> Operator? {
        let characters = keys.map(\.argumentCharacter)
        switch characters.count {
        case 1: return characters[0].flatMap { singleKey[$0] }
        case 2 where characters[0] == "g": return characters[1].flatMap { afterG[$0] }
        default: return nil
        }
    }

    /// Whether `keys` are this operator's keys again, or their last key, as in `dd`, `gUU`
    /// and `gUgU`, which act on lines.
    static func repeats(_ operatorKeys: [VimKey], in keys: [VimKey]) -> KeyParse<Bool> {
        if keys == operatorKeys || keys == [operatorKeys[operatorKeys.count - 1]] {
            return .complete(true)
        }
        if operatorKeys.count == 2 && keys == [operatorKeys[0]] { return .incomplete }
        return .complete(false)
    }

    var changesText: Bool { self != .yank }
}

/// What an operator acts on after its keys.
enum OperatorTarget: Equatable {
    case motion(Motion)
    case textObject(TextObject)
    /// The operator doubled, or a command such as `Y` or `S`: `count` whole lines.
    case lines

    static func parse(_ keys: [VimKey], after operatorKeys: [VimKey]) -> KeyParse<OperatorTarget> {
        switch Operator.repeats(operatorKeys, in: keys) {
        case .incomplete: return .incomplete
        case .unknown: return .unknown
        case .complete(true): return .complete(.lines)
        case .complete(false): break
        }
        let objects = TextObject.parse(keys)
        if case .unknown = objects { return Motion.parse(keys).map(OperatorTarget.motion) }
        return objects.map(OperatorTarget.textObject)
    }
}

/// The text an operator acts on.
enum Region: Equatable {
    /// UTF-16 offsets, possibly over several lines.
    case characters(NSRange)
    case lines(ClosedRange<Int>)

    func lines(in b: VimBuffer) -> ClosedRange<Int> {
        switch self {
        case .lines(let lines): return lines
        case .characters(let range):
            return b.lineIndex(of: range.location)...b.lineIndex(of: NSMaxRange(range))
        }
    }

    /// Vim's operator region for a motion from `a` to `b`, after its rule for exclusive
    /// motions that end in the first column of a later line: the end moves back to the end
    /// of the line before, and when the start is in the indent, the region becomes lines.
    static func between(_ a: Int, _ b: Int, _ kind: MotionKind, keepingEnd: Bool = false,
                        in buffer: VimBuffer) -> Region {
        let start = min(a, b)
        let end = max(a, b)
        let startLine = buffer.lineIndex(of: start)
        let endLine = buffer.lineIndex(of: end)
        switch kind {
        case .linewise:
            return .lines(startLine...endLine)
        case .inclusive:
            let after = end < buffer.contentEnd(endLine) ? buffer.nextGrapheme(after: end) ?? end
                : end
            return .characters(NSRange(location: start, length: after - start))
        case .exclusive:
            guard !keepingEnd, endLine > startLine, end == buffer.lineStart(endLine) else {
                return .characters(NSRange(location: start, length: end - start))
            }
            if start <= buffer.firstNonBlank(line: startLine) {
                return .lines(startLine...endLine - 1)
            }
            let previousEnd = buffer.contentEnd(endLine - 1)
            return .characters(NSRange(location: start, length: previousEnd - start))
        }
    }
}

/// A region and where its operated text starts, where the cursor goes after a yank or a
/// case change.
struct OperatorSpan: Equatable {
    var region: Region
    var start: Int
}

extension VimEngine {
    /// Runs `op` on `target` from the cursor. `keys` are the command's keys after its count
    /// and register, recorded for `.`.
    static func operate(_ op: Operator, on target: OperatorTarget, _ command: CommandInput,
                        _ result: inout VimResult, _ buffer: VimBuffer, _ screen: ScreenGeometry) {
        if let name = command.register, op == .delete || op == .change || op == .yank,
           !VimRegisters.isWritable(name) && name != "\"" {
            fail(&result)
            return
        }
        guard let span = span(of: target, for: op, command.count, &result, buffer, screen)
        else { return }
        result.window.desiredColumn = nil
        let registerOne: Bool
        if case .motion(let motion) = target { registerOne = motion.deletesIntoRegisterOne }
        else { registerOne = false }
        switch op {
        case .delete: delete(span, register: command.register, registerOne, &result, buffer)
        case .change:
            change(span, register: command.register, registerOne, &result, buffer)
            result.window.changeInProgress = command.change
            return
        case .yank: yank(span, register: command.register, &result, buffer)
        case .shiftLeft, .shiftRight:
            shift(span, left: op == .shiftLeft, amount: 1, &result, buffer)
        case .lowercase: changeCase(span, .lower, &result, buffer)
        case .uppercase: changeCase(span, .upper, &result, buffer)
        case .toggleCase: changeCase(span, .toggle, &result, buffer)
        case .rot13: changeCase(span, .rot13, &result, buffer)
        case .reindent: reindent(span, &result, buffer)
        case .format: format(span, &result, buffer)
        }
        if op.changesText { result.session.lastChange = command.change }
    }

    /// The text `target` covers, or nil after reporting why there is none.
    private static func span(of target: OperatorTarget, for op: Operator, _ count: Int?,
                             _ result: inout VimResult, _ buffer: VimBuffer,
                             _ screen: ScreenGeometry) -> OperatorSpan? {
        let cursor = result.window.cursor
        switch target {
        case .lines:
            let line = buffer.lineIndex(of: cursor)
            let lineCount = max(count ?? 1, 1)
            guard lineCount == 1 || line < buffer.lineCount - 1 else {
                fail(&result)
                return nil
            }
            let last = min(line + lineCount - 1, buffer.lineCount - 1)
            let end = Motions.normalPosition(buffer.firstNonBlank(line: last), in: buffer)
            return OperatorSpan(region: .lines(line...last),
                                start: op == .yank ? cursor : min(cursor, end))
        case .textObject(let object):
            guard let found = TextObjects.find(object, count: max(count ?? 1, 1), from: cursor,
                                               in: buffer) else {
                fail(&result)
                return nil
            }
            return OperatorSpan(region: Region.between(found.start, found.end, found.kind,
                                                       in: buffer), start: found.start)
        case .motion(let motion):
            guard let moved = motionTarget(motion, for: op, count, &result, buffer, screen)
            else { return nil }
            return OperatorSpan(region: Region.between(cursor, moved.offset, moved.kind,
                                                       keepingEnd: moved.keepsEnd, in: buffer),
                                start: min(cursor, moved.offset))
        }
    }

    /// Where `motion` goes with an operator pending. `cw` on a word acts like `ce`, but stops
    /// at the end of the word under the cursor.
    private static func motionTarget(_ motion: Motion, for op: Operator, _ count: Int?,
                                     _ result: inout VimResult, _ buffer: VimBuffer,
                                     _ screen: ScreenGeometry) -> MotionTarget? {
        let cursor = result.window.cursor
        var context = motionContext(result, buffer, screen)
        context.operatorPending = true
        context.operatorDeletes = op == .delete || op == .change
        if case .find(let find) = motion { result.session.lastFind = find }
        let outcome: Motions.Outcome
        if op == .change, case .wordForward(let big) = motion, !buffer.isLineEnd(cursor),
           !buffer.isBlankCharacter(at: cursor) {
            outcome = Motions.wordEnd(cursor, max(count ?? 1, 1), big: big, stop: true, buffer)
        } else {
            outcome = Motions.target(of: motion, count: count, from: cursor, in: context)
        }
        switch outcome {
        case .failure(let failure):
            if let message = failure.message { result.effects.append(.message(message)) }
            fail(&result)
            return nil
        case .success(let target):
            if motion.isJump { recordJump(&result.window, buffer) }
            guard target.shortfall != .cancelOperator else {
                result.window.cursor = Motions.normalPosition(target.offset, in: buffer)
                fail(&result)
                return nil
            }
            return target
        }
    }

    // MARK: Delete, change and yank

    /// Deletes `span`. Outside Visual mode, Vi's rule may turn a characterwise delete into
    /// a linewise one.
    static func delete(_ span: OperatorSpan, register: Character?, _ registerOne: Bool,
                       visual: Bool = false, _ result: inout VimResult, _ buffer: VimBuffer) {
        var region = span.region
        if case .characters(let range) = region {
            guard range.length > 0 else { return }
            if !visual && spansLinesLeavingBlanks(range, buffer) {
                region = .lines(region.lines(in: buffer))
            }
        }
        storeDelete(region, register: register, registerOne, &result, buffer)
        switch region {
        case .characters(let range):
            result.edits.append(TextEdit(range: range, replacement: ""))
            result.window.cursor = cursor(afterDeleting: range, buffer)
            let start = buffer.mark(at: range.location)
            setChangeMarks(start, start, &result.window)
        case .lines(let lines):
            let (edit, cursor) = deleteLines(lines, buffer)
            result.edits.append(edit)
            result.window.cursor = cursor
            let start = Mark(line: lines.lowerBound, column: 0)
            setChangeMarks(start, start, &result.window)
        }
    }

    /// Sets the `[` and `]` marks, which Vim puts around the text a command changed or yanked.
    static func setChangeMarks(_ start: Mark, _ end: Mark, _ window: inout VimWindowState) {
        window.marks["["] = start
        window.marks["]"] = end
    }

    /// Vi's rule, kept by Vim's default `cpoptions`: a characterwise delete over several
    /// lines that starts in the indent and leaves only blanks on its last line deletes lines.
    private static func spansLinesLeavingBlanks(_ range: NSRange, _ b: VimBuffer) -> Bool {
        let startLine = b.lineIndex(of: range.location)
        let end = NSMaxRange(range)
        let endLine = b.lineIndex(of: end)
        guard endLine > startLine, range.location <= b.firstNonBlank(line: startLine) else {
            return false
        }
        var offset = end
        while offset < b.contentEnd(endLine) {
            guard b.isBlankCharacter(at: offset) else { return false }
            offset += 1
        }
        return true
    }

    private static func storeDelete(_ region: Region, register: Character?, _ registerOne: Bool,
                                    _ result: inout VimResult, _ buffer: VimBuffer) {
        let small: Bool
        switch region {
        case .characters(let range):
            small = buffer.lineIndex(of: range.location) == buffer.lineIndex(of: NSMaxRange(range))
        case .lines:
            small = false
        }
        let clipboard = result.session.registers.delete(
            registerValue(region, buffer), into: target(register, result.session.options),
            small: small, alsoNumbered: registerOne)
        if let clipboard { result.effects.append(.setClipboard(clipboard)) }
    }

    static func change(_ span: OperatorSpan, register: Character?, _ registerOne: Bool,
                       _ result: inout VimResult, _ buffer: VimBuffer) {
        switch span.region {
        case .characters(let range):
            if range.length > 0 {
                storeDelete(span.region, register: register, registerOne, &result, buffer)
                result.edits.append(TextEdit(range: range, replacement: ""))
            }
            result.window.cursor = range.location
        case .lines(let lines):
            storeDelete(span.region, register: register, registerOne, &result, buffer)
            let start = buffer.lineStart(lines.lowerBound)
            let indent = result.session.options.autoindent
                ? buffer.substring(start..<buffer.firstNonBlank(line: lines.lowerBound)) : ""
            let end = buffer.contentEnd(lines.upperBound)
            let range = NSRange(location: start, length: end - start)
            result.edits.append(TextEdit(range: range, replacement: indent))
            result.window.cursor = start + indent.utf16.count
        }
        result.window.mode = .insert
        result.window.insertSession = InsertSession()
    }

    static func yank(_ span: OperatorSpan, register: Character?,
                     _ result: inout VimResult, _ buffer: VimBuffer) {
        let clipboard = result.session.registers.yank(
            registerValue(span.region, buffer), into: target(register, result.session.options))
        if let clipboard { result.effects.append(.setClipboard(clipboard)) }
        result.window.cursor = Motions.normalPosition(span.start, in: buffer)
        switch span.region {
        case .characters(let range):
            var last = NSMaxRange(range)
            if range.length > 0 { _ = buffer.decl(&last) }
            setChangeMarks(buffer.mark(at: range.location), buffer.mark(at: last),
                           &result.window)
        case .lines(let lines):
            setChangeMarks(Mark(line: lines.lowerBound, column: 0),
                           Mark(line: lines.upperBound, column: Int.max), &result.window)
        }
    }

    /// The register a yank or delete writes: the one named, or under `clipboard=unnamed`
    /// and `unnamedplus` the system clipboard.
    static func target(_ register: Character?, _ options: VimOptions) -> Character? {
        if let register, register != "\"" { return register }
        let flags = options.clipboard.split(separator: ",")
        if flags.contains("unnamedplus") { return "+" }
        if flags.contains("unnamed") { return "*" }
        return nil
    }

    /// The text of `region` with every line break written as `\n`, as registers hold it.
    static func registerValue(_ region: Region, _ b: VimBuffer) -> RegisterValue {
        switch region {
        case .characters(let range):
            var text = ""
            var line = b.lineIndex(of: range.location)
            var offset = range.location
            while offset < NSMaxRange(range) {
                let contentEnd = min(b.contentEnd(line), NSMaxRange(range))
                text += b.substring(offset..<contentEnd)
                guard NSMaxRange(range) > b.contentEnd(line) else { break }
                text += "\n"
                line += 1
                offset = b.lineStart(line)
            }
            return RegisterValue(text: text, kind: .characterwise)
        case .lines(let lines):
            let text = lines.map { b.substring(b.contentRange(at: $0)) + "\n" }.joined()
            return RegisterValue(text: text, kind: .linewise)
        }
    }

    /// The Normal-mode cursor once `range` is deleted: its start, or the character before
    /// it when the deletion reached the end of a non-empty line.
    static func cursor(afterDeleting range: NSRange, _ b: VimBuffer) -> Int {
        let start = range.location
        guard b.isLineEnd(NSMaxRange(range)), start > b.lineStart(b.lineIndex(of: start)) else {
            return start
        }
        return b.previousGrapheme(before: start) ?? start
    }

    /// Deletes whole lines. Deleting the last line also removes the line break before it.
    /// The cursor goes to the first non-blank of the line that takes their place.
    static func deleteLines(_ lines: ClosedRange<Int>, _ b: VimBuffer) -> (TextEdit, Int) {
        let first = lines.lowerBound
        let start = b.lineStart(first)
        let end = NSMaxRange(b.lineRange(at: lines.upperBound))
        if end < b.length {
            let following = Motions.normalPosition(b.firstNonBlank(line: lines.upperBound + 1),
                                                   in: b)
            return (TextEdit(range: NSRange(location: start, length: end - start),
                             replacement: ""), following - (end - start))
        }
        guard first > 0 else {
            return (TextEdit(range: NSRange(location: 0, length: end), replacement: ""), 0)
        }
        let previous = Motions.normalPosition(b.firstNonBlank(line: first - 1), in: b)
        let hasFinalBreak = b.contentEnd(lines.upperBound) < end
        let from = hasFinalBreak ? start : b.contentEnd(first - 1)
        return (TextEdit(range: NSRange(location: from, length: end - from), replacement: ""),
                previous)
    }

    // MARK: Lines rewritten one by one

    /// One edit that replaces the content of `lines` with `contents`, keeping each line's own
    /// line break. Nil when nothing changes.
    static func rewrite(_ lines: ClosedRange<Int>, as contents: [String],
                        _ b: VimBuffer) -> TextEdit? {
        var replacement = ""
        var changed = false
        for (index, line) in lines.enumerated() {
            let content = b.contentRange(at: line)
            let old = b.substring(content)
            changed = changed || old != contents[index]
            replacement += contents[index]
            if line < lines.upperBound {
                replacement += b.substring(NSMaxRange(content)..<NSMaxRange(b.lineRange(at: line)))
            }
        }
        guard changed else { return nil }
        let start = b.lineStart(lines.lowerBound)
        return TextEdit(range: NSRange(location: start, length: b.contentEnd(lines.upperBound)
            - start), replacement: replacement)
    }

    /// The Normal-mode offset of the first non-blank in a line whose new content is `content`
    /// and which starts at `lineStart`.
    static func firstNonBlank(of content: String, lineStart: Int) -> Int {
        let units = Array(content.utf16)
        var column = 0
        while column < units.count, units[column] == 0x20 || units[column] == 0x09 { column += 1 }
        if column == units.count && column > 0 { column -= 1 }
        return lineStart + column
    }

    /// Shifts the lines of `span` by `amount` shift widths.
    static func shift(_ span: OperatorSpan, left: Bool, amount: Int, _ result: inout VimResult,
                      _ buffer: VimBuffer) {
        let options = result.session.options
        let width = amount * (options.shiftwidth > 0 ? options.shiftwidth : options.tabstop)
        let lines = span.region.lines(in: buffer)
        let contents = lines.map { line -> String in
            let content = buffer.substring(buffer.contentRange(at: line))
            guard !content.isEmpty else { return content }
            let indent = buffer.indentWidth(line: line, tabstop: options.tabstop)
            let shifted = left ? max(indent - width, 0) : indent + width
            return indentText(width: shifted, options) + buffer.textAfterIndent(line: line)
        }
        if let edit = rewrite(lines, as: contents, buffer) { result.edits.append(edit) }
        result.window.cursor = firstNonBlank(of: contents[0],
                                             lineStart: buffer.lineStart(lines.lowerBound))
    }

    /// Vim's `set_indent`: tabs and spaces without `expandtab`, spaces with it.
    static func indentText(width: Int, _ options: VimOptions) -> String {
        guard !options.expandtab, options.tabstop > 0 else {
            return String(repeating: " ", count: width)
        }
        return String(repeating: "\t", count: width / options.tabstop)
            + String(repeating: " ", count: width % options.tabstop)
    }

    // MARK: Case

    static func changeCase(_ span: OperatorSpan, _ change: CaseChange,
                           _ result: inout VimResult, _ buffer: VimBuffer) {
        switch span.region {
        case .characters(let range):
            let old = buffer.substring(range)
            let new = change.apply(to: old)
            if new != old { result.edits.append(TextEdit(range: range, replacement: new)) }
            result.window.cursor = Motions.normalPosition(span.start, in: buffer)
        case .lines(let lines):
            let contents = lines.map {
                change.apply(to: buffer.substring(buffer.contentRange(at: $0)))
            }
            if let edit = rewrite(lines, as: contents, buffer) { result.edits.append(edit) }
            let lineStart = buffer.lineStart(lines.lowerBound)
            let before = change.apply(to: buffer.substring(lineStart..<span.start))
            result.window.cursor = Motions.normalPosition(lineStart + before.utf16.count,
                                                          in: buffer)
        }
    }

    // MARK: = and gq

    /// Every non-blank line takes the indent of the nearest non-blank line above the region;
    /// blank lines lose their blanks. Vim would use C indenting here.
    static func reindent(_ span: OperatorSpan, _ result: inout VimResult,
                         _ buffer: VimBuffer) {
        let options = result.session.options
        let lines = span.region.lines(in: buffer)
        var above = lines.lowerBound - 1
        while above >= 0, buffer.isBlankLine(above) { above -= 1 }
        let width = above >= 0 ? buffer.indentWidth(line: above, tabstop: options.tabstop) : 0
        let contents = lines.map { line -> String in
            buffer.isBlankLine(line) ? ""
                : indentText(width: width, options) + buffer.textAfterIndent(line: line)
        }
        if let edit = rewrite(lines, as: contents, buffer) { result.edits.append(edit) }
        result.window.cursor = firstNonBlank(of: contents[0],
                                             lineStart: buffer.lineStart(lines.lowerBound))
    }

    /// Joins each paragraph of the region and breaks it again at blanks, so that no line is
    /// wider than `textwidth` (79 when it is 0) unless a single word is. Unlike Vim, comment
    /// leaders such as `#` and list markers are not recognized.
    static func format(_ span: OperatorSpan, _ result: inout VimResult,
                       _ buffer: VimBuffer) {
        let options = result.session.options
        let lines = span.region.lines(in: buffer)
        let width = options.textwidth > 0 ? options.textwidth : 79
        var output: [String] = []
        var paragraph: [String] = []
        func flush() {
            guard !paragraph.isEmpty else { return }
            let joined = TextFormat.join(paragraph, spaces: true).text
            let indent = options.autoindent ? TextFormat.leadingBlanks(of: paragraph[0]) : ""
            output += TextFormat.wrap(joined, width: width, nextIndent: indent,
                                      tabstop: options.tabstop)
            paragraph = []
        }
        for line in lines {
            let content = buffer.substring(buffer.contentRange(at: line))
            if buffer.isBlankLine(line) {
                flush()
                output.append(content)
            } else {
                paragraph.append(content)
            }
        }
        flush()
        let start = buffer.lineStart(lines.lowerBound)
        let lineBreak = buffer.lineBreak(near: lines.lowerBound)
        let replacement = output.joined(separator: lineBreak)
        let range = NSRange(location: start, length: buffer.contentEnd(lines.upperBound) - start)
        if buffer.substring(range) != replacement {
            result.edits.append(TextEdit(range: range, replacement: replacement))
        }
        let lastStart = start + output.dropLast().reduce(0) {
            $0 + $1.utf16.count + lineBreak.utf16.count
        }
        result.window.cursor = firstNonBlank(of: output[output.count - 1], lineStart: lastStart)
    }
}

/// The input of a command: its count, register and keys, which `.` repeats.
struct CommandInput {
    var count: Int?
    var register: Character?
    var keys: [VimKey]

    var change: RecordedChange { RecordedChange(register: register, count: count, keys: keys) }
}

enum CaseChange {
    case lower, upper, toggle, rot13

    /// Maps each code point to one code point, as Vim does: `ß` becomes `ẞ`, and a letter
    /// whose full mapping has several code points stays as it is.
    func apply(to text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch self {
            case .lower: scalars.append(Self.lower(scalar))
            case .upper: scalars.append(Self.upper(scalar))
            case .toggle:
                let upper = Self.upper(scalar)
                scalars.append(upper != scalar ? upper : Self.lower(scalar))
            case .rot13: scalars.append(Self.rot13(scalar))
            }
        }
        return String(scalars)
    }

    private static func upper(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        if scalar == "ß" { return "ẞ" }
        return single(scalar.properties.uppercaseMapping) ?? scalar
    }

    private static func lower(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        if scalar == "İ" { return "i" }
        return single(scalar.properties.lowercaseMapping) ?? scalar
    }

    private static func single(_ mapping: String) -> Unicode.Scalar? {
        let scalars = mapping.unicodeScalars
        return scalars.count == 1 ? scalars.first : nil
    }

    private static func rot13(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        switch scalar.value {
        case 0x41...0x5A: return Unicode.Scalar((scalar.value - 0x41 + 13) % 26 + 0x41) ?? scalar
        case 0x61...0x7A: return Unicode.Scalar((scalar.value - 0x61 + 13) % 26 + 0x61) ?? scalar
        default: return scalar
        }
    }
}

extension VimBuffer {
    func substring(_ range: NSRange) -> String { text.substring(with: range) }

    func substring(_ range: Range<Int>) -> String {
        text.substring(with: NSRange(location: range.lowerBound, length: range.count))
    }

    /// The line break that ends `line`, or the one before it on the last line, or `\n` in
    /// text without line breaks. Inserted lines use it, so CRLF text stays CRLF.
    func lineBreak(near line: Int) -> String {
        let breakRange = NSMaxRange(contentRange(at: line))..<NSMaxRange(lineRange(at: line))
        if !breakRange.isEmpty { return substring(breakRange) }
        return line > 0 ? lineBreak(near: line - 1) : "\n"
    }

    /// Whether the line holds only spaces and tabs, or nothing.
    func isBlankLine(_ line: Int) -> Bool { firstNonBlank(line: line) == contentEnd(line) }

    func indentWidth(line: Int, tabstop: Int) -> Int {
        displayColumn(of: firstNonBlank(line: line), tabstop: tabstop)
    }

    func textAfterIndent(line: Int) -> String {
        substring(firstNonBlank(line: line)..<contentEnd(line))
    }
}
