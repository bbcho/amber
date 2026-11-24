import Foundation

public struct TextEdit: Equatable {
    public var range: NSRange
    public var replacement: String

    public init(range: NSRange, replacement: String) {
        self.range = range
        self.replacement = replacement
    }
}

/// How the adapter should move the view. Lines are logical lines counted from 0.
public enum ScrollRequest: Equatable {
    /// Make `line` the first visible line.
    case top(line: Int)
    case center(line: Int)
    /// Make `line` the last visible line.
    case bottom(line: Int)
}

public enum VimEffect: Equatable {
    case scroll(ScrollRequest)
    case openCommandLine(Character)
    case undo(Int)
    case redo(Int)
    case replay([VimKey])
    case message(String)
    /// Vim's beep. It ends a count, a macro or `:norm`.
    case failure
    case setClipboard(String)
    case highlightSearch(String?)
    case ex(String)
}

public struct VimResult: Equatable {
    public var window: VimWindowState
    public var session: VimSession
    /// Applied in order, each to the text the previous one produced.
    public var edits: [TextEdit]
    public var selections: [NSRange]
    public var effects: [VimEffect]
}

/// A Normal-mode command other than a motion.
enum NormalCommand: Equatable {
    case motion(Motion)
    case scroll(Scroll)
    case jumpOlder, jumpNewer
    case setMark(Character)

    enum Scroll: Equatable {
        /// Control-E and Control-Y.
        case lines(down: Bool)
        /// Control-D and Control-U.
        case halfPage(down: Bool)
        /// Control-F and Control-B.
        case page(down: Bool)
        /// `zt` `zz` `zb`, and with `firstNonBlank`, `z<CR>` `z.` `z-`.
        case cursorLine(ScreenPlace, firstNonBlank: Bool)
    }

    enum ScreenPlace: Equatable {
        case top, center, bottom
    }

    static func parse(_ keys: [VimKey]) -> KeyParse<NormalCommand> {
        guard let first = keys.first else { return .incomplete }
        switch (first.base, first.control) {
        case (.character("e"), true): return .complete(.scroll(.lines(down: true)))
        case (.character("y"), true): return .complete(.scroll(.lines(down: false)))
        case (.character("d"), true): return .complete(.scroll(.halfPage(down: true)))
        case (.character("u"), true): return .complete(.scroll(.halfPage(down: false)))
        case (.character("f"), true), (.pageDown, false):
            return .complete(.scroll(.page(down: true)))
        case (.character("b"), true), (.pageUp, false):
            return .complete(.scroll(.page(down: false)))
        case (.character("o"), true): return .complete(.jumpOlder)
        case (.character("i"), true), (.tab, false): return .complete(.jumpNewer)
        case (.character("z"), false):
            guard keys.count > 1 else { return .incomplete }
            return parseZ(keys[1])
        case (.character("m"), false):
            guard keys.count > 1 else { return .incomplete }
            return keys[1].argumentCharacter.map { .complete(.setMark($0)) } ?? .unknown
        default:
            return Motion.parse(keys).map(NormalCommand.motion)
        }
    }

    private static func parseZ(_ key: VimKey) -> KeyParse<NormalCommand> {
        let place: (ScreenPlace, Bool)
        switch (key.base, key.control) {
        case (.character("t"), false): place = (.top, false)
        case (.character("z"), false): place = (.center, false)
        case (.character("b"), false): place = (.bottom, false)
        case (.enter, false): place = (.top, true)
        case (.character("."), false): place = (.center, true)
        case (.character("-"), false): place = (.bottom, true)
        default: return .unknown
        }
        return .complete(.scroll(.cursorLine(place.0, firstNonBlank: place.1)))
    }
}

/// The pure Vim state machine. The adapter calls `handle` once per key with the current
/// text and applies the result. `handle` builds one `VimBuffer`, which is O(n) in the text's
/// length; a caller with a large document can keep the buffer for an unchanged text by
/// calling `handle(_:window:session:buffer:screen:clipboard:)` directly.
public enum VimEngine {
    public static func handle(_ key: VimKey, window: VimWindowState, session: VimSession,
                              text: NSString, screen: ScreenGeometry,
                              clipboard: () -> String?) -> VimResult {
        handle(key, window: window, session: session, buffer: VimBuffer(text), screen: screen,
               clipboard: clipboard)
    }

