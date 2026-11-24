import Foundation

/// How an operator treats the text between the cursor and a motion's target.
enum MotionKind: Equatable {
    case exclusive, inclusive, linewise
}

/// Where a motion goes. Operators use the same targets as cursor movement.
struct MotionTarget: Equatable {
    var offset: Int
    var kind: MotionKind
    /// The desired column to keep afterwards, as `j`, `k`, `$` and `|` do. Nil resets it to
    /// the cursor's own column.
    var desiredColumn: Int?
    /// Set when the motion ran into an end of the text but still moved.
    var shortfall: Shortfall?
    /// Vim's `CA_NO_ADJ_OP_END`: an operator keeps an exclusive end in the first column
    /// instead of moving it back to the previous line, as `d<BS>` deletes only a line break.
    var keepsEnd = false

    init(_ offset: Int, _ kind: MotionKind, desiredColumn: Int? = nil,
         shortfall: Shortfall? = nil) {
        self.offset = offset
        self.kind = kind
        self.desiredColumn = desiredColumn
        self.shortfall = shortfall
    }
}

/// Vim's two ways of reporting a word motion that ran out of text.
enum Shortfall: Equatable {
    /// `w` and `e`: Vim beeps only without an operator; an operator still acts.
    case beepWithoutOperator
    /// `b` and `ge`: Vim's `clearopbeep` beeps and cancels any operator.
    case cancelOperator
}

/// A motion that could not move. `message` is Vim's error text, when Vim shows one.
struct MotionFailure: Error, Equatable {
    var message: String?
}

enum Motion: Equatable {
    case left, right, up, down
    /// Backspace and Space, which wrap across lines under Vim's default `whichwrap=b,s`.
    case leftWrapping, rightWrapping
    case screenUp, screenDown
    /// `-`, `+` (and Enter), and `_`.
    case previousLineStart, nextLineStart, currentLineStart
    case wordForward(big: Bool), wordBackward(big: Bool)
    case wordEnd(big: Bool), wordEndBackward(big: Bool)
    /// `0`, `^`, `$`, `g_` and `|`.
    case lineStart, firstNonBlank, lineEnd, lastNonBlank, column
    case firstLine, lastLine
    case find(LastFind)
    /// `;`, and `,` when reversed.
    case repeatFind(reversed: Bool)
    case sentenceBackward, sentenceForward, paragraphBackward, paragraphForward
    /// `%`: the matching bracket, or with a count, that percentage of the lines.
    case matchingPair
    case screenTop, screenMiddle, screenBottom
    /// `` `x `` when `exact`, otherwise `'x`.
    case mark(Character, exact: Bool)

    /// Whether a delete with this motion always fills register 1, even within one line, as
    /// Vim does for `%`, `(`, `)`, `` ` ``, `{` and `}`.
    var deletesIntoRegisterOne: Bool {
        switch self {
        case .sentenceBackward, .sentenceForward, .paragraphBackward, .paragraphForward,
             .matchingPair:
            return true
        case .mark(_, let exact):
            return exact
        case .left, .right, .up, .down, .leftWrapping, .rightWrapping, .screenUp, .screenDown,
             .previousLineStart, .nextLineStart, .currentLineStart, .wordForward, .wordBackward,
             .wordEnd, .wordEndBackward, .lineStart, .firstNonBlank, .lineEnd, .lastNonBlank,
             .column, .firstLine, .lastLine, .find, .repeatFind, .screenTop, .screenMiddle,
             .screenBottom:
            return false
        }
    }

    /// Whether Vim records the starting position in the jump list and the `'` mark.
    var isJump: Bool {
        switch self {
        case .firstLine, .lastLine, .sentenceBackward, .sentenceForward, .paragraphBackward,
             .paragraphForward, .matchingPair, .screenTop, .screenMiddle, .screenBottom, .mark:
            return true
        case .left, .right, .up, .down, .leftWrapping, .rightWrapping, .screenUp, .screenDown,
             .previousLineStart, .nextLineStart, .currentLineStart, .wordForward, .wordBackward,
             .wordEnd, .wordEndBackward, .lineStart, .firstNonBlank, .lineEnd, .lastNonBlank,
             .column, .find, .repeatFind:
            return false
        }
    }
}

enum KeyParse<Command> {
    case incomplete
    case unknown
    case complete(Command)

    func map<Other>(_ transform: (Command) -> Other) -> KeyParse<Other> {
        switch self {
        case .incomplete: return .incomplete
        case .unknown: return .unknown
        case .complete(let command): return .complete(transform(command))
        }
    }
}

