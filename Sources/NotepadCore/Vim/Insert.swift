import Foundation

/// Insert and Replace mode, after Vim's `edit()` with its default
/// `backspace=indent,eol,start`. The adapter lets AppKit insert typed text and reports it
/// through `recordTyped`; the engine handles the special keys, and types every key itself
/// when it replays them for `.`, a macro or a count.
extension VimEngine {
    private static let controlR = VimKey(.character("r"), control: true)

    /// Escape, and Control-C and Control-[, which leave Insert mode and cancel a pending
    /// command as Escape does. Escape counts with any modifier.
    static func isEscape(_ key: VimKey) -> Bool {
        key.base == .escape || key == VimKey(.character("c"), control: true)
            || key == VimKey(.character("["), control: true)
    }

    /// Records `text`, which AppKit has already inserted at the cursor while typing in
    /// Insert mode, as typed keys: `.`, a count and a macro recording see it as if the
    /// engine had typed it. Outside Insert and Replace mode it does nothing.
    public static func recordTyped(_ text: String, window: VimWindowState,
                                   session: VimSession) -> VimResult {
        var result = VimResult(window: window, session: session, edits: [], selections: [],
                               effects: [])
        guard window.mode == .insert || window.mode == .replace else { return result }
        let keys = text.map { VimKey(.character($0)) }
        result.window.changeInProgress?.keys += keys
        result.window.insertSession?.typed += keys
        if window.mode == .replace {
            result.window.insertSession?.overwritten += keys.map { _ in nil }
        }
        result.window.cursor += text.utf16.count
        result.session.recording?.keys += keys
        result.selections = [NSRange(location: result.window.cursor, length: 0)]
        return result
    }

    static func insertMode(_ key: VimKey, _ result: inout VimResult, _ b: VimBuffer,
                           _ clipboard: () -> String?) {
        result.window.changeInProgress?.keys.append(key)
        if result.window.pendingKeys.isEmpty && isEscape(key) {
            finishInsert(&result, b, clipboard)
            return
        }
        result.window.insertSession?.typed.append(key)
        insertKey(key, &result, b, clipboard)
    }

    /// One key in Insert or Replace mode other than the Escape that ends it.
    private static func insertKey(_ key: VimKey, _ result: inout VimResult, _ b: VimBuffer,
                                  _ clipboard: () -> String?) {
        if !result.window.pendingKeys.isEmpty {
            registerKey(key, &result, b, clipboard)
            return
        }
        switch (key.base, key.control) {
        case (.backspace, _), (.character("h"), true): erase(.character, &result, b)
        case (.character("w"), true): erase(.word, &result, b)
        case (.character("u"), true): erase(.line, &result, b)
        case (.character("t"), true): shiftIndent(right: true, &result, b)
        case (.character("d"), true): shiftIndent(right: false, &result, b)
        case (.character("r"), true): result.window.pendingKeys = [key]
        case (.character("j"), true), (.character("m"), true): type(VimKey(.enter), &result, b)
        case (.character("i"), true): type(VimKey(.tab), &result, b)
        case (.character, _), (.escape, _), (.enter, _), (.tab, _), (.up, _), (.down, _),
             (.left, _), (.right, _), (.home, _), (.end, _), (.pageUp, _), (.pageDown, _),
             (.delete, _):
            type(key, &result, b)
        }
    }

    /// The key after Control-R: Control-R, Control-O or Control-P (all inserting literally
    /// here) wait for the register name. An invalid or empty register inserts nothing.
    private static func registerKey(_ key: VimKey, _ result: inout VimResult, _ b: VimBuffer,
                                    _ clipboard: () -> String?) {
        let literally = [controlR, VimKey(.character("o"), control: true),
                         VimKey(.character("p"), control: true)]
        if result.window.pendingKeys.count == 1 && literally.contains(key) {
            result.window.pendingKeys.append(key)
            return
        }
        result.window.pendingKeys = []
        guard let name = key.argumentCharacter, isRegisterName(name),
              let value = result.session.registers.value(name, clipboard: clipboard)
        else { return }
        let lineBreak = b.lineBreak(near: b.lineIndex(of: result.window.cursor))
        let firstLine = value.text.prefix { $0 != "\n" }.count
        insert(value.text.replacingOccurrences(of: "\n", with: lineBreak),
               overwriting: firstLine, &result, b)
    }

    private static func type(_ key: VimKey, _ result: inout VimResult, _ b: VimBuffer) {
        let cursor = result.window.cursor
        let line = b.lineIndex(of: cursor)
        guard let text = typedText(key, after: b.substring(b.lineStart(line)..<cursor),
                                   result.session.options, lineBreak: b.lineBreak(near: line))
        else { return }
        insert(text, overwriting: key == VimKey(.enter) ? 0 : 1, &result, b)
    }

