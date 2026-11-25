import Foundation

/// A search motion as typed.
enum SearchMotion: Equatable {
    /// `/` or `?` and the text submitted at the prompt, with an empty pattern already
    /// replaced by the last one.
    case pattern(LastSearch)
    /// `n`, and `N` when reversed.
    case next(reversed: Bool)
    /// `*` and `#`, or without `whole`, `g*` and `g#`.
    case word(forward: Bool, whole: Bool)

    /// Whether the search becomes the last search; `n` and `N` keep it.
    var isNewSearch: Bool {
        switch self {
        case .pattern, .word: return true
        case .next: return false
        }
    }
}

// MARK: The footer prompt

/// `/`, `?` and `:` open the footer. While it is open, its text waits in the pending keys
/// after the prompt key, so replayed keys such as `/foo<CR>` run here; when the user types,
/// the footer submits its text through `search` or as an ex command instead.
extension VimEngine {
    private static let prompts: Set<Character> = ["/", "?", ":"]

    /// What `:` starts the command line with in Visual mode. `@:` there leaves it out of the
    /// command it repeats, as Vim's `do_execreg` does, so the new selection's range is used.
    static let visualRange = "'<,'>"

    /// Runs a search submitted at the `/` or `?` prompt: `pattern` is the text typed after
    /// the prompt key, with any offset, such as `foo/e`. The window's pending count,
    /// register, operator and Visual selection apply, as when Return is typed.
    public static func search(_ pattern: String, forward: Bool, window: VimWindowState,
                              session: VimSession, buffer: VimBuffer,
                              screen: ScreenGeometry) -> VimResult {
        var result = VimResult(window: window, session: session, edits: [], selections: [],
                               effects: [])
        let typed = pattern.map { VimKey(.character($0)) }
        result.session.recording?.keys += typed + [VimKey(.enter)]
        result.window.pendingKeys = [VimKey(.character(forward ? "/" : "?"))] + typed
        submitCommandLine(&result, buffer, screen, { nil })
        select(&result, buffer)
        return result
    }

    static func isCommandLinePrompt(_ keys: [VimKey]) -> Bool {
        guard let first = keys.first?.argumentCharacter else { return false }
        return prompts.contains(first)
    }

    /// Whether the pending keys are a prompt key that opens the footer: `/` or `?`, or `:`
    /// in Normal or Visual mode, but not the `?` that doubles `g?`. `:` in Visual mode ends
    /// it and starts the line with `'<,'>`; after a count it starts with `.,.+{count-1}`.
    static func opensCommandLine(_ result: inout VimResult, _ buffer: VimBuffer) -> Bool {
        let window = result.window
        guard window.pendingKeys.count == 1, let prompt = window.pendingKeys[0].argumentCharacter,
              prompts.contains(prompt),
              prompt != ":" || window.mode == .normal || window.mode.isVisual,
              window.operatorKeys.last != window.pendingKeys[0]
        else { return false }
        guard prompt == ":" else {
            result.effects.append(.openCommandLine(prompt))
            return true
        }
        var prefill = ""
        if window.mode.isVisual {
            prefill = visualRange
            endVisual(&result, buffer)
        } else if window.count != nil || window.leadingCount != nil {
            let count = (window.leadingCount ?? 1) * (window.count ?? 1)
            prefill = count == 1 ? "." : ".,.+\(count - 1)"
        }
        clearPending(&result.window)
        result.window.pendingKeys = [VimKey(.character(":"))]
            + prefill.map { VimKey(.character($0)) }
        result.effects.append(.openCommandLine(":", prefill: prefill))
        return true
    }

    /// A key typed into an open prompt: Return submits it, Backspace deletes a character or
    /// closes an empty prompt, and a character is added. Escape was handled before.
    static func commandLineKey(_ key: VimKey, _ result: inout VimResult, _ buffer: VimBuffer,
                               _ screen: ScreenGeometry, _ clipboard: () -> String?) {
        switch (key.base, key.control) {
        case (.enter, _), (.character("j"), true), (.character("m"), true):
            submitCommandLine(&result, buffer, screen, clipboard)
        case (.backspace, _), (.character("h"), true):
            result.window.pendingKeys.removeLast()
            if result.window.pendingKeys.isEmpty { clearPending(&result.window) }
        case (.character, false), (.tab, false):
            result.window.pendingKeys.append(key)
        case (.character, true), (.tab, true), (.escape, _), (.up, _), (.down, _), (.left, _),
             (.right, _), (.home, _), (.end, _), (.pageUp, _), (.pageDown, _), (.delete, _):
            return
        }
    }