extension Motion {
    /// Reads a motion from the keys typed after any count and register.
    static func parse(_ keys: [VimKey]) -> KeyParse<Motion> {
        guard let first = keys.first else { return .incomplete }
        guard !first.control else { return .unknown }
        switch first.base {
        case .left: return .complete(.left)
        case .right: return .complete(.right)
        case .up: return .complete(.up)
        case .down: return .complete(.down)
        case .home: return .complete(.lineStart)
        case .end: return .complete(.lineEnd)
        case .backspace: return .complete(.leftWrapping)
        case .enter: return .complete(.nextLineStart)
        case .escape, .tab, .pageUp, .pageDown, .delete: return .unknown
        case .character(let character):
            return parse(character, then: keys.count > 1 ? keys[1] : nil)
        }
    }

    private static let singleKey: [Character: Motion] = [
        "h": .left, "l": .right, "k": .up, "j": .down, " ": .rightWrapping,
        "w": .wordForward(big: false), "W": .wordForward(big: true),
        "b": .wordBackward(big: false), "B": .wordBackward(big: true),
        "e": .wordEnd(big: false), "E": .wordEnd(big: true),
        "0": .lineStart, "^": .firstNonBlank, "$": .lineEnd, "|": .column, "G": .lastLine,
        "-": .previousLineStart, "+": .nextLineStart, "_": .currentLineStart,
        "(": .sentenceBackward, ")": .sentenceForward,
        "{": .paragraphBackward, "}": .paragraphForward, "%": .matchingPair,
        "H": .screenTop, "M": .screenMiddle, "L": .screenBottom,
        ";": .repeatFind(reversed: false), ",": .repeatFind(reversed: true),
    ]

    private static let findKinds: [Character: FindKind] = [
        "f": .forward, "F": .backward, "t": .tillForward, "T": .tillBackward,
    ]

    private static func parse(_ character: Character, then second: VimKey?) -> KeyParse<Motion> {
        if let motion = singleKey[character] { return .complete(motion) }
        let needsArgument = character == "g" || character == "`" || character == "'"
            || findKinds[character] != nil
        guard needsArgument else { return .unknown }
        guard let second else { return .incomplete }
        if character == "g" { return parseG(second) }
        guard let argument = second.argumentCharacter else { return .unknown }
        if let kind = findKinds[character] {
            return .complete(.find(LastFind(character: argument, kind: kind)))
        }
        return .complete(.mark(argument, exact: character == "`"))
    }

    private static func parseG(_ second: VimKey) -> KeyParse<Motion> {
        guard !second.control else { return .unknown }
        switch second.base {
        case .character("g"): return .complete(.firstLine)
        case .character("j"), .down: return .complete(.screenDown)
        case .character("k"), .up: return .complete(.screenUp)
        case .character("e"): return .complete(.wordEndBackward(big: false))
        case .character("E"): return .complete(.wordEndBackward(big: true))
        case .character("_"): return .complete(.lastNonBlank)
        default: return .unknown
        }
    }
}

extension VimKey {
    /// The character a key stands for after `f`, `m` and the like, if it is one.
    var argumentCharacter: Character? {
        guard !control else { return nil }
        switch base {
        case .character(let character): return character
        case .tab: return "\t"
        case .escape, .enter, .backspace, .up, .down, .left, .right, .home, .end, .pageUp,
             .pageDown, .delete:
            return nil
        }
    }
}

/// What a motion may read besides the text.
struct MotionContext {
    let buffer: VimBuffer
    let options: VimOptions
    let screen: ScreenGeometry
    let desiredColumn: Int?
    let marks: [Character: Mark]
    let lastVisual: LastVisual?
    let lastFind: LastFind?
    /// With an operator, `w` stops at the end of the line, `l` may take the last character,
    /// and `h` and `l` that cannot move give empty text instead of failing, as in Vim.
    var operatorPending = false
    /// The pending operator is `d` or `c`, for which Backspace at a line start stops on the
    /// line break before it.
    var operatorDeletes = false
    /// In Visual mode the cursor may also rest after the last character of a line, where
    /// `l`, `j`, `k` and `$` can take it, as Vim's `coladvance` allows there.
    var visual = false
}

enum Motions {
    typealias Outcome = Result<MotionTarget, MotionFailure>