    /// Inserts `text` at the cursor. In Replace mode it first overwrites up to `count`
    /// graphemes of the line, and remembers them for Backspace.
    private static func insert(_ text: String, overwriting count: Int,
                               _ result: inout VimResult, _ b: VimBuffer) {
        let cursor = result.window.cursor
        var end = cursor
        if result.window.mode == .replace {
            var originals: [String] = []
            while originals.count < count, !b.isLineEnd(end),
                  let next = b.nextGrapheme(after: end) {
                originals.append(b.substring(end..<next))
                end = next
            }
            result.window.insertSession?.overwritten += (0..<text.count).map {
                $0 < originals.count ? originals[$0] : nil
            }
        }
        result.edits.append(TextEdit(range: NSRange(location: cursor, length: end - cursor),
                                     replacement: text))
        result.window.cursor = cursor + text.utf16.count
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

    // MARK: Backspace, Control-W and Control-U

    private enum Erase { case character, word, line }

    /// Vim's `ins_bs`: deletes back to where `kind` stops, joining lines at a line start. In
    /// Replace mode each grapheme typed in this session gets its original back instead, and
    /// the cursor only moves over the rest.
    private static func erase(_ kind: Erase, _ result: inout VimResult, _ b: VimBuffer) {
        guard var session = result.window.insertSession, result.window.cursor > 0 else { return }
        let cursor = result.window.cursor
        let from = eraseStart(kind, cursor, session.start, result.session.options, b)
        var replacement = ""
        if result.window.mode == .replace {
            var position = cursor
            while position > from, let previous = b.previousGrapheme(before: position) {
                let kept = session.overwritten.isEmpty ? b.substring(previous..<position)
                    : session.overwritten.removeLast()
                replacement = (kept ?? "") + replacement
                position = previous
            }
        }
        result.edits.append(TextEdit(range: NSRange(location: from, length: cursor - from),
                                     replacement: replacement))
        result.window.cursor = from
        session.start = min(session.start, from)
        result.window.insertSession = session
    }

    /// Where `kind` stops erasing back from `cursor`. Control-W and Control-U delete at least
    /// one grapheme, then stop at `start`; Control-U keeps the indent under `autoindent`.
    private static func eraseStart(_ kind: Erase, _ cursor: Int, _ start: Int,
                                   _ options: VimOptions, _ b: VimBuffer) -> Int {
        let line = b.lineIndex(of: cursor)
        let lineStart = b.lineStart(line)
        guard cursor > lineStart else { return b.previousGrapheme(before: cursor) ?? cursor }
        var position = cursor
        switch kind {
        case .character:
            return b.previousGrapheme(before: cursor) ?? lineStart
        case .word:
            var wordClass: VimBuffer.WordClass?
            repeat {
                guard let previous = b.previousGrapheme(before: position) else { break }
                let previousClass = b.wordClass(at: previous, bigWord: false)
                if let wordClass, previousClass != wordClass { break }
                if previousClass != .blank { wordClass = previousClass }
                position = previous
            } while position > lineStart && position != start
        case .line:
            let firstNonBlank = b.firstNonBlank(line: line)
            let floor = options.autoindent && cursor > firstNonBlank ? firstNonBlank : lineStart
            repeat {
                position = b.previousGrapheme(before: position) ?? lineStart
            } while position > floor && position != start
        }
        return position
    }

    // MARK: Control-T and Control-D

    /// Moves the line's indent to the next or previous multiple of `shiftwidth`, keeping the
    /// cursor on its character, or, in the indent, the same distance from the indent's end.
    private static func shiftIndent(right: Bool, _ result: inout VimResult, _ b: VimBuffer) {
        let options = result.session.options
        let width = options.shiftwidth > 0 ? options.shiftwidth : options.tabstop
        let cursor = result.window.cursor
        let line = b.lineIndex(of: cursor)
        let lineStart = b.lineStart(line)
        let firstNonBlank = b.firstNonBlank(line: line)
        let old = b.indentWidth(line: line, tabstop: options.tabstop)
        let new = right ? (old / width + 1) * width : max((old - 1) / width * width, 0)
        guard new != old, width > 0 else { return }
        let indent = indentText(width: new, options)
        result.edits.append(TextEdit(range: NSRange(location: lineStart,
                                                    length: firstNonBlank - lineStart),
                                     replacement: indent))
        let delta = lineStart + indent.utf16.count - firstNonBlank
        if cursor >= firstNonBlank {
            result.window.cursor = cursor + delta
        } else {
            let column = b.displayColumn(of: cursor, tabstop: options.tabstop) + new - old
            result.window.cursor = lineStart + units(of: indent, upTo: max(column, 0),
                                                     tabstop: options.tabstop)
        }
        guard var session = result.window.insertSession else { return }
        session.start = session.start >= firstNonBlank ? session.start + delta
            : min(session.start, result.window.cursor)
        result.window.insertSession = session
    }

    /// The UTF-16 length of the start of `indent` that reaches screen column `column`.
    private static func units(of indent: String, upTo column: Int, tabstop: Int) -> Int {
        var reached = 0
        var units = 0
        for character in indent where reached < column {
            reached = character == "\t" ? (reached / tabstop + 1) * tabstop : reached + 1
            units += 1
        }
        return units
    }

    // MARK: Escape

    /// Escape: types the keys again for the extra copies a count asks for, sets the `^`
    /// mark and the `.` register, records the change for `.`, and steps the cursor left as
    /// Vim does.
    private static func finishInsert(_ result: inout VimResult, _ b: VimBuffer,
                                     _ clipboard: () -> String?) {
        let cursor = result.window.cursor
        let session = result.window.insertSession ?? InsertSession(start: cursor)
        var stop = b.mark(at: cursor)
        var normal = b.isLineStart(cursor) ? cursor : b.previousGrapheme(before: cursor) ?? cursor
        if let copies = typeCopies(session, &result, b, clipboard) {
            stop = copies.stop
            normal = copies.normal
        }
        result.window.marks["^"] = stop
        result.window.cursor = normal
        result.session.registers.setReadOnly(".", dotRegisterText(session.typed, result,
                                                                  clipboard))
        if let change = result.window.changeInProgress { result.session.lastChange = change }
        result.window.mode = .normal
        result.window.insertSession = nil
        result.window.changeInProgress = nil
        result.window.desiredColumn = nil
        if let block = session.block { finishBlockInsert(block, typedUpTo: cursor, &result, b) }
    }

    /// Types the session's keys `count - 1` more times on a copy of the lines the session
    /// typed on, so that Backspace and the other keys act as they did, and replaces those
    /// lines with the copy. Returns the `^` mark and the Normal-mode cursor.
    private static func typeCopies(_ session: InsertSession, _ result: inout VimResult,
                                   _ b: VimBuffer,
                                   _ clipboard: () -> String?) -> (stop: Mark, normal: Int)? {
        guard session.count > 1, !session.typed.isEmpty else { return nil }
        let cursor = result.window.cursor
        let firstLine = b.lineIndex(of: min(session.start, cursor))
        let lastLine = b.lineIndex(of: cursor)
        let regionStart = b.lineStart(firstLine)
        let region = NSRange(location: regionStart, length: b.contentEnd(lastLine) - regionStart)
        let lineBreak = b.lineBreak(near: lastLine)
        let text = NSMutableString(string: b.substring(region) + lineBreak)
        var copy = result
        copy.window.cursor = cursor - regionStart
        copy.window.pendingKeys = []
        copy.window.insertSession?.start = max(session.start - regionStart, 0)
        for _ in 1..<session.count {
            text.insert(session.repeatPrefix, at: copy.window.cursor)
            copy.window.cursor += session.repeatPrefix.utf16.count
            typeKeys(session.typed, into: text, &copy, clipboard)
        }
        text.deleteCharacters(in: NSRange(location: text.length - lineBreak.utf16.count,
                                          length: lineBreak.utf16.count))
        result.edits.append(TextEdit(range: region, replacement: text as String))
        let typed = VimBuffer(NSString(string: text))
        let end = copy.window.cursor
        let mark = typed.mark(at: end)
        let normal = typed.isLineStart(end) ? end : typed.previousGrapheme(before: end) ?? end
        return (Mark(line: firstLine + mark.line, column: mark.column), regionStart + normal)
    }

    /// What the `.` register holds, as Vim keeps the typed keys: the keys typed again on
    /// empty text without `expandtab` and `autoindent`, so Tab and Enter stay as typed and
    /// Backspace, Control-W and Control-U take back what they deleted. Control-T and
    /// Control-D, which change the indent rather than type, are left out.
    private static func dotRegisterText(_ keys: [VimKey], _ result: VimResult,
                                        _ clipboard: () -> String?) -> String {
        var typing = result
        typing.window.mode = .insert
        typing.window.cursor = 0
        typing.window.pendingKeys = []
        typing.window.insertSession = InsertSession(start: 0)
        typing.session.options.expandtab = false
        typing.session.options.autoindent = false
        let indentKeys = [VimKey(.character("t"), control: true),
                          VimKey(.character("d"), control: true)]
        let text = NSMutableString()
        typeKeys(keys.filter { !indentKeys.contains($0) }, into: text, &typing, clipboard)
        return text as String
    }

    /// Types `keys` into `text`, which `typing`'s window shows, building a buffer only for
    /// keys other than plain characters in Insert mode.
    private static func typeKeys(_ keys: [VimKey], into text: NSMutableString,
                                 _ typing: inout VimResult, _ clipboard: () -> String?) {
        for key in keys {
            if typing.window.mode == .insert, typing.window.pendingKeys.isEmpty, !key.control,
               case .character(let character) = key.base {
                let typed = String(character)
                text.insert(typed, at: typing.window.cursor)
                typing.window.cursor += typed.utf16.count
                continue
            }
            typing.edits = []
            insertKey(key, &typing, VimBuffer(NSString(string: text)), clipboard)
            for edit in typing.edits {
                text.replaceCharacters(in: edit.range, with: edit.replacement)
            }
        }
    }
}
