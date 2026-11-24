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
    /// The text with the cursor written as `|`, or each selection written as `[...]`.
    var rendered: String
}

/// Splits `marked` at its single `|` into the text and the cursor's UTF-16 offset.
func splitCursor(_ marked: String) -> (text: String, cursor: Int) {
    let nsMarked = marked as NSString
    let bar = nsMarked.range(of: "|")
    precondition(bar.location != NSNotFound, "the text needs a | for the cursor")
    return (nsMarked.replacingCharacters(in: bar, with: ""), bar.location)
}

func render(_ text: String, cursor: Int, selections: [NSRange]) -> String {
    let marked = NSMutableString(string: text)
    let visible = selections.filter { $0.length > 0 }
    guard !visible.isEmpty else {
        marked.insert("|", at: min(cursor, marked.length))
        return marked as String
    }
    for range in visible.sorted(by: { $0.location > $1.location }) {
        marked.insert("]", at: NSMaxRange(range))
        marked.insert("[", at: range.location)
    }
    return marked as String
}

/// Feeds `keys` (Vim key notation) to the engine with `before` (cursor written as `|`).
/// Edits are applied in order, each to the text the previous one produced. The fake view
/// shows `lines` lines from `top`, follows scroll effects, and otherwise scrolls only as far
/// as `scrolloff` needs, as the adapter does.
@discardableResult
func runVim(_ before: String, _ keys: String, window: VimWindowState = VimWindowState(),
            session: VimSession = VimSession(), lines: Int = 20, top: Int = 0,
            wrapWidth: Int = 80) -> VimRun {
    let (start, cursor) = splitCursor(before)
    let text = NSMutableString(string: start)
    var window = window
    window.cursor = cursor
    var session = session
    var effects: [VimEffect] = []
    var top = top
    var selections: [NSRange] = []
    let parsed: [VimKey]
    do { parsed = try VimKey.parse(keys) } catch { preconditionFailure("bad keys \(keys)") }
    for key in parsed {
        let snapshot = NSString(string: text)
        let screen = ScreenGeometry.fake(lines: lines, top: top, text: snapshot,
                                         wrapWidth: wrapWidth)
        let result = VimEngine.handle(key, window: window, session: session, text: snapshot,
                                      screen: screen, clipboard: { nil })
        for edit in result.edits {
            text.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        window = result.window
        session = result.session
        selections = result.selections
        effects += result.effects
        top = fakeTop(after: result.effects, top: top, lines: lines, cursor: window.cursor,
                      text: NSString(string: text), scrolloff: session.options.scrolloff)
    }
    let final = text as String
    return VimRun(text: final, window: window, session: session, effects: effects, top: top,
                  rendered: render(final, cursor: window.cursor, selections: selections))
}

/// Asserts that `keys` turn `before` into `after`, both written with `|` for the cursor.
@discardableResult
func assertVim(_ before: String, _ keys: String, _ after: String,
               window: VimWindowState = VimWindowState(), session: VimSession = VimSession(),
               lines: Int = 20, top: Int = 0, wrapWidth: Int = 80,
               file: StaticString = #filePath, line: UInt = #line) -> VimRun {
    let run = runVim(before, keys, window: window, session: session, lines: lines, top: top,
                     wrapWidth: wrapWidth)
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
