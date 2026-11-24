import Foundation

/// A Normal-mode command that edits the text without an operator.
enum Edit: Equatable {
    /// `r`; a line break stands for `r<CR>`.
    case replace(Character)
    case replaceMode
    case toggleCase
    /// `J`, or `gJ` without `spaces`.
    case join(spaces: Bool)
    case put(Put)
    /// Control-A, or Control-X when `subtract`.
    case addToNumber(subtract: Bool)
    case insert(InsertPlace)
    case undo, redo
    case repeatChange

    struct Put: Equatable {
        /// `P` and `gP`.
        var before: Bool
        /// `gp` and `gP`.
        var cursorAfter = false
        /// `]p` and `[p`.
        var fixIndent = false
    }

    enum InsertPlace: Equatable {
        /// `i`, `a`, `I`, `A` and `gi`.
        case cursor, afterCursor, firstNonBlank, lineEnd, lastInsert
        /// `o` and `O`.
        case lineBelow, lineAbove
    }

    private static let singleKey: [Character: NormalCommand] = [
        "x": .operate(.delete, .motion(.right)), "X": .operate(.delete, .motion(.left)),
        "D": .operate(.delete, .motion(.lineEnd)), "C": .operate(.change, .motion(.lineEnd)),
        "s": .operate(.change, .motion(.right)), "S": .operate(.change, .lines),
        "Y": .operate(.yank, .lines),
        "R": .edit(.replaceMode), "~": .edit(.toggleCase), "J": .edit(.join(spaces: true)),
        "p": .edit(.put(Put(before: false))), "P": .edit(.put(Put(before: true))),
        "i": .edit(.insert(.cursor)), "a": .edit(.insert(.afterCursor)),
        "I": .edit(.insert(.firstNonBlank)), "A": .edit(.insert(.lineEnd)),
        "o": .edit(.insert(.lineBelow)), "O": .edit(.insert(.lineAbove)),
        "u": .edit(.undo), ".": .edit(.repeatChange),
    ]

    private static let afterG: [Character: NormalCommand] = [
        "J": .edit(.join(spaces: false)),
        "p": .edit(.put(Put(before: false, cursorAfter: true))),
        "P": .edit(.put(Put(before: true, cursorAfter: true))),
        "i": .edit(.insert(.lastInsert)),
    ]

    /// Reads an operator or edit from the keys after any count and register, or nil when the
    /// first key starts neither.
    static func parse(_ keys: [VimKey]) -> KeyParse<NormalCommand>? {
        guard let first = keys.first else { return nil }
        if first.control {
            switch first.base {
            case .character("a"): return .complete(.edit(.addToNumber(subtract: false)))
            case .character("x"): return .complete(.edit(.addToNumber(subtract: true)))
            case .character("r"): return .complete(.edit(.redo))
            default: return nil
            }
        }
        guard case .character(let character) = first.base else { return nil }
        if let op = Operator.named([first]) { return .complete(.operator(op)) }
        if let command = singleKey[character] { return .complete(command) }
        let second = keys.count > 1 ? keys[1] : nil
        switch character {
        case "r":
            guard let second else { return .incomplete }
            if second == VimKey(.enter) { return .complete(.edit(.replace("\n"))) }
            return second.argumentCharacter.map { .complete(.edit(.replace($0))) } ?? .unknown
        case "g":
            guard let second else { return nil }
            if let op = Operator.named([first, second]) { return .complete(.operator(op)) }
            return second.argumentCharacter.flatMap { afterG[$0] }.map { .complete($0) }
        case "[", "]":
            guard let second else { return .incomplete }
            guard second == VimKey(.character("p")) else { return .unknown }
            return .complete(.edit(.put(Put(before: character == "[", fixIndent: true))))
        default:
            return nil
        }
    }
}

extension VimEngine {
    static func edit(_ edit: Edit, _ input: CommandInput, _ result: inout VimResult,
                     _ buffer: VimBuffer, _ clipboard: () -> String?) {
        let changed: Bool
        switch edit {
        case .undo:
            result.effects.append(.undo(input.count ?? 1))
            return
        case .redo:
            result.effects.append(.redo(input.count ?? 1))
            return
        case .repeatChange:
            repeatChange(input, &result)
            return
        case .insert(let place):
            startInsert(place, input, &result, buffer)
            return
        case .replaceMode:
            enterInsert(.replace, at: result.window.cursor,
                        InsertSession(count: max(input.count ?? 1, 1)), input, &result)
            return
        case .replace(let character): changed = replace(with: character, input, &result, buffer)
        case .toggleCase: changed = toggleCase(input, &result, buffer)
        case .join(let spaces): changed = join(spaces: spaces, input, &result, buffer)
        case .put(let put): changed = self.put(put, input, &result, buffer, clipboard)
        case .addToNumber(let subtract):
            changed = addToNumber(subtract: subtract, input, &result, buffer)
        }
        if changed { result.session.lastChange = input.change }
    }