    /// Return at the prompt: `:` hands its text to the adapter as an ex command, and `/` and
    /// `?` search, as a motion for the pending operator or Visual selection.
    private static func submitCommandLine(_ result: inout VimResult, _ buffer: VimBuffer,
                                          _ screen: ScreenGeometry,
                                          _ clipboard: () -> String?) {
        let keys = result.window.pendingKeys + [VimKey(.enter)]
        let prompt = keys[0].argumentCharacter
        let text = String(keys.dropFirst().compactMap(\.argumentCharacter))
        guard prompt != ":" else {
            clearPending(&result.window)
            if !text.isEmpty { result.session.registers.setReadOnly(":", text) }
            result.effects.append(.ex(text))
            return
        }
        guard let search = parseSearch(text, forward: prompt == "/",
                                       last: result.session.lastSearch) else {
            result.effects.append(.message("E35: No previous regular expression"))
            fail(&result)
            return
        }
        let motion = Motion.search(.pattern(search))
        if result.window.mode == .operatorPending {
            operatePending(on: .motion(motion), keys: keys, &result, buffer, screen)
        } else {
            let input = takeInput(&result.window, keys: keys)
            complete(.motion(motion), input, &result, buffer, screen, clipboard)
        }
    }

    /// The search a prompt's text asks for: the pattern up to an unescaped `/` (or `?`, where
    /// `\?` stands for `?`), then any offset. An empty pattern reuses the last one, and its
    /// offset too unless the text gives one. Nil when there is no last pattern to reuse.
    static func parseSearch(_ text: String, forward: Bool, last: LastSearch?) -> LastSearch? {
        let terminator: Character = forward ? "/" : "?"
        var pattern = ""
        var offset: String?
        var escaped = false
        for (index, character) in zip(text.indices, text) {
            if escaped {
                if character != terminator || forward { pattern.append("\\") }
                pattern.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == terminator {
                offset = String(text[text.index(after: index)...])
                break
            } else {
                pattern.append(character)
            }
        }
        if escaped { pattern.append("\\") }
        guard pattern.isEmpty else {
            return LastSearch(pattern: pattern, forward: forward,
                              offset: searchOffset(offset ?? ""))
        }
        guard var reused = last else { return nil }
        reused.forward = forward
        if let offset { reused.offset = searchOffset(offset) }
        return reused
    }

    /// Vim's `[+-]n`, `e[+-n]`, `s[+-n]` and `b[+-n]`; a sign alone means 1. Anything
    /// else gives no offset.
    static func searchOffset(_ text: String) -> SearchOffset {
        var rest = Substring(text)
        var anchor = SearchOffset.Anchor.line
        if let first = rest.first, "esb".contains(first) {
            anchor = first == "e" ? .end : .start
            rest = rest.dropFirst()
        }
        let sign = rest.first == "-" ? -1 : 1
        let signed = rest.first == "-" || rest.first == "+"
        if signed { rest = rest.dropFirst() }
        let digits = rest.prefix { $0.isASCII && $0.isNumber }.prefix(9)
        if !signed && digits.isEmpty {
            return anchor == .line ? .none : SearchOffset(anchor: anchor, amount: 0)
        }
        return SearchOffset(anchor: anchor, amount: sign * (Int(digits) ?? 1))
    }

    /// What a motion leaves behind for later commands, before it runs: the last `f`, `t`,
    /// `F` or `T`, and for a search, the last pattern, the `/` register and the highlight.
    /// The cursor stays put, so the jump and an operator start there; `*` and `#` search
    /// from the start of the word. False after a failure is reported.
    static func remember(_ motion: Motion, _ result: inout VimResult, _ buffer: VimBuffer,
                         _ screen: ScreenGeometry) -> Bool {
        if case .find(let find) = motion { result.session.lastFind = find }
        guard case .search(let kind) = motion else { return true }
        let context = motionContext(result, buffer, screen)
        switch Motions.searchRequest(kind, from: result.window.cursor, context) {
        case .failure(let failure):
            if let message = failure.message { result.effects.append(.message(message)) }
            fail(&result)
            return false
        case .success(let (search, _)):
            if kind.isNewSearch { result.session.lastSearch = search }
            result.session.registers.setReadOnly("/", search.pattern)
            if result.session.options.hlsearch {
                result.effects.append(.highlightSearch(search.pattern))
            }
            return true
        }
    }
}

// MARK: Finding matches

/// Vim's `searchit` and `do_search` over the whole text, one line at a time in effect:
/// patterns never match a line break.
extension Motions {
    typealias SearchRequest = (search: LastSearch, start: Int)