    static func target(of motion: Motion, count: Int?, from cursor: Int,
                       in context: MotionContext) -> Outcome {
        let b = context.buffer
        let count1 = max(count ?? 1, 1)
        switch motion {
        case .left: return left(cursor, count1, wrapping: false, context)
        case .leftWrapping: return left(cursor, count1, wrapping: true, context)
        case .right: return right(cursor, count1, wrapping: false, context)
        case .rightWrapping: return right(cursor, count1, wrapping: true, context)
        case .up, .down: return vertical(cursor, motion == .down ? count1 : -count1, context)
        case .screenUp, .screenDown:
            let moved = context.screen.moveScreenLines(cursor, motion == .screenDown
                ? count1 : -count1)
            let offset = normalPosition(moved, in: b)
            return offset == cursor ? .failure(MotionFailure()) : .success(MotionTarget(offset,
                .exclusive))
        case .previousLineStart, .nextLineStart, .currentLineStart:
            let delta = motion == .previousLineStart ? -count1
                : motion == .nextLineStart ? count1 : count1 - 1
            return lineMove(cursor, delta, b).map { firstNonBlank($0, b) }
        case .wordForward(let big): return wordForward(cursor, count1, big: big, context)
        case .wordBackward(let big): return wordBackward(cursor, count1, big: big, b)
        case .wordEnd(let big): return wordEnd(cursor, count1, big: big, b)
        case .wordEndBackward(let big): return wordEndBackward(cursor, count1, big: big, b)
        case .lineStart:
            return .success(MotionTarget(b.lineStart(b.lineIndex(of: cursor)), .exclusive))
        case .firstNonBlank:
            let offset = normalPosition(b.firstNonBlank(line: b.lineIndex(of: cursor)), in: b)
            return .success(MotionTarget(offset, .exclusive))
        case .lineEnd: return lineEnd(cursor, count1, visual: context.visual, b)
        case .lastNonBlank: return lastNonBlank(cursor, count1, b)
        case .column:
            let column = count1 - 1
            let offset = b.offset(line: b.lineIndex(of: cursor), displayColumn: column,
                                  tabstop: context.options.tabstop)
            return .success(MotionTarget(normalPosition(offset, in: b), .exclusive,
                                         desiredColumn: column))
        case .firstLine, .lastLine:
            let line = count.map { $0 - 1 } ?? (motion == .firstLine ? 0 : b.lineCount - 1)
            return .success(firstNonBlank(min(max(line, 0), b.lineCount - 1), b))
        case .find(let find): return self.find(find, count1, from: cursor, repeated: false, b)
        case .repeatFind(let reversed):
            guard var find = context.lastFind else { return .failure(MotionFailure()) }
            if reversed { find.kind = find.kind.reversed }
            return self.find(find, count1, from: cursor, repeated: count == nil, b)
        case .sentenceBackward, .sentenceForward:
            return sentence(forward: motion == .sentenceForward, count1, from: cursor, b)
        case .paragraphBackward, .paragraphForward:
            return paragraph(forward: motion == .paragraphForward, count1, from: cursor, b)
        case .matchingPair:
            guard let count else { return matchingBracket(cursor, b) }
            guard count <= 100 else { return .failure(MotionFailure()) }
            return .success(firstNonBlank((count * b.lineCount + 99) / 100 - 1, b))
        case .screenTop: return .success(firstNonBlank(screenLine(.top, count1, context), b))
        case .screenMiddle:
            return .success(firstNonBlank(screenLine(.middle, count1, context), b))
        case .screenBottom:
            return .success(firstNonBlank(screenLine(.bottom, count1, context), b))
        case .mark(let name, let exact): return mark(name, exact: exact, context)
        }
    }

    /// The nearest place Normal mode may rest: never on a line break, except on an empty
    /// line, and always at the start of a grapheme.
    static func normalPosition(_ offset: Int, in b: VimBuffer) -> Int {
        let content = b.contentRange(at: b.lineIndex(of: offset))
        guard content.length > 0 else { return content.location }
        let last = b.previousGrapheme(before: NSMaxRange(content)) ?? content.location
        let clamped = min(max(offset, content.location), last)
        return b.text.rangeOfComposedCharacterSequence(at: clamped).location
    }

    /// The lines the cursor may rest on when the view shows `top` to `bottom`. `scrolloff`
    /// keeps it away from an edge of the view, except where that edge is an end of the text.
    static func cursorLines(top: Int, bottom: Int, lineCount: Int,
                            scrolloff: Int) -> ClosedRange<Int> {
        let margin = min(scrolloff, max(bottom - top, 0) / 2)
        let low = min(top == 0 ? 0 : top + margin, lineCount - 1)
        let high = min(bottom >= lineCount - 1 ? lineCount - 1 : bottom - margin, lineCount - 1)
        return low...max(high, low)
    }

    static func firstNonBlank(_ line: Int, _ b: VimBuffer) -> MotionTarget {
        MotionTarget(normalPosition(b.firstNonBlank(line: line), in: b), .linewise)
    }

    // MARK: Characters and lines