    /// `handle` for a caller that keeps the `VimBuffer` of the current text between keys.
    /// The buffer must be built from exactly the text the window is showing.
    public static func handle(_ key: VimKey, window: VimWindowState, session: VimSession,
                              buffer: VimBuffer, screen: ScreenGeometry,
                              clipboard: () -> String?) -> VimResult {
        var result = VimResult(window: window, session: session, edits: [], selections: [],
                               effects: [])
        switch window.mode {
        case .normal:
            normal(key, &result, buffer, screen)
            result.selections = [NSRange(location: result.window.cursor, length: 0)]
        case .insert, .replace, .visual, .visualLine, .visualBlock, .operatorPending,
             .commandLine:
            break
        }
        return result
    }

    // MARK: Normal mode

    private static let maximumCount = 999_999_999

    private static func normal(_ key: VimKey, _ result: inout VimResult, _ buffer: VimBuffer,
                               _ screen: ScreenGeometry) {
        result.window.cursor = Motions.normalPosition(result.window.cursor, in: buffer)
        if key == VimKey(.escape) {
            clearPending(&result.window)
            return
        }
        if result.window.pendingKeys.isEmpty, let digit = countDigit(key, result.window) {
            result.window.count = min((result.window.count ?? 0) * 10 + digit, maximumCount)
            return
        }
        if result.window.pendingKeys == [VimKey(.character("\""))] {
            result.window.pendingKeys = []
            guard let name = key.argumentCharacter, isRegisterName(name) else {
                fail(&result)
                return
            }
            result.window.register = name
            return
        }
        result.window.pendingKeys.append(key)
        if result.window.pendingKeys == [VimKey(.character("\""))] { return }
        switch NormalCommand.parse(result.window.pendingKeys) {
        case .incomplete:
            return
        case .unknown:
            fail(&result)
        case .complete(let command):
            let count = result.window.count
            clearPending(&result.window)
            execute(command, count: count, &result, buffer, screen)
        }
    }

    /// A digit continues a count; `0` starts one only when a count is already under way.
    private static func countDigit(_ key: VimKey, _ window: VimWindowState) -> Int? {
        guard case .character(let character) = key.base, !key.control,
              let digit = character.wholeNumberValue, character.isASCII else { return nil }
        return digit == 0 && window.count == nil ? nil : digit
    }

    private static func isRegisterName(_ name: Character) -> Bool {
        VimRegisters.isWritable(name) || ".:/\"".contains(name)
    }

    private static func clearPending(_ window: inout VimWindowState) {
        window.pendingKeys = []
        window.count = nil
        window.register = nil
    }

    private static func fail(_ result: inout VimResult) {
        clearPending(&result.window)
        result.effects.append(.failure)
    }

    private static func execute(_ command: NormalCommand, count: Int?, _ result: inout VimResult,
                                _ buffer: VimBuffer, _ screen: ScreenGeometry) {
        switch command {
        case .motion(let motion): move(motion, count: count, &result, buffer, screen)
        case .scroll(let scroll): self.scroll(scroll, count: count, &result, buffer, screen)
        case .jumpOlder: jump(by: -(count ?? 1), &result, buffer)
        case .jumpNewer: jump(by: count ?? 1, &result, buffer)
        case .setMark(let name): setMark(name, &result, buffer)
        }
    }

    private static func motionContext(_ result: VimResult, _ buffer: VimBuffer,
                                      _ screen: ScreenGeometry) -> MotionContext {
        MotionContext(buffer: buffer, options: result.session.options, screen: screen,
                      desiredColumn: result.window.desiredColumn, marks: result.window.marks,
                      lastVisual: result.window.lastVisual, lastFind: result.session.lastFind)
    }

    private static func move(_ motion: Motion, count: Int?, _ result: inout VimResult,
                             _ buffer: VimBuffer, _ screen: ScreenGeometry) {
        let context = motionContext(result, buffer, screen)
        if case .find(let find) = motion { result.session.lastFind = find }
        switch Motions.target(of: motion, count: count, from: result.window.cursor,
                              in: context) {
        case .failure(let failure):
            if let message = failure.message { result.effects.append(.message(message)) }
            result.effects.append(.failure)
        case .success(let target):
            if motion.isJump { recordJump(&result.window, buffer) }
            result.window.cursor = Motions.normalPosition(target.offset, in: buffer)
            result.window.desiredColumn = target.desiredColumn
            if target.failed { result.effects.append(.failure) }
        }
    }

    // MARK: Marks and the jump list

    private static let jumpListSize = 100