    /// `.` asks the adapter to feed the last change's keys back, with a new count or
    /// register in place of the recorded one. A recorded register `1` to `8` becomes the
    /// next one, so `"1p..` puts registers 1, 2 and 3 (Vim's `redo-register`).
    private static func repeatChange(_ input: CommandInput, _ result: inout VimResult) {
        guard var change = result.session.lastChange else {
            fail(&result)
            return
        }
        if let count = input.count { change.count = count }
        if let register = input.register {
            change.register = register
        } else if let number = change.register?.wholeNumberValue, (1...8).contains(number) {
            change.register = Character(String(number + 1))
        }
        var keys: [VimKey] = []
        if let register = change.register {
            keys += [VimKey(.character("\"")), VimKey(.character(register))]
        }
        if let count = change.count {
            keys += String(count).map { VimKey(.character($0)) }
        }
        result.effects.append(.replay(keys + change.keys))
    }

    // MARK: Insert and Replace mode

    private static func startInsert(_ place: Edit.InsertPlace, _ input: CommandInput,
                                    _ result: inout VimResult, _ b: VimBuffer) {
        let cursor = result.window.cursor
        let line = b.lineIndex(of: cursor)
        let count = max(input.count ?? 1, 1)
        let offset: Int
        switch place {
        case .cursor: offset = cursor
        case .afterCursor:
            offset = b.isLineEnd(cursor) ? cursor : b.nextGrapheme(after: cursor) ?? cursor
        case .firstNonBlank: offset = b.firstNonBlank(line: line)
        case .lineEnd: offset = b.contentEnd(line)
        case .lastInsert: offset = result.window.marks["^"].map { b.offset(of: $0) } ?? cursor
        case .lineBelow, .lineAbove:
            let indent = result.session.options.autoindent
                ? b.substring(b.lineStart(line)..<b.firstNonBlank(line: line)) : ""
            let lineBreak = b.lineBreak(near: line)
            let below = place == .lineBelow
            let at = below ? b.contentEnd(line) : b.lineStart(line)
            let opened = below ? lineBreak + indent : indent + lineBreak
            result.edits.append(TextEdit(range: NSRange(location: at, length: 0),
                                         replacement: opened))
            let session = InsertSession(count: count, repeatPrefix: lineBreak + indent)
            let start = at + (below ? opened.utf16.count : indent.utf16.count)
            enterInsert(.insert, at: start, session, input, &result)
            return
        }
        enterInsert(.insert, at: offset, InsertSession(count: count), input, &result)
    }

    private static func enterInsert(_ mode: VimMode, at offset: Int, _ session: InsertSession,
                                    _ input: CommandInput, _ result: inout VimResult) {
        result.window.mode = mode
        result.window.cursor = offset
        result.window.desiredColumn = nil
        result.window.insertSession = session
        result.window.changeInProgress = input.change
    }

    /// Insert and Replace mode: typed characters, Tab and Enter go into the text and Escape
    /// returns to Normal mode. The adapter lets AppKit insert typed text; the engine sees
    /// these keys when it replays them for `.`.
    static func insertMode(_ key: VimKey, _ result: inout VimResult, _ b: VimBuffer) {
        result.window.changeInProgress?.keys.append(key)
        if key == VimKey(.escape) {
            finishInsert(&result, b)
            return
        }
        let cursor = result.window.cursor
        let line = b.lineIndex(of: cursor)
        guard let text = typedText(key, after: b.substring(b.lineStart(line)..<cursor),
                                   result.session.options, lineBreak: b.lineBreak(near: line))
        else { return }
        var range = NSRange(location: cursor, length: 0)
        if result.window.mode == .replace, key != VimKey(.enter), !b.isLineEnd(cursor),
           let next = b.nextGrapheme(after: cursor) {
            range.length = next - cursor
        }
        result.edits.append(TextEdit(range: range, replacement: text))
        result.window.cursor = cursor + text.utf16.count
        result.window.insertSession?.typed.append(key)
    }