    private static func left(_ cursor: Int, _ count: Int, wrapping: Bool,
                             _ context: MotionContext) -> Outcome {
        let b = context.buffer
        var offset = cursor
        var keepsEnd = false
        for _ in 0..<count {
            let line = b.lineIndex(of: offset)
            if offset > b.lineStart(line) {
                offset = b.previousGrapheme(before: offset) ?? offset
            } else if wrapping, line > 0 {
                keepsEnd = context.operatorDeletes && !b.isEmptyLine(line - 1)
                offset = keepsEnd ? b.contentEnd(line - 1)
                    : normalPosition(b.contentEnd(line - 1), in: b)
            } else {
                break
            }
        }
        guard offset == cursor, !context.operatorPending else {
            var target = MotionTarget(offset, .exclusive)
            target.keepsEnd = keepsEnd
            return .success(target)
        }
        return .failure(MotionFailure())
    }

    private static func right(_ cursor: Int, _ count: Int, wrapping: Bool,
                              _ context: MotionContext) -> Outcome {
        let b = context.buffer
        var offset = cursor
        var kind = MotionKind.exclusive
        for _ in 0..<count {
            let line = b.lineIndex(of: offset)
            let last = context.visual ? b.contentEnd(line) : normalPosition(b.contentEnd(line),
                                                                            in: b)
            if offset < last {
                offset = b.nextGrapheme(after: offset) ?? offset
            } else if wrapping, line + 1 < b.lineCount {
                if context.operatorPending && kind == .exclusive && !b.isEmptyLine(line) {
                    kind = .inclusive
                } else {
                    offset = b.lineStart(line + 1)
                    kind = .exclusive
                }
            } else if context.operatorPending {
                return .success(MotionTarget(offset, b.isEmptyLine(line) ? .exclusive
                    : .inclusive))
            } else {
                break
            }
        }
        guard offset == cursor, !context.operatorPending else {
            return .success(MotionTarget(offset, kind))
        }
        return .failure(MotionFailure())
    }

    /// Vim's `cursor_down` and `cursor_up`: a count past the last or first line stops there,
    /// but moving from that line fails.
    private static func lineMove(_ cursor: Int, _ delta: Int,
                                 _ b: VimBuffer) -> Result<Int, MotionFailure> {
        let line = b.lineIndex(of: cursor)
        if delta > 0 && line == b.lineCount - 1 || delta < 0 && line == 0 {
            return .failure(MotionFailure())
        }
        return .success(min(max(line + delta, 0), b.lineCount - 1))
    }

    private static func vertical(_ cursor: Int, _ delta: Int,
                                 _ context: MotionContext) -> Outcome {
        let b = context.buffer
        let tabstop = context.options.tabstop
        let want = context.desiredColumn ?? b.displayColumn(of: cursor, tabstop: tabstop)
        return lineMove(cursor, delta, b).map { line in
            let offset = b.offset(line: line, displayColumn: want, tabstop: tabstop)
            return MotionTarget(context.visual ? offset : normalPosition(offset, in: b),
                                .linewise, desiredColumn: want)
        }
    }

    private static func lineEnd(_ cursor: Int, _ count: Int, visual: Bool,
                                _ b: VimBuffer) -> Outcome {
        lineMove(cursor, count - 1, b).map { line in
            let end = b.contentEnd(line)
            return MotionTarget(visual ? end : normalPosition(end, in: b), .inclusive,
                                desiredColumn: Int.max)
        }
    }

    private static func lastNonBlank(_ cursor: Int, _ count: Int, _ b: VimBuffer) -> Outcome {
        lineMove(cursor, count - 1, b).map { line in
            let start = b.lineStart(line)
            var offset = normalPosition(b.contentEnd(line), in: b)
            while offset > start, b.isBlankCharacter(at: offset) {
                offset = b.previousGrapheme(before: offset) ?? start
            }
            return MotionTarget(offset, .inclusive)
        }
    }

    private enum ViewPlace { case top, middle, bottom }

    private static func screenLine(_ place: ViewPlace, _ count: Int,
                                   _ context: MotionContext) -> Int {
        let screen = context.screen
        let lineCount = context.buffer.lineCount
        let top = min(screen.firstVisibleLine, lineCount - 1)
        let bottom = min(max(screen.lastVisibleLine, top), lineCount - 1)
        let allowed = cursorLines(top: top, bottom: bottom, lineCount: lineCount,
                                  scrolloff: context.options.scrolloff)
        let line: Int
        switch place {
        case .top: line = top + count - 1
        case .middle: line = top + (bottom - top + 2) / 2 - 1
        case .bottom: line = max(bottom - (count - 1), 0)
        }
        return min(max(line, allowed.lowerBound), allowed.upperBound)
    }

    // MARK: Words, after Vim's fwd_word, bck_word, end_word and bckend_word

