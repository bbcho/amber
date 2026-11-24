import XCTest
@testable import NotepadCore

/// The state after feeding keys to the engine one at a time, as the adapter would.
struct VimRun {
    var text: String
    var window: VimWindowState
    var session: VimSession
    /// Every effect from every key, in order.
    var effects: [VimEffect]
    /// The first visible line of the fake view after the keys.
    var top: Int
    /// The text with the cursor written as `|` and each selection written as `[...]`. In a
    /// selection the cursor is on the character after the `|`.
    var rendered: String
    /// The selections the last key reported.
    var selections: [NSRange]
}

/// Splits `marked` at its single `|` into the text and the cursor's UTF-16 offset.
func splitCursor(_ marked: String) -> (text: String, cursor: Int) {
    let nsMarked = marked as NSString
    let bar = nsMarked.range(of: "|")
    precondition(bar.location != NSNotFound, "the text needs a | for the cursor")
    return (nsMarked.replacingCharacters(in: bar, with: ""), bar.location)
}

/// Writes `|` at the cursor and `[` and `]` around each non-empty selection. Where they meet,
/// `[` comes before `|`, and `|` before `]`.
func render(_ text: String, cursor: Int, selections: [NSRange]) -> String {
    let marked = NSMutableString(string: text)
    var marks: [(offset: Int, order: Int, mark: String)] = [(min(cursor, marked.length), 1, "|")]
    for range in selections where range.length > 0 {
        marks.append((range.location, 0, "["))
        marks.append((NSMaxRange(range), 2, "]"))
    }
    for mark in marks.sorted(by: { ($0.offset, $0.order) > ($1.offset, $1.order) }) {
        marked.insert(mark.mark, at: mark.offset)
    }
    return marked as String
}

/// Feeds `keys` (Vim key notation) to the engine with `before` (cursor written as `|`).
/// Edits are applied in order, each to the text the previous one produced. The fake view
/// shows `lines` lines from `top`, follows scroll effects, and otherwise scrolls only as far
/// as `scrolloff` needs, as the adapter does. Keys from a `.replay` effect are fed next, as
/// the adapter does for `.`. `clipboard` is what the system clipboard holds.
@discardableResult
func runVim(_ before: String, _ keys: String, window: VimWindowState = VimWindowState(),
            session: VimSession = VimSession(), lines: Int = 20, top: Int = 0,
            wrapWidth: Int = 80, clipboard: String? = nil) -> VimRun {
    let (start, cursor) = splitCursor(before)
    let text = NSMutableString(string: start)
    var window = window
    window.cursor = cursor
    var session = session
    var effects: [VimEffect] = []
    var top = top
    var selections: [NSRange] = []
    var queue: [VimKey]
    do { queue = try VimKey.parse(keys) } catch { preconditionFailure("bad keys \(keys)") }
    while !queue.isEmpty {
        let key = queue.removeFirst()
        let snapshot = NSString(string: text)
        let screen = ScreenGeometry.fake(lines: lines, top: top, text: snapshot,
                                         wrapWidth: wrapWidth)
        let result = VimEngine.handle(key, window: window, session: session, text: snapshot,
                                      screen: screen, clipboard: { clipboard })
        for edit in result.edits {
            text.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        window = result.window
        session = result.session
        selections = result.selections
        effects += result.effects
        for case .replay(let replayed) in result.effects {
            queue.insert(contentsOf: replayed, at: 0)
        }
        top = fakeTop(after: result.effects, top: top, lines: lines, cursor: window.cursor,
                      text: NSString(string: text), scrolloff: session.options.scrolloff)
    }
    let final = text as String
    return VimRun(text: final, window: window, session: session, effects: effects, top: top,
                  rendered: render(final, cursor: window.cursor, selections: selections),
                  selections: selections)
}

/// Asserts that `keys` turn `before` into `after`, both written with `|` for the cursor.
@discardableResult
func assertVim(_ before: String, _ keys: String, _ after: String,
               window: VimWindowState = VimWindowState(), session: VimSession = VimSession(),
               lines: Int = 20, top: Int = 0, wrapWidth: Int = 80, clipboard: String? = nil,
               file: StaticString = #filePath, line: UInt = #line) -> VimRun {
    let run = runVim(before, keys, window: window, session: session, lines: lines, top: top,
                     wrapWidth: wrapWidth, clipboard: clipboard)
    XCTAssertEqual(run.rendered, after, "keys \(keys)", file: file, line: line)
    return run
}

/// Where the fake view's top line ends up: scroll effects first, then the smallest scroll
/// that keeps the cursor inside the view, `scrolloff` lines from its edges unless the key
/// scrolled the view itself (the engine has already placed the cursor for that scroll).
private func fakeTop(after effects: [VimEffect], top: Int, lines: Int, cursor: Int,
                     text: NSString, scrolloff: Int) -> Int {
    var top = top
    var scrolled = false
    for case .scroll(let request) in effects {
        scrolled = true
        switch request {
        case .top(let line): top = line
        case .center(let line): top = max(line - (lines - 1) / 2, 0)
        case .bottom(let line): top = max(line - lines + 1, 0)
        }
    }
    let buffer = VimBuffer(text)
    let cursorLine = buffer.lineIndex(of: cursor)
    let margin = scrolled ? 0 : min(scrolloff, (lines - 1) / 2)
    if cursorLine - margin < top { top = max(cursorLine - margin, 0) }
    if cursorLine + margin > top + lines - 1 {
        top = max(min(cursorLine + margin, buffer.lineCount - 1) - lines + 1, 0)
    }
    return top
}

/// `count` lines `line 1`, `line 2`, ..., with the odd-numbered ones indented by two spaces,
/// and the cursor at `column` of `cursorLine` (both counted from 0).
func numberedLines(_ count: Int, cursorLine: Int = 0, column: Int = 0) -> String {
    (1...count).enumerated().map { index, number in
        var line = (number % 2 == 1 ? "  " : "") + "line \(number)"
        if index == cursorLine {
            line.insert("|", at: line.index(line.startIndex, offsetBy: column))
        }
        return line
    }.joined(separator: "\n")
}

extension VimRun {
    /// What register `name` holds after the run, reading `+` and `*` as an empty clipboard.
    func register(_ name: Character) -> RegisterValue? {
        session.registers.value(name, clipboard: { nil })
    }
}

func charwise(_ text: String) -> RegisterValue { RegisterValue(text: text, kind: .characterwise) }
func linewise(_ text: String) -> RegisterValue { RegisterValue(text: text, kind: .linewise) }

/// A session with `options` changed by `:set`-style assignments.
func session(_ change: (inout VimOptions) -> Void) -> VimSession {
    var session = VimSession()
    change(&session.options)
    return session
}