    /// The text a key typed in Insert mode adds after `linePrefix`, the line's text before
    /// the cursor, or nil for keys that insert nothing here. Tab reaches the next tabstop
    /// with spaces under `expandtab`; Enter copies the indent under `autoindent`.
    private static func typedText(_ key: VimKey, after linePrefix: String,
                                  _ options: VimOptions, lineBreak: String) -> String? {
        guard !key.control else { return nil }
        switch key.base {
        case .character(let character):
            return String(character)
        case .tab:
            guard options.expandtab, options.tabstop > 0 else { return "\t" }
            let column = TextFormat.displayWidth(Array(linePrefix), tabstop: options.tabstop)
            return String(repeating: " ", count: options.tabstop - column % options.tabstop)
        case .enter:
            return lineBreak + (options.autoindent ? TextFormat.leadingBlanks(of: linePrefix)
                : "")
        case .escape, .backspace, .up, .down, .left, .right, .home, .end, .pageUp, .pageDown,
             .delete:
            return nil
        }
    }

    /// What the `.` register holds for typed keys: Tab and Enter as typed, not expanded.
    private static func insertedText(_ keys: [VimKey]) -> String {
        String(keys.compactMap { key -> Character? in
            switch key.base {
            case .character(let character): return character
            case .tab: return "\t"
            case .enter: return "\n"
            case .escape, .backspace, .up, .down, .left, .right, .home, .end, .pageUp,
                 .pageDown, .delete:
                return nil
            }
        })
    }

    /// Escape: types the keys again for the extra copies a count asks for, sets the `^`
    /// mark and the `.` register, records the change for `.`, and steps the cursor left as
    /// Vim does.
    private static func finishInsert(_ result: inout VimResult, _ b: VimBuffer) {
        let session = result.window.insertSession ?? InsertSession()
        let cursor = result.window.cursor
        let line = b.lineIndex(of: cursor)
        var stop = b.mark(at: cursor)
        var normal = b.isLineStart(cursor) ? cursor : b.previousGrapheme(before: cursor) ?? cursor
        let linePrefix = b.substring(b.lineStart(line)..<cursor)
        let (copies, lastLine) = repeatedTyping(session, after: linePrefix, result.session.options,
                                                lineBreak: b.lineBreak(near: line))
        if !copies.isEmpty {
            var range = NSRange(location: cursor, length: 0)
            if result.window.mode == .replace {
                range.length = graphemes(copies.count, from: cursor, b).end - cursor
            }
            result.edits.append(TextEdit(range: range, replacement: copies))
            let end = cursor + copies.utf16.count
            let breaks = copies.filter(\.isNewline).count
            stop = breaks == 0 ? Mark(line: stop.line, column: stop.column + copies.utf16.count)
                : Mark(line: stop.line + breaks, column: lastLine.utf16.count)
            normal = lastLine.isEmpty ? end : end - lastCharacterLength(of: copies)
        }
        result.window.marks["^"] = stop
        result.window.cursor = normal
        result.session.registers.setReadOnly(".", insertedText(session.typed))
        if let change = result.window.changeInProgress { result.session.lastChange = change }
        result.window.mode = .normal
        result.window.insertSession = nil
        result.window.changeInProgress = nil
        result.window.desiredColumn = nil
    }

    /// The text the `count - 1` extra copies add, typing the keys again from where the
    /// session stopped, and the text of the last line they end on.
    private static func repeatedTyping(_ session: InsertSession, after linePrefix: String,
                                       _ options: VimOptions,
                                       lineBreak: String) -> (String, String) {
        guard session.count > 1, !session.typed.isEmpty else { return ("", linePrefix) }
        var text = ""
        var lastLine = linePrefix
        func add(_ piece: String) {
            text += piece
            if let lastBreak = piece.lastIndex(where: \.isNewline) {
                lastLine = String(piece[piece.index(after: lastBreak)...])
            } else {
                lastLine += piece
            }
        }
        for _ in 1..<session.count {
            add(session.repeatPrefix)
            for key in session.typed {
                if let typed = typedText(key, after: lastLine, options, lineBreak: lineBreak) {
                    add(typed)
                }
            }
        }
        return (text, lastLine)
    }