    /// Vim does not leave the cursor on the end of a line it moved onto. With an operator,
    /// the last character is then included.
    private static func adjusted(_ offset: Int, from start: Int, _ kind: MotionKind,
                                 shortfall: Shortfall?, _ b: VimBuffer) -> Outcome {
        guard offset > start, b.isLineEnd(offset), offset > b.lineStart(b.lineIndex(of: offset))
        else { return .success(MotionTarget(offset, kind, shortfall: shortfall)) }
        let previous = b.previousGrapheme(before: offset) ?? offset
        return .success(MotionTarget(previous, .inclusive, shortfall: shortfall))
    }

    private static func wordForward(_ start: Int, _ count: Int, big: Bool,
                                    _ context: MotionContext) -> Outcome {
        var p = start
        let ok = fwdWord(&p, count, big: big, eol: context.operatorPending, context.buffer)
        return adjusted(p, from: start, .exclusive, shortfall: ok ? nil : .beepWithoutOperator,
                        context.buffer)
    }

    /// Vim's `fwd_word`. False when it started at the end of the text.
    static func fwdWord(_ p: inout Int, _ count: Int, big: Bool, eol: Bool,
                        _ b: VimBuffer) -> Bool {
        for remaining in stride(from: count - 1, through: 0, by: -1) {
            let startClass = b.wordClass(p, big)
            let onLastLine = b.lineIndex(of: p) == b.lineCount - 1
            var step = b.inc(&p)
            if step == -1 || (step >= 1 && onLastLine) { return false }
            if step >= 1 && eol && remaining == 0 { return true }
            if startClass != .blank {
                while b.wordClass(p, big) == startClass {
                    step = b.inc(&p)
                    if step == -1 || (step >= 1 && eol && remaining == 0) { return true }
                }
            }
            while b.wordClass(p, big) == .blank {
                if b.isEmptyLineStart(p) { break }
                step = b.inc(&p)
                if step == -1 || (step >= 1 && eol && remaining == 0) { return true }
            }
        }
        return true
    }

    private static func wordBackward(_ start: Int, _ count: Int, big: Bool,
                                     _ b: VimBuffer) -> Outcome {
        var p = start
        for _ in 0..<count {
            if b.dec(&p) == -1 {
                return .success(MotionTarget(p, .exclusive, shortfall: .cancelOperator))
            }
            var onEmptyLine = false
            while b.wordClass(p, big) == .blank {
                if b.isEmptyLineStart(p) {
                    onEmptyLine = true
                    break
                }
                if b.dec(&p) == -1 { return .success(MotionTarget(p, .exclusive)) }
            }
            if !onEmptyLine {
                if b.skip(b.wordClass(p, big), forward: false, big, &p) {
                    return .success(MotionTarget(p, .exclusive))
                }
                _ = b.inc(&p)
            }
        }
        return .success(MotionTarget(p, .exclusive))
    }

    /// `e`, or with `stop`, the target `cw` uses: a cursor already on the end of a word
    /// stays there.
    static func wordEnd(_ start: Int, _ count: Int, big: Bool, stop: Bool = false,
                        _ b: VimBuffer) -> Outcome {
        var p = start
        let ok = endWord(&p, count, big: big, stop: stop, empty: false, b)
        return adjusted(p, from: start, .inclusive, shortfall: ok ? nil : .beepWithoutOperator, b)
    }

    /// Vim's `end_word`. With `empty`, it stops at an empty line. False when it ran into the
    /// end of the text.
    static func endWord(_ p: inout Int, _ count: Int, big: Bool, stop: Bool, empty: Bool,
                        _ b: VimBuffer) -> Bool {
        var stop = stop
        for _ in 0..<count {
            let startClass = b.wordClass(p, big)
            if b.inc(&p) == -1 { return false }
            if b.wordClass(p, big) == startClass && startClass != .blank {
                if b.skip(startClass, forward: true, big, &p) { return false }
                _ = b.dec(&p)
            } else if !stop || startClass == .blank {
                var reachedEmptyLine = false
                while b.wordClass(p, big) == .blank {
                    if empty && b.isEmptyLineStart(p) {
                        reachedEmptyLine = true
                        break
                    }
                    if b.inc(&p) == -1 { return false }
                }
                if !reachedEmptyLine {
                    if b.skip(b.wordClass(p, big), forward: true, big, &p) { return false }
                    _ = b.dec(&p)
                }
            } else {
                _ = b.dec(&p)
            }
            stop = false
        }
        return true
    }