    /// The search a motion runs and where it starts from.
    static func searchRequest(_ kind: SearchMotion, from cursor: Int,
                              _ context: MotionContext) -> Result<SearchRequest, MotionFailure> {
        switch kind {
        case .pattern(let search):
            return .success((search, cursor))
        case .next(let reversed):
            guard var search = context.lastSearch else {
                return .failure(MotionFailure(message: "E35: No previous regular expression"))
            }
            if reversed { search.forward.toggle() }
            return .success((search, cursor))
        case .word(let forward, let whole):
            let b = context.buffer
            guard let word = identifier(at: cursor, b) else {
                return .failure(MotionFailure(message: "E348: No string under cursor"))
            }
            let keyword = isKeyword(b.wordClass(at: word.location, bigWord: false))
            let escaped = b.substring(word).map { "\\/.*~[^$".contains($0) ? "\\\($0)" : "\($0)" }
            let pattern = whole && keyword ? "\\<" + escaped.joined() + "\\>"
                : escaped.joined()
            return .success((LastSearch(pattern: pattern, forward: forward,
                                        usesSmartCase: false), word.location))
        }
    }

    private static func isKeyword(_ wordClass: VimBuffer.WordClass) -> Bool {
        wordClass != .blank && wordClass != .punctuation
    }

    /// Vim's `find_ident_under_cursor` for `*`: the keyword under or after the cursor in its
    /// line, or else the run of symbols there.
    static func identifier(at cursor: Int, _ b: VimBuffer) -> NSRange? {
        let line = b.lineIndex(of: cursor)
        let end = b.contentEnd(line)
        func next(_ offset: Int) -> Int { b.nextGrapheme(after: offset) ?? end }
        var start = cursor
        while start < end, !isKeyword(b.wordClass(at: start, bigWord: false)) {
            start = next(start)
        }
        if start >= end {
            start = cursor
            while start < end, b.wordClass(at: start, bigWord: false) == .blank {
                start = next(start)
            }
            guard start < end else { return nil }
        }
        let wordClass = b.wordClass(at: start, bigWord: false)
        while let previous = b.previousGrapheme(before: start), previous >= b.lineStart(line),
              b.wordClass(at: previous, bigWord: false) == wordClass {
            start = previous
        }
        var stop = start
        while stop < end, b.wordClass(at: stop, bigWord: false) == wordClass { stop = next(stop) }
        return NSRange(location: start, length: stop - start)
    }

    /// The `count`th match of `search` from `cursor`, with its offset applied.
    static func search(_ search: LastSearch, _ count: Int, from cursor: Int,
                       _ context: MotionContext) -> Outcome {
        let b = context.buffer
        let options = context.options
        let regex: NSRegularExpression
        do {
            regex = try VimPattern.regex(search.pattern, ignoreCase: options.ignorecase,
                                         smartCase: options.smartcase && search.usesSmartCase)
        } catch {
            let message = (error as? VimError)?.message
                ?? "E383: Invalid search string: \(search.pattern)"
            return .failure(MotionFailure(message: message))
        }
        let offset = search.offset
        let toEnd = offset.anchor == .end
        var position = offset.anchor == .line ? cursor
            : stepped(cursor, by: -offset.amount, b, outside: true)
        var wrapped = false
        for _ in 0..<count {
            guard let (match, didWrap) = find(regex, from: position, search.forward,
                                              toEnd: toEnd, wrapscan: options.wrapscan, b)
            else { return .failure(MotionFailure(message: notFound(search, options))) }
            position = toEnd && match.length > 0
                ? b.previousGrapheme(before: NSMaxRange(match)) ?? match.location
                : match.location
            wrapped = wrapped || didWrap
        }
        var target: MotionTarget
        if offset.anchor == .line {
            let line = min(max(b.lineIndex(of: position) + offset.amount, 0), b.lineCount - 1)
            target = MotionTarget(b.lineStart(line), .linewise)
        } else {
            target = MotionTarget(stepped(position, by: offset.amount, b, outside: false),
                                  toEnd ? .inclusive : .exclusive)
        }
        if wrapped {
            target.warning = search.forward ? "search hit BOTTOM, continuing at TOP"
                : "search hit TOP, continuing at BOTTOM"
        }
        return .success(target)
    }