    /// Vim's `setpcmark`: the cursor becomes the `'` mark and the newest jump.
    private static func recordJump(_ window: inout VimWindowState, _ buffer: VimBuffer) {
        let mark = buffer.mark(at: window.cursor)
        window.marks["'"] = mark
        window.jumpList.append(mark)
        if window.jumpList.count > jumpListSize { window.jumpList.removeFirst() }
        window.jumpIndex = window.jumpList.count
    }

    private static func setMark(_ name: Character, _ result: inout VimResult,
                                _ buffer: VimBuffer) {
        switch name {
        case "'", "`":
            recordJump(&result.window, buffer)
        case "a"..."z", "[", "]":
            result.window.marks[name] = buffer.mark(at: result.window.cursor)
        default:
            result.effects.append(.failure)
        }
    }

    /// Vim's `movemark`, for Control-O (negative) and Control-I.
    private static func jump(by delta: Int, _ result: inout VimResult, _ buffer: VimBuffer) {
        var window = result.window
        removeDuplicateJumps(&window)
        guard window.jumpIndex + delta >= 0,
              window.jumpIndex + delta < window.jumpList.count else {
            result.window = window
            result.effects.append(.failure)
            return
        }
        if window.jumpIndex == window.jumpList.count {
            recordJump(&window, buffer)
            window.jumpIndex -= 1
            guard window.jumpIndex + delta >= 0 else {
                result.window = window
                result.effects.append(.failure)
                return
            }
        }
        window.jumpIndex += delta
        let target = buffer.offset(of: window.jumpList[window.jumpIndex])
        window.cursor = Motions.normalPosition(target, in: buffer)
        window.desiredColumn = nil
        result.window = window
    }

    /// Vim's `cleanup_jumplist`: of several jumps on one line, only the newest stays.
    private static func removeDuplicateJumps(_ window: inout VimWindowState) {
        var kept: [Mark] = []
        var index = window.jumpIndex
        for (position, mark) in window.jumpList.enumerated() {
            if window.jumpIndex == position { index = kept.count }
            let later = window.jumpList[(position + 1)...]
            if !later.contains(where: { $0.line == mark.line }) { kept.append(mark) }
        }
        if window.jumpIndex == window.jumpList.count { index = kept.count }
        window.jumpList = kept
        window.jumpIndex = index
    }

    // MARK: Scrolling

    private static func scroll(_ scroll: NormalCommand.Scroll, count: Int?,
                               _ result: inout VimResult, _ buffer: VimBuffer,
                               _ screen: ScreenGeometry) {
        switch scroll {
        case .lines(let down): scrollLines(down: down, count ?? 1, &result, buffer, screen)
        case .halfPage(let down): scrollHalfPage(down: down, count, &result, buffer, screen)
        case .page(let down): scrollPages(down: down, count ?? 1, &result, buffer, screen)
        case .cursorLine(let place, let firstNonBlank):
            placeCursorLine(place, firstNonBlank: firstNonBlank, count, &result, buffer, screen)
        }
    }

    /// The lines the cursor may rest on once the view starts at `top`. The view is assumed
    /// to hold `linesPerPage` lines, which is exact without wrapping.
    private static func allowedLines(top: Int, _ result: VimResult, _ buffer: VimBuffer,
                                     _ screen: ScreenGeometry) -> ClosedRange<Int> {
        Motions.cursorLines(top: top, bottom: top + max(screen.linesPerPage, 1) - 1,
                            lineCount: buffer.lineCount,
                            scrolloff: result.session.options.scrolloff)
    }

    /// Control-E and Control-Y scroll the view and move the cursor only as far as the view
    /// and `scrolloff` require, keeping the desired column.
    private static func scrollLines(down: Bool, _ count: Int, _ result: inout VimResult,
                                    _ buffer: VimBuffer, _ screen: ScreenGeometry) {
        let top = screen.firstVisibleLine
        let newTop = down ? min(top + count, buffer.lineCount - 1) : max(top - count, 0)
        guard newTop != top else { return }
        result.effects.append(.scroll(.top(line: newTop)))
        let line = buffer.lineIndex(of: result.window.cursor)
        let allowed = allowedLines(top: newTop, result, buffer, screen)
        let target = min(max(line, allowed.lowerBound), allowed.upperBound)
        guard target != line else { return }
        let tabstop = result.session.options.tabstop
        let want = result.window.desiredColumn
            ?? buffer.displayColumn(of: result.window.cursor, tabstop: tabstop)
        let offset = buffer.offset(line: target, displayColumn: want, tabstop: tabstop)
        result.window.cursor = Motions.normalPosition(offset, in: buffer)
        result.window.desiredColumn = want
    }