    private static func wordEndBackward(_ start: Int, _ count: Int, big: Bool,
                                        _ b: VimBuffer) -> Outcome {
        var p = start
        for _ in 0..<count {
            let startClass = b.wordClass(p, big)
            if b.dec(&p) == -1 {
                return .success(MotionTarget(p, .inclusive, shortfall: .cancelOperator))
            }
            if startClass != .blank {
                while b.wordClass(p, big) == startClass {
                    if b.dec(&p) == -1 { return .success(MotionTarget(p, .inclusive)) }
                }
            }
            while b.wordClass(p, big) == .blank {
                if b.isEmptyLineStart(p) { break }
                if b.dec(&p) == -1 { return .success(MotionTarget(p, .inclusive)) }
            }
        }
        return .success(MotionTarget(p, .inclusive))
    }

    // MARK: Finding a character

    /// Vim's `searchc`. A repeated `t` or `T` without a count skips a match right next to the
    /// cursor, so `;` always moves (Vim's default `cpoptions` lacks `;`).
    private static func find(_ find: LastFind, _ count: Int, from cursor: Int, repeated: Bool,
                             _ b: VimBuffer) -> Outcome {
        let content = b.contentRange(at: b.lineIndex(of: cursor))
        let forward = find.kind == .forward || find.kind == .tillForward
        let till = find.kind == .tillForward || find.kind == .tillBackward
        var offset = cursor
        var skipNext = repeated && till
        for _ in 0..<count {
            while true {
                guard let next = forward ? b.nextGrapheme(after: offset)
                    : b.previousGrapheme(before: offset),
                      next >= content.location, next < NSMaxRange(content)
                else { return .failure(MotionFailure()) }
                offset = next
                if !skipNext && b.character(at: offset) == find.character { break }
                skipNext = false
            }
        }
        if till {
            offset = (forward ? b.previousGrapheme(before: offset)
                : b.nextGrapheme(after: offset)) ?? offset
        }
        return .success(MotionTarget(offset, forward ? .inclusive : .exclusive))
    }

    // MARK: Sentences and paragraphs, after Vim's findsent and findpar

    private static func sentence(forward: Bool, _ count: Int, from cursor: Int,
                                 _ b: VimBuffer) -> Outcome {
        guard let pos = findSentence(forward: forward, count, from: cursor, b) else {
            return .failure(MotionFailure())
        }
        return adjusted(pos, from: cursor, .exclusive, shortfall: nil, b)
    }

    /// Vim's `findsent`: the start of the sentence `count` sentences away, or nil.
    static func findSentence(forward: Bool, _ count: Int, from cursor: Int,
                             _ b: VimBuffer) -> Int? {
        let step: (inout Int) -> Int = forward ? { b.incl(&$0) } : { b.decl(&$0) }
        var pos = cursor
        var remaining = count
        while remaining > 0 {
            remaining -= 1
            let previous = pos
            var noSkip = false
            var found = false
            if b.unit(at: pos) == 0 {
                repeat {
                    if step(&pos) == -1 { break }
                } while b.unit(at: pos) == 0
                found = forward
            } else if forward, b.isLineStart(pos), b.startsParagraph(b.lineIndex(of: pos)) {
                let line = b.lineIndex(of: pos)
                guard line + 1 < b.lineCount else { return nil }
                pos = b.lineStart(line + 1)
                found = true
            } else if !forward {
                _ = b.decl(&pos)
            }
            if !found {
                backOverSentenceEnd(&pos, forward: forward, b)
                switch sentenceEnd(&pos, forward: forward, remaining: remaining, step, b) {
                case .failed: return nil
                case .hitEnd: noSkip = true
                case .found: break
                }
            }
            while !noSkip, b.unit(at: pos) == 0x20 || b.unit(at: pos) == 0x09 {
                if b.incl(&pos) == -1 { break }
            }
            if pos == previous {
                if step(&pos) == -1 {
                    if remaining > 0 { return nil }
                    break
                }
                remaining += 1
            }
        }
        return pos
    }

    private static let sentenceEnders: Set<UInt16> = [0x2E, 0x21, 0x3F]
    private static let closers: Set<UInt16> = [0x29, 0x5D, 0x22, 0x27]

    /// Steps back over blanks and sentence-ending punctuation before the cursor.
    private static func backOverSentenceEnd(_ pos: inout Int, forward: Bool, _ b: VimBuffer) {
        var foundDot = false
        while true {
            let c = b.unit(at: pos)
            guard c == 0x20 || c == 0x09 || sentenceEnders.contains(c) || closers.contains(c)
            else { return }
            var before = pos
            if b.decl(&before) == -1 || (b.isEmptyLine(b.lineIndex(of: before)) && forward) {
                return
            }
            if foundDot { return }
            if sentenceEnders.contains(c) { foundDot = true }
            let beforeUnit = b.unit(at: before)
            if closers.contains(c) && !sentenceEnders.contains(beforeUnit)
                && !closers.contains(beforeUnit) {
                return
            }
            _ = b.decl(&pos)
        }
    }