    /// `offset` moved `amount` characters on with Vim's `incl` and `decl`. With `outside`,
    /// running into an end of the text gives a position just outside it, -1 or one past the
    /// length, so that the search after it may take a match at that end.
    private static func stepped(_ offset: Int, by amount: Int, _ b: VimBuffer,
                                outside: Bool) -> Int {
        var position = offset
        for _ in 0..<abs(amount) {
            guard (amount > 0 ? b.incl(&position) : b.decl(&position)) != -1 else {
                return outside ? (amount > 0 ? b.length + 1 : -1) : position
            }
        }
        return position
    }

    private static func notFound(_ search: LastSearch, _ options: VimOptions) -> String {
        if options.wrapscan { return "E486: Pattern not found: \(search.pattern)" }
        return search.forward
            ? "E385: Search hit BOTTOM without match for: \(search.pattern)"
            : "E384: Search hit TOP without match for: \(search.pattern)"
    }

    private static let bounds: NSRegularExpression.MatchingOptions = [
        .withTransparentBounds, .withoutAnchoringBounds,
    ]

    /// The next match in the search's direction, and whether finding it wrapped around.
    private static func find(_ regex: NSRegularExpression, from position: Int, _ forward: Bool,
                             toEnd: Bool, wrapscan: Bool,
                             _ b: VimBuffer) -> (NSRange, Bool)? {
        let found = forward ? nextMatch(regex, after: position, toEnd: toEnd, b)
            : previousMatch(regex, before: position, toEnd: toEnd, b)
        if let found { return (found, false) }
        guard wrapscan else { return nil }
        let wrapped = forward ? nextMatch(regex, after: -1, toEnd: toEnd, b)
            : previousMatch(regex, before: b.length + 1, toEnd: toEnd, b)
        return wrapped.map { ($0, true) }
    }

    /// The first match after `position`. On its own line a match must start after the
    /// character at `position` (a match at the line's end counts as on its last
    /// character), or with `toEnd`, end after it. Matches are taken without overlapping
    /// from the line's start, as Vim's default `cpoptions` with `c` does.
    private static func nextMatch(_ regex: NSRegularExpression, after position: Int,
                                  toEnd: Bool, _ b: VimBuffer) -> NSRange? {
        let text = b.text as String
        let whole = NSRange(location: 0, length: b.length)
        guard position >= 0 else {
            return regex.firstMatch(in: text, options: bounds, range: whole)?.range
        }
        let line = b.lineIndex(of: position)
        let lineStart = b.lineStart(line)
        let lineEnd = b.contentEnd(line)
        let threshold = position >= lineEnd ? position + 1
            : b.nextGrapheme(after: position) ?? position + 1
        var found: NSRange?
        regex.enumerateMatches(in: text, options: bounds,
                               range: NSRange(location: lineStart,
                                              length: b.length - lineStart)) { match, _, stop in
            guard let range = match?.range else { return }
            let atLineEnd = range.location == lineEnd ? 1 : 0
            let accepted = range.location > lineEnd
                || (toEnd ? NSMaxRange(range) - 1 >= threshold
                    : range.location - atLineEnd >= threshold)
            if accepted {
                found = range
                stop.pointee = true
            }
        }
        return found
    }

    /// The last match before `position`: starting before it, or with `toEnd`, ending
    /// before it.
    private static func previousMatch(_ regex: NSRegularExpression, before position: Int,
                                      toEnd: Bool, _ b: VimBuffer) -> NSRange? {
        let end = position > b.length ? b.length : b.contentEnd(b.lineIndex(of: position))
        var found: NSRange?
        regex.enumerateMatches(in: b.text as String, options: bounds,
                               range: NSRange(location: 0, length: end)) { match, _, stop in
            guard let range = match?.range else { return }
            if (toEnd ? NSMaxRange(range) - 1 : range.location) < position {
                found = range
            } else {
                stop.pointee = true
            }
        }
        return found
    }
}