    private static func lastCharacterLength(of text: String) -> Int {
        text.last.map { String($0).utf16.count } ?? 0
    }

    /// The end of up to `count` graphemes from `offset` within its line, and how many there
    /// were.
    private static func graphemes(_ count: Int, from offset: Int,
                                  _ b: VimBuffer) -> (end: Int, found: Int) {
        let lineEnd = b.contentEnd(b.lineIndex(of: offset))
        var end = offset
        var found = 0
        while found < count, end < lineEnd, let next = b.nextGrapheme(after: end) {
            end = next
            found += 1
        }
        return (end, found)
    }

    // MARK: r and ~

    private static func replace(with character: Character, _ input: CommandInput,
                                _ result: inout VimResult, _ b: VimBuffer) -> Bool {
        let cursor = result.window.cursor
        let count = max(input.count ?? 1, 1)
        let (end, found) = graphemes(count, from: cursor, b)
        guard found == count else {
            fail(&result)
            return false
        }
        let range = NSRange(location: cursor, length: end - cursor)
        if character == "\n" {
            let lineBreak = b.lineBreak(near: b.lineIndex(of: cursor))
            result.edits.append(TextEdit(range: range, replacement: lineBreak))
            result.window.cursor = cursor + lineBreak.utf16.count
        } else {
            let text = String(character)
            result.edits.append(TextEdit(range: range,
                                         replacement: String(repeating: text, count: count)))
            result.window.cursor = cursor + (count - 1) * text.utf16.count
        }
        return true
    }

    /// `~`: toggles the case of up to `count` characters and moves past them, but not past
    /// the last character of the line.
    private static func toggleCase(_ input: CommandInput, _ result: inout VimResult,
                                   _ b: VimBuffer) -> Bool {
        let cursor = result.window.cursor
        guard !b.isLineEnd(cursor) else {
            fail(&result)
            return false
        }
        let (end, _) = graphemes(max(input.count ?? 1, 1), from: cursor, b)
        let range = NSRange(location: cursor, length: end - cursor)
        let old = b.substring(range)
        let new = CaseChange.toggle.apply(to: old)
        if new != old { result.edits.append(TextEdit(range: range, replacement: new)) }
        let after = cursor + new.utf16.count
        result.window.cursor = b.isLineEnd(end) ? after - lastCharacterLength(of: new) : after
        return true
    }

    // MARK: J and gJ

    private static func join(spaces: Bool, _ input: CommandInput, _ result: inout VimResult,
                             _ b: VimBuffer) -> Bool {
        let line = b.lineIndex(of: result.window.cursor)
        var count = max(input.count ?? 2, 2)
        if line + count > b.lineCount {
            guard count > 2 else {
                fail(&result)
                return false
            }
            count = b.lineCount - line
        }
        let lines = line...(line + count - 1)
        let contents = lines.map { b.substring(b.contentRange(at: $0)) }
        let joined = TextFormat.join(contents, spaces: spaces)
        let start = b.lineStart(line)
        let range = NSRange(location: start, length: b.contentEnd(lines.upperBound) - start)
        if b.substring(range) != joined.text {
            result.edits.append(TextEdit(range: range, replacement: joined.text))
        }
        let length = joined.text.utf16.count
        result.window.cursor = start + (joined.lastJoin < length || length == 0
            ? joined.lastJoin : length - lastCharacterLength(of: joined.text))
        return true
    }

    // MARK: p P gp gP ]p [p

    private static func put(_ put: Edit.Put, _ input: CommandInput, _ result: inout VimResult,
                            _ b: VimBuffer, _ clipboard: () -> String?) -> Bool {
        let name = target(input.register, result.session.options) ?? "\""
        guard let value = result.session.registers.value(name, clipboard: clipboard) else {
            result.effects.append(.message("E353: Nothing in register \(name)"))
            fail(&result)
            return false
        }
        let count = max(input.count ?? 1, 1)
        switch value.kind {
        case .characterwise:
            putCharacters(value.text, count, put, &result, b)
        case .linewise:
            putLines(value.text, count, put, &result, b)
        case .blockwise:
            fail(&result)
            return false
        }
        return true
    }