    private enum SentenceEnd { case found, hitEnd, failed }

    private static func sentenceEnd(_ pos: inout Int, forward: Bool, remaining: Int,
                                    _ step: (inout Int) -> Int, _ b: VimBuffer) -> SentenceEnd {
        let startLine = b.lineIndex(of: pos)
        while true {
            let c = b.unit(at: pos)
            if c == 0 || (b.isLineStart(pos) && b.startsParagraph(b.lineIndex(of: pos))) {
                let line = b.lineIndex(of: pos)
                if !forward && line != startLine { pos = b.lineStart(line + 1) }
                return .found
            }
            if sentenceEnders.contains(c) {
                var after = pos
                var next: UInt16 = 0
                var atEnd = false
                repeat {
                    if b.inc(&after) == -1 {
                        atEnd = true
                        break
                    }
                    next = b.unit(at: after)
                } while closers.contains(next)
                if atEnd || next == 0x20 || next == 0x09 || next == 0 {
                    pos = after
                    if b.unit(at: pos) == 0 { _ = b.inc(&pos) }
                    return .found
                }
            }
            if step(&pos) == -1 { return remaining > 0 ? .failed : .hitEnd }
        }
    }

    private static func paragraph(forward: Bool, _ count: Int, from cursor: Int,
                                  _ b: VimBuffer) -> Outcome {
        let direction = forward ? 1 : -1
        var line = b.lineIndex(of: cursor)
        for remaining in stride(from: count - 1, through: 0, by: -1) {
            var sawText = false
            var first = true
            while true {
                if !b.isEmptyLine(line) { sawText = true }
                if !first && sawText && b.startsParagraph(line) { break }
                line += direction
                if line < 0 || line >= b.lineCount {
                    if remaining > 0 { return .failure(MotionFailure()) }
                    line -= direction
                    break
                }
                first = false
            }
        }
        if forward && line == b.lineCount - 1 && !b.isEmptyLine(line) {
            return .success(MotionTarget(normalPosition(b.contentEnd(line), in: b), .inclusive))
        }
        return .success(MotionTarget(b.lineStart(line), .exclusive))
    }

    // MARK: Brackets and marks

    private static let brackets: [UInt16: (match: UInt16, forward: Bool)] = [
        0x28: (0x29, true), 0x29: (0x28, false), 0x5B: (0x5D, true), 0x5D: (0x5B, false),
        0x7B: (0x7D, true), 0x7D: (0x7B, false),
    ]

    /// The bracket under or after the cursor on its line, matched by nesting depth. Unlike
    /// Vim, brackets inside quotes, comments and after backslashes still count.
    private static func matchingBracket(_ cursor: Int, _ b: VimBuffer) -> Outcome {
        let end = b.contentEnd(b.lineIndex(of: cursor))
        var start = cursor
        while start < end, brackets[b.text.character(at: start)] == nil { start += 1 }
        guard start < end else { return .failure(MotionFailure()) }
        let open = b.text.character(at: start)
        guard let pair = brackets[open] else { return .failure(MotionFailure()) }
        var depth = 0
        var offset = start
        while true {
            offset += pair.forward ? 1 : -1
            guard offset >= 0, offset < b.length else { return .failure(MotionFailure()) }
            let unit = b.text.character(at: offset)
            if unit == open {
                depth += 1
            } else if unit == pair.match {
                if depth == 0 { return .success(MotionTarget(offset, .inclusive)) }
                depth -= 1
            }
        }
    }

    private static func mark(_ name: Character, exact: Bool,
                             _ context: MotionContext) -> Outcome {
        let b = context.buffer
        guard let mark = markPosition(name, context) else {
            return .failure(MotionFailure(message: "E20: Mark not set"))
        }
        guard mark.line < b.lineCount else {
            return .failure(MotionFailure(message: "E19: Mark has invalid line number"))
        }
        guard exact else { return .success(firstNonBlank(mark.line, b)) }
        return .success(MotionTarget(normalPosition(b.offset(of: mark), in: b), .exclusive))
    }

    private static func markPosition(_ name: Character, _ context: MotionContext) -> Mark? {
        switch name {
        case "`", "'": return context.marks["'"]
        case "<", ">":
            guard let visual = context.lastVisual else { return nil }
            let ordered = [visual.anchor, visual.cursor].sorted {
                ($0.line, $0.column) < ($1.line, $1.column)
            }
            var mark = name == "<" ? ordered[0] : ordered[1]
            if visual.mode == .visualLine { mark.column = name == "<" ? 0 : Int.max }
            return mark
        default: return context.marks[name]
        }
    }
}

