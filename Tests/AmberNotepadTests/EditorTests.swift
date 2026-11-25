import AppKit
import XCTest
@testable import AmberNotepad

final class EditorTests: XCTestCase {
    func test_long_document_remains_scrollable_after_resizing() async {
        await MainActor.run {
            _ = NSApplication.shared
            let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 1000, height: 720))
            let window = NSWindow(contentRect: terminal.frame, styleMask: [.titled],
                                  backing: .buffered, defer: false)
            window.contentView = terminal
            terminal.layoutSubtreeIfNeeded()
            terminal.textView.string = (1...500).map { "Line \($0)" }.joined(separator: "\n")
            terminal.textView.sizeToFit()
            terminal.frame.size.width = 700
            terminal.layout()
            let end = (terminal.textView.string as NSString).length
            terminal.textView.scrollRangeToVisible(NSRange(location: end, length: 0))
            XCTAssertGreaterThan(terminal.textView.visibleRect.minY, 0)
            XCTAssertEqual(terminal.textView.string.components(separatedBy: "\n").last, "Line 500")
            window.contentView = nil
        }
    }

    func test_vim_line_motion_scrolls_one_line_at_a_time_past_the_screen_edge() async {
        await MainActor.run {
            _ = NSApplication.shared
            let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 1000, height: 720))
            let window = NSWindow(contentRect: terminal.frame, styleMask: [.titled],
                                  backing: .buffered, defer: false)
            window.contentView = terminal
            let view = terminal.textView
            view.string = (1...500).map { "Line \($0)" }.joined(separator: "\n")
            terminal.layoutSubtreeIfNeeded()
            view.setSelectedRange(NSRange(location: 0, length: 0))
            let linePitch = view.layoutManager!.defaultLineHeight(for: Phosphor.font)
                + view.defaultParagraphStyle!.lineSpacing
            let screenLines = Int(view.visibleRect.height / linePitch)
            for motion in ["j", "k"] {
                var scrolls: [CGFloat] = []
                for _ in 0..<(screenLines + 20) {
                    let before = view.visibleRect.minY
                    view.keyDown(with: key(motion))
                    let scrolled = abs(view.visibleRect.minY - before)
                    if scrolled > 0 { scrolls.append(scrolled) }
                    var actual = NSRange()
                    let screenRect = view.firstRect(
                        forCharacterRange: view.selectedRange(), actualRange: &actual
                    )
                    let caret = view.convert(window.convertFromScreen(screenRect), from: nil)
                    XCTAssertTrue(view.visibleRect.contains(caret), "\(motion) hid the cursor")
                }
                // The first scroll only finishes revealing a partly visible line.
                XCTAssertFalse(scrolls.isEmpty, "\(motion) never scrolled")
                XCTAssertLessThanOrEqual(scrolls.first ?? 0, linePitch)
                XCTAssertEqual(Array(scrolls.dropFirst()),
                               Array(repeating: linePitch, count: max(scrolls.count - 1, 0)))
            }
            XCTAssertEqual(view.visibleRect.minY, 0)
            XCTAssertEqual(view.selectedRange().location, 0)
            window.contentView = nil
        }
    }

    func test_vim_motion_to_document_end_reveals_the_last_line() async {
        await MainActor.run {
            _ = NSApplication.shared
            let lines = (1...100).map { "Line \($0)" }.joined(separator: "\n")
            let cases = [("", true), (lines, true), (lines + "\n", false)]
            for (text, endsAtBottom) in cases {
                let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 1000, height: 720))
                let window = NSWindow(contentRect: terminal.frame, styleMask: [.titled],
                                      backing: .buffered, defer: false)
                window.contentView = terminal
                let view = terminal.textView
                view.string = text
                terminal.layoutSubtreeIfNeeded()
                view.setSelectedRange(NSRange(location: 0, length: 0))
                view.keyDown(with: key("G"))
                view.keyDown(with: key("j"))
                let lastLine = (text as NSString).range(of: "Line 100")
                let expected = lastLine.location == NSNotFound ? 0 : lastLine.location
                XCTAssertEqual(view.selectedRange(), NSRange(location: expected, length: 0))
                var actual = NSRange()
                let screenRect = view.firstRect(
                    forCharacterRange: view.selectedRange(), actualRange: &actual
                )
                let caret = view.convert(window.convertFromScreen(screenRect), from: nil)
                XCTAssertTrue(view.visibleRect.contains(caret), "\(text.suffix(8)) hid the cursor")
                XCTAssertEqual(view.visibleRect.maxY == view.bounds.maxY, endsAtBottom,
                               "\(text.suffix(8))")
                window.contentView = nil
            }
        }
    }

    func test_vim_normal_mode_moves_without_inserting_letters() async {
        await MainActor.run {
            let view = TerminalTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
            view.string = "hello world"
            view.setSelectedRange(NSRange(location: 0, length: 0))
            view.keyDown(with: key("l"))
            XCTAssertEqual(view.string, "hello world")
            XCTAssertEqual(view.selectedRange(), NSRange(location: 1, length: 0))
        }
    }

    func test_vim_delete_line_can_be_pasted_back() async {
        await MainActor.run {
            let view = TerminalTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
            view.allowsUndo = true
            view.string = "first\nsecond\n"
            view.setSelectedRange(NSRange(location: 0, length: 0))
            view.keyDown(with: key("d"))
            view.keyDown(with: key("d"))
            XCTAssertEqual(view.string, "second\n")
            view.keyDown(with: key("P"))
            XCTAssertEqual(view.string, "first\nsecond\n")
        }
    }

    func test_vim_D_deletes_to_line_end_and_p_puts_it_back() async {
        await MainActor.run {
            let view = TerminalTextView(frame: .zero)
            view.string = "hello world\nnext"
            view.setSelectedRange(NSRange(location: 6, length: 0))
            view.keyDown(with: key("D"))
            XCTAssertEqual(view.string, "hello \nnext")
            XCTAssertEqual(view.selectedRange(), NSRange(location: 5, length: 0))
            XCTAssertEqual(view.mode, .normal)
            view.keyDown(with: key("p"))
            XCTAssertEqual(view.string, "hello world\nnext")
        }
    }

    func test_vim_D_with_count_deletes_through_following_lines() async {
        await MainActor.run {
            let view = TerminalTextView(frame: .zero)
            view.string = "one two\nthree\nfour"
            view.setSelectedRange(NSRange(location: 4, length: 0))
            view.keyDown(with: key("2"))
            view.keyDown(with: key("D"))
            XCTAssertEqual(view.string, "one \nfour")
        }
    }

    func test_vim_C_changes_to_line_end_in_insert_mode() async {
        await MainActor.run {
            let view = TerminalTextView(frame: .zero)
            view.string = "hello world\nnext"
            view.setSelectedRange(NSRange(location: 6, length: 0))
            view.keyDown(with: key("C"))
            XCTAssertEqual(view.string, "hello \nnext")
            XCTAssertEqual(view.selectedRange(), NSRange(location: 6, length: 0))
            XCTAssertEqual(view.mode, .insert)
        }
    }

    func test_vim_C_on_an_empty_line_enters_insert_mode_without_deleting() async {
        await MainActor.run {
            let view = TerminalTextView(frame: .zero)
            view.string = "a\n\nb"
            view.setSelectedRange(NSRange(location: 2, length: 0))
            view.keyDown(with: key("C"))
            XCTAssertEqual(view.string, "a\n\nb")
            XCTAssertEqual(view.selectedRange(), NSRange(location: 2, length: 0))
            XCTAssertEqual(view.mode, .insert)
        }
    }

    func test_vim_visual_D_deletes_the_selected_lines() async {
        await MainActor.run {
            let view = TerminalTextView(frame: .zero)
            view.string = "one\ntwo\nthree\nfour"
            view.setSelectedRange(NSRange(location: 5, length: 0))
            view.keyDown(with: key("v"))
            view.keyDown(with: key("j"))
            view.keyDown(with: key("D"))
            XCTAssertEqual(view.string, "one\nfour")
            XCTAssertEqual(view.selectedRange(), NSRange(location: 4, length: 0))
            XCTAssertEqual(view.mode, .normal)
            view.keyDown(with: key("P"))
            XCTAssertEqual(view.string, "one\ntwo\nthree\nfour")
        }
    }

    func test_vim_visual_C_replaces_the_selected_lines_with_an_empty_line() async {
        await MainActor.run {
            let view = TerminalTextView(frame: .zero)
            view.string = "one\ntwo\nthree\nfour"
            view.setSelectedRange(NSRange(location: 5, length: 0))
            view.keyDown(with: key("v"))
            view.keyDown(with: key("j"))
            view.keyDown(with: key("C"))
            XCTAssertEqual(view.string, "one\n\nfour")
            XCTAssertEqual(view.selectedRange(), NSRange(location: 4, length: 0))
            XCTAssertEqual(view.mode, .insert)
        }
    }

    func test_vim_visual_C_keeps_the_documents_line_break() async {
        await MainActor.run {
            let view = TerminalTextView(frame: .zero)
            view.string = "one\r\ntwo\r\nthree"
            view.setSelectedRange(NSRange(location: 5, length: 0))
            view.keyDown(with: key("v"))
            view.keyDown(with: key("C"))
            XCTAssertEqual(view.string, "one\r\n\r\nthree")
        }
    }

    func test_vim_change_word_enters_insert_mode() async {
        await MainActor.run {
            let view = TerminalTextView(frame: .zero)
            view.string = "hello world"
            view.setSelectedRange(NSRange(location: 0, length: 0))
            view.keyDown(with: key("c"))
            view.keyDown(with: key("w"))
            XCTAssertEqual(view.string, " world")
            XCTAssertEqual(view.mode, .insert)
        }
    }

    func test_change_word_does_not_cross_current_word_end() async {
        await MainActor.run {
            for (text, offset, expected) in [("a b", 0, " b"), ("hello world", 4, "hell world")] {
                let view = TerminalTextView(frame: .zero)
                view.string = text
                view.setSelectedRange(NSRange(location: offset, length: 0))
                view.keyDown(with: key("c"))
                view.keyDown(with: key("w"))
                XCTAssertEqual(view.string, expected)
                XCTAssertEqual(view.mode, .insert)
            }
        }
    }

    func test_vim_word_motion_and_visual_delete_preserve_unicode() async {
        await MainActor.run {
            let view = TerminalTextView(frame: .zero)
            view.string = "hi 👩🏽‍💻 there"
            view.setSelectedRange(NSRange(location: 0, length: 0))
            view.keyDown(with: key("w"))
            XCTAssertEqual(view.selectedRange().location, 3)
            view.keyDown(with: key("v"))
            view.keyDown(with: key("d"))
            XCTAssertEqual(view.string, "hi  there")
            XCTAssertEqual(view.mode, .normal)
        }
    }

    func test_escape_returns_from_insert_without_changing_text() async {
        await MainActor.run {
            let view = TerminalTextView(frame: .zero)
            view.keyDown(with: key("i"))
            XCTAssertEqual(view.mode, .insert)
            view.keyDown(with: key("\u{1b}"))
            XCTAssertEqual(view.mode, .normal)
            XCTAssertEqual(view.string, "")
        }
    }

    @MainActor private func key(_ character: String) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                         windowNumber: 0, context: nil, characters: character,
                         charactersIgnoringModifiers: character, isARepeat: false, keyCode: 0)!
    }
}