    /// Control-D and Control-U scroll by the window's scroll amount, stopping once the last
    /// line is in view, and move the cursor by the same amount onto a first non-blank.
    private static func scrollHalfPage(down: Bool, _ count: Int?, _ result: inout VimResult,
                                       _ buffer: VimBuffer, _ screen: ScreenGeometry) {
        if let count { result.window.scrollAmount = count }
        let lines = max(screen.linesPerPage, 1)
        let amount = result.window.scrollAmount ?? max(lines / 2, 1)
        let lastLine = buffer.lineCount - 1
        let line = buffer.lineIndex(of: result.window.cursor)
        guard down ? line < lastLine : line > 0 else {
            result.effects.append(.failure)
            return
        }
        let top = screen.firstVisibleLine
        let newTop = down ? max(top, min(top + amount, lastLine + 1 - lines))
            : max(top - amount, 0)
        if newTop != top { result.effects.append(.scroll(.top(line: newTop))) }
        let moved = down ? min(line + amount, lastLine) : max(line - amount, 0)
        let allowed = allowedLines(top: newTop, result, buffer, screen)
        let target = min(max(moved, allowed.lowerBound), allowed.upperBound)
        result.window.cursor = Motions.firstNonBlank(target, buffer).offset
        result.window.desiredColumn = nil
    }

    /// Control-F and Control-B keep two lines of the old page in view. Control-F at the end
    /// shows only the last line. The cursor goes to the top or bottom of the new page.
    private static func scrollPages(down: Bool, _ count: Int, _ result: inout VimResult,
                                    _ buffer: VimBuffer, _ screen: ScreenGeometry) {
        let lines = max(screen.linesPerPage, 1)
        let lastLine = buffer.lineCount - 1
        let scrolloff = result.session.options.scrolloff
        var top = screen.firstVisibleLine
        var bottom = screen.lastVisibleLine
        var pages = 0
        var stopped = false
        for _ in 0..<count {
            if down {
                let endVisible = bottom >= lastLine
                if endVisible && top >= lastLine - scrolloff {
                    stopped = true
                    break
                }
                top = endVisible ? lastLine : bottom - 1
            } else {
                if top == 0 {
                    stopped = true
                    break
                }
                top = max(top + 1 - (lines - 1), 0)
            }
            bottom = top + lines - 1
            pages += 1
        }
        guard pages > 0 else {
            result.effects.append(.failure)
            return
        }
        result.effects.append(.scroll(.top(line: top)))
        let allowed = allowedLines(top: top, result, buffer, screen)
        let line = down ? allowed.lowerBound : allowed.upperBound
        result.window.cursor = Motions.firstNonBlank(line, buffer).offset
        result.window.desiredColumn = nil
        if stopped { result.effects.append(.failure) }
    }

    /// `zt` `zz` `zb` keep the column; `z<CR>` `z.` `z-` go to the first non-blank. A count
    /// picks the line first.
    private static func placeCursorLine(_ place: NormalCommand.ScreenPlace, firstNonBlank: Bool,
                                        _ count: Int?, _ result: inout VimResult,
                                        _ buffer: VimBuffer, _ screen: ScreenGeometry) {
        let lastLine = buffer.lineCount - 1
        let line = count.map { min($0, buffer.lineCount) - 1 }
            ?? buffer.lineIndex(of: result.window.cursor)
        let margin = min(result.session.options.scrolloff,
                         (max(screen.linesPerPage, 1) - 1) / 2)
        let request: ScrollRequest
        switch place {
        case .top: request = .top(line: max(line - margin, 0))
        case .center: request = .center(line: line)
        case .bottom: request = .bottom(line: min(line + margin, lastLine))
        }
        result.effects.append(.scroll(request))
        if firstNonBlank {
            result.window.cursor = Motions.firstNonBlank(line, buffer).offset
            result.window.desiredColumn = nil
        } else if count != nil {
            let tabstop = result.session.options.tabstop
            let want = result.window.desiredColumn
                ?? buffer.displayColumn(of: result.window.cursor, tabstop: tabstop)
            let offset = buffer.offset(line: line, displayColumn: want, tabstop: tabstop)
            result.window.cursor = Motions.normalPosition(offset, in: buffer)
        }
    }
}