    private static func putCharacters(_ text: String, _ count: Int, _ put: Edit.Put,
                                      _ result: inout VimResult, _ b: VimBuffer) {
        let cursor = result.window.cursor
        let line = b.lineIndex(of: cursor)
        let at = put.before || b.isLineEnd(cursor) ? cursor : b.nextGrapheme(after: cursor)
            ?? cursor
        let lineBreak = b.lineBreak(near: line)
        let inserted = String(repeating: text.replacingOccurrences(of: "\n", with: lineBreak),
                              count: count)
        guard !inserted.isEmpty else { return }
        result.edits.append(TextEdit(range: NSRange(location: at, length: 0),
                                     replacement: inserted))
        let end = at + inserted.utf16.count
        if put.cursorAfter {
            let atLineEnd = b.isLineEnd(at) && !inserted.hasSuffix(lineBreak)
            result.window.cursor = atLineEnd ? end - lastCharacterLength(of: inserted) : end
        } else if text.contains("\n") {
            result.window.cursor = at
        } else {
            result.window.cursor = end - lastCharacterLength(of: inserted)
        }
    }

    private static func putLines(_ text: String, _ count: Int, _ put: Edit.Put,
                                 _ result: inout VimResult, _ b: VimBuffer) {
        let line = b.lineIndex(of: result.window.cursor)
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        if put.fixIndent {
            let options = result.session.options
            lines = TextFormat.reindent(lines, to: b.indentWidth(line: line,
                                                                 tabstop: options.tabstop),
                                        options)
        }
        let block = Array(Array(repeating: lines, count: count).joined())
        let lineBreak = b.lineBreak(near: line)
        let hasBreak = b.contentEnd(line) < NSMaxRange(b.lineRange(at: line))
        let at: Int
        let inserted: String
        let firstStart: Int
        if put.before || hasBreak {
            at = put.before ? b.lineStart(line) : NSMaxRange(b.lineRange(at: line))
            inserted = block.map { $0 + lineBreak }.joined()
            firstStart = at
        } else {
            at = b.contentEnd(line)
            inserted = lineBreak + block.joined(separator: lineBreak)
            firstStart = at + lineBreak.utf16.count
        }
        result.edits.append(TextEdit(range: NSRange(location: at, length: 0),
                                     replacement: inserted))
        guard put.cursorAfter else {
            result.window.cursor = firstNonBlank(of: block[0], lineStart: firstStart)
            return
        }
        let end = at + inserted.utf16.count
        if put.before || at < b.length {
            result.window.cursor = end
        } else {
            let lastLine = (block.last ?? "").utf16.count + (hasBreak ? lineBreak.utf16.count : 0)
            result.window.cursor = end - lastLine
        }
    }

    // MARK: Control-A and Control-X

    /// A port of Vim's `do_addsub` outside Visual mode, for decimal numbers and, under
    /// `nrformats`, hex and binary ones. Unlike Vim, the case of hex digits comes from the
    /// number itself rather than from the last number changed when it has no letters.
    private static func addToNumber(subtract: Bool, _ input: CommandInput,
                                    _ result: inout VimResult, _ b: VimBuffer) -> Bool {
        let cursor = result.window.cursor
        let lineStart = b.lineStart(b.lineIndex(of: cursor))
        let content = b.contentRange(at: b.lineIndex(of: cursor))
        let units = (0..<content.length).map { b.text.character(at: content.location + $0) }
        let formats = result.session.options.nrformats.split(separator: ",")
        let number = NumberEdit(units: units, hex: formats.contains("hex"),
                                binary: formats.contains("bin"))
        guard let edit = number.add(UInt64(max(input.count ?? 1, 1)), subtract: subtract,
                                    from: cursor - lineStart) else {
            fail(&result)
            return false
        }
        result.edits.append(TextEdit(range: NSRange(location: lineStart + edit.range.lowerBound,
                                                    length: edit.range.count),
                                     replacement: edit.text))
        result.window.cursor = lineStart + edit.range.lowerBound + edit.text.utf16.count - 1
        result.window.desiredColumn = nil
        return true
    }
}

/// The number Control-A or Control-X changes, found in one line's UTF-16 units.
struct NumberEdit {
    let units: [UInt16]
    let hex: Bool
    let binary: Bool

    private func unit(_ index: Int) -> UInt16 {
        index >= 0 && index < units.count ? units[index] : 0
    }
    private func isDigit(_ index: Int) -> Bool { (0x30...0x39).contains(unit(index)) }
    private func isBinaryDigit(_ index: Int) -> Bool { unit(index) == 0x30 || unit(index) == 0x31 }