private extension FindKind {
    var reversed: FindKind {
        switch self {
        case .forward: return .backward
        case .backward: return .forward
        case .tillForward: return .tillBackward
        case .tillBackward: return .tillForward
        }
    }
}

/// Positions in Vim's sense: a line may also be at its end, after the last character, where
/// Vim's `NUL` sits.
extension VimBuffer {
    func lineStart(_ line: Int) -> Int { lineRange(at: line).location }
    func contentEnd(_ line: Int) -> Int { NSMaxRange(contentRange(at: line)) }
    func isEmptyLine(_ line: Int) -> Bool { contentRange(at: line).length == 0 }
    func isLineStart(_ offset: Int) -> Bool { offset == lineStart(lineIndex(of: offset)) }
    func isLineEnd(_ offset: Int) -> Bool { offset == contentEnd(lineIndex(of: offset)) }

    func isEmptyLineStart(_ offset: Int) -> Bool {
        isLineStart(offset) && isEmptyLine(lineIndex(of: offset))
    }

    /// Vim's `startPS` for `(`, `)`, `{` and `}`: an empty line or one starting with a form
    /// feed. Vim's nroff macros (`.PP` and the like) are not recognized.
    func startsParagraph(_ line: Int) -> Bool {
        let content = contentRange(at: line)
        return content.length == 0 || text.character(at: content.location) == 0x0C
    }

    /// The UTF-16 unit at `offset`, or 0 at the end of a line, as Vim's `gchar_pos` gives NUL.
    func unit(at offset: Int) -> UInt16 {
        isLineEnd(offset) ? 0 : text.character(at: offset)
    }

    func character(at offset: Int) -> Character? {
        guard let end = nextGrapheme(after: offset) else { return nil }
        return text.substring(with: NSRange(location: offset, length: end - offset)).first
    }

    func isBlankCharacter(at offset: Int) -> Bool {
        let unit = text.character(at: offset)
        return unit == 0x20 || unit == 0x09
    }

    func mark(at offset: Int) -> Mark {
        let line = lineIndex(of: offset)
        return Mark(line: line, column: offset - lineStart(line))
    }

    /// The offset of `mark`, with its line and column clamped to the text.
    func offset(of mark: Mark) -> Int {
        let content = contentRange(at: min(max(mark.line, 0), lineCount - 1))
        return content.location + min(max(mark.column, 0), content.length)
    }

    /// Vim's `cls()`: the end of a line is blank.
    func wordClass(_ offset: Int, _ bigWord: Bool) -> WordClass {
        isLineEnd(offset) ? .blank : wordClass(at: offset, bigWord: bigWord)
    }

    /// Vim's `inc()`: 0 within the line, 2 onto the line's end, 1 onto the next line, and -1
    /// at the end of the text, where the offset does not change.
    func inc(_ offset: inout Int) -> Int {
        let line = lineIndex(of: offset)
        let end = contentEnd(line)
        if offset < end {
            offset = min(nextGrapheme(after: offset) ?? end, end)
            return offset < end ? 0 : 2
        }
        guard line + 1 < lineCount else { return -1 }
        offset = lineStart(line + 1)
        return 1
    }

    /// Vim's `dec()`: 0 within the line, 1 onto the end of the previous line, and -1 at the
    /// start of the text.
    func dec(_ offset: inout Int) -> Int {
        let line = lineIndex(of: offset)
        let start = lineStart(line)
        if offset > start {
            offset = max(previousGrapheme(before: offset) ?? start, start)
            return 0
        }
        guard line > 0 else { return -1 }
        offset = contentEnd(line - 1)
        return 1
    }

    /// Vim's `incl()`: like `inc()`, but never stops at the end of a non-empty line.
    func incl(_ offset: inout Int) -> Int {
        let result = inc(&offset)
        return result >= 1 && !isLineStart(offset) ? inc(&offset) : result
    }

    /// Vim's `decl()`: like `dec()`, but never stops at the end of a non-empty line.
    func decl(_ offset: inout Int) -> Int {
        let result = dec(&offset)
        return result == 1 && !isLineStart(offset) ? dec(&offset) : result
    }

    /// Vim's `skip_chars()`: moves past graphemes of `wordClass`. True when it hit an end of
    /// the text first.
    func skip(_ wordClass: WordClass, forward: Bool, _ bigWord: Bool,
              _ offset: inout Int) -> Bool {
        while self.wordClass(offset, bigWord) == wordClass {
            if (forward ? inc(&offset) : dec(&offset)) == -1 { return true }
        }
        return false
    }
}