    private func isHexDigit(_ index: Int) -> Bool {
        let u = unit(index) | 0x20
        return isDigit(index) || (0x61...0x66).contains(u)
    }

    /// Whether `index` is the `x` or `b` of a `0x` or `0b` prefix followed by a digit.
    private func isPrefix(_ index: Int) -> Bool {
        guard index > 0, unit(index - 1) == 0x30 else { return false }
        let letter = unit(index) | 0x20
        return (hex && letter == 0x78 && isHexDigit(index + 1))
            || (binary && letter == 0x62 && isBinaryDigit(index + 1))
    }

    /// The start of the number at or after `column`: back over binary and hex digits to a
    /// prefix, or else forward to a digit and back to the start of its run.
    private func numberStart(from column: Int) -> Int? {
        guard column < units.count else { return nil }
        var index = column
        if binary { while index > 0 && isBinaryDigit(index) { index -= 1 } }
        if hex { while index > 0 && isHexDigit(index) { index -= 1 } }
        if binary && hex && !(index > 0 && (unit(index) | 0x20) == 0x78 && unit(index - 1) == 0x30
                              && isHexDigit(index + 1)) {
            index = column
            while index > 0 && isDigit(index) { index -= 1 }
        }
        if isPrefix(index) { return index - 1 }
        index = column
        while index < units.count && !isDigit(index) { index += 1 }
        while index > 0 && isDigit(index - 1) { index -= 1 }
        return isDigit(index) ? index : nil
    }

    func add(_ amount: UInt64, subtract: Bool,
                      from column: Int) -> (range: Range<Int>, text: String)? {
        guard var start = numberStart(from: column) else { return nil }
        let firstDigit = unit(start)
        var negative = false
        if start > 0 && unit(start - 1) == 0x2D {
            start -= 1
            negative = true
        }
        let digitsStart = negative ? start + 1 : start
        var parsed = parse(at: digitsStart)
        if parsed.prefix != nil && negative {
            start += 1
            negative = false
        }
        let subtracting = subtract != negative
        let old = parsed.value
        if !parsed.overflow {
            parsed.value = subtracting ? old &- amount : old &+ amount
        }
        if parsed.prefix == nil {
            if subtracting && parsed.value > old {
                parsed.value = 0 &- parsed.value
                negative.toggle()
            } else if !subtracting && parsed.value < old {
                parsed.value = ~parsed.value
                negative.toggle()
            }
            if parsed.value == 0 { negative = false }
        }
        return (start..<parsed.end, format(parsed, negative: negative, firstDigit: firstDigit,
                                    digitsStart: digitsStart))
    }

    private struct Parsed {
        var value: UInt64
        var overflow: Bool
        /// `x`, `X`, `b` or `B`, as written.
        var prefix: UInt16?
        var end: Int
        var uppercase: Bool
    }

    /// Vim's `vim_str2nr`: a number that does not fit is the largest value, with `overflow`.
    private func parse(at start: Int) -> Parsed {
        var index = start
        var prefix: UInt16?
        var base: UInt64 = 10
        if isPrefix(start + 1) {
            prefix = unit(start + 1)
            base = (prefix! | 0x20) == 0x78 ? 16 : 2
            index += 2
        }
        var value: UInt64 = 0
        var overflow = false
        var uppercase = prefix.map { (0x41...0x5A).contains($0) } ?? false
        while let digit = digitValue(index, base: base) {
            let unitValue = unit(index)
            if (0x41...0x46).contains(unitValue) { uppercase = true }
            if (0x61...0x66).contains(unitValue) { uppercase = false }
            let (times, timesOverflow) = value.multipliedReportingOverflow(by: base)
            let (sum, sumOverflow) = times.addingReportingOverflow(digit)
            if timesOverflow || sumOverflow || overflow {
                value = .max
                overflow = true
            } else {
                value = sum
            }
            index += 1
        }
        return Parsed(value: value, overflow: overflow, prefix: prefix, end: index,
                      uppercase: uppercase)
    }

    private func digitValue(_ index: Int, base: UInt64) -> UInt64? {
        let u = unit(index)
        switch base {
        case 2: return isBinaryDigit(index) ? UInt64(u - 0x30) : nil
        case 16:
            if isDigit(index) { return UInt64(u - 0x30) }
            let lower = u | 0x20
            return (0x61...0x66).contains(lower) ? UInt64(lower - 0x61 + 10) : nil
        default: return isDigit(index) ? UInt64(u - 0x30) : nil
        }
    }

    /// The new number, padded with zeros to the old width when the old one started with 0.
    private func format(_ parsed: Parsed, negative: Bool, firstDigit: UInt16,
                        digitsStart: Int) -> String {
        var head = negative ? "-" : ""
        var digits = String(parsed.value)
        if let prefix = parsed.prefix {
            head += "0" + String(UnicodeScalar(UInt8(prefix)))
            digits = prefix | 0x20 == 0x78
                ? String(parsed.value, radix: 16, uppercase: parsed.uppercase)
                : parsed.value == 0 ? "" : String(parsed.value, radix: 2)
        }
        let oldWidth = parsed.end - digitsStart - (parsed.prefix == nil ? 0 : 2)
        if firstDigit == 0x30 && digits.count < oldWidth {
            digits = String(repeating: "0", count: oldWidth - digits.count) + digits
        }
        return head + digits
    }
}

/// Joining and breaking lines, for `J`, `gJ` and `gq`.
enum TextFormat {
    /// Vim's `do_join` with its default `joinspaces`: the indent of each joined line goes,
    /// and one space goes between, two after `.` `!` or `?`, and none after a blank or
    /// before `)` or an empty line. `lastJoin` is where the last line was joined.
    static func join(_ contents: [String], spaces: Bool) -> (text: String, lastJoin: Int) {
        var text = contents[0]
        var lastJoin = 0
        var last = contents[0].last
        var beforeLast = contents[0].dropLast().last
        for content in contents.dropFirst() {
            var line = Substring(content)
            var gap = 0
            if spaces {
                line = line.drop { $0 == " " || $0 == "\t" }
                if let first = line.first, first != ")", !text.isEmpty, last != "\t" {
                    if last == " " { last = beforeLast } else { gap += 1 }
                    if last == "." || last == "?" || last == "!" { gap += 1 }
                }
            }
            lastJoin = text.utf16.count
            text += String(repeating: " ", count: gap) + line
            last = spaces ? line.last : nil
            beforeLast = spaces ? line.dropLast().last : nil
        }
        return (text, lastJoin)
    }

    static func leadingBlanks(of line: String) -> String {
        String(line.prefix { $0 == " " || $0 == "\t" })
    }

    /// Breaks `line` at its blanks, after its indent, so that each piece fits in `width`
    /// columns. A word wider than that stays whole on its own line.
    static func wrap(_ line: String, width: Int, nextIndent: String, tabstop: Int) -> [String] {
        var pieces: [String] = []
        var rest = Array(line)
        while displayWidth(rest, tabstop: tabstop) > width {
            let indentEnd = rest.firstIndex { $0 != " " && $0 != "\t" } ?? rest.count
            var runs: [Range<Int>] = []
            var index = indentEnd
            while index < rest.count {
                guard rest[index] == " " || rest[index] == "\t" else {
                    index += 1
                    continue
                }
                let start = index
                while index < rest.count && (rest[index] == " " || rest[index] == "\t") {
                    index += 1
                }
                runs.append(start..<index)
            }
            let fitting = runs.last {
                displayWidth(rest[..<$0.lowerBound], tabstop: tabstop) <= width
            }
            guard let run = fitting ?? runs.first, run.upperBound < rest.count else { break }
            pieces.append(String(rest[..<run.lowerBound]))
            rest = Array(nextIndent) + rest[run.upperBound...]
        }
        pieces.append(String(rest))
        return pieces
    }

    static func displayWidth<C: Collection>(_ characters: C, tabstop: Int) -> Int
    where C.Element == Character {
        characters.reduce(0) { column, character in
            character == "\t" && tabstop > 0 ? (column / tabstop + 1) * tabstop : column + 1
        }
    }

    /// Vim's `]p` indent: the first non-empty line takes `width`, later lines move by the
    /// same amount, and empty lines stay empty.
    static func reindent(_ lines: [String], to width: Int, _ options: VimOptions) -> [String] {
        var shift: Int?
        return lines.map { line in
            guard !line.isEmpty else { return line }
            let indent = leadingBlanks(of: line)
            let old = displayWidth(Array(indent), tabstop: options.tabstop)
            let delta = shift ?? width - old
            shift = delta
            return VimEngine.indentText(width: max(old + delta, 0), options)
                + line.dropFirst(indent.count)
        }
    }
}
