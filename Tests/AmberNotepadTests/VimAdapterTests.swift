import AppKit
import NotepadCore
import XCTest
@testable import AmberNotepad

/// The adapter between `TerminalTextView` and the Vim engine, driven through real windows.
final class VimAdapterTests: XCTestCase {
    // MARK: Undo

    func test_one_insert_session_is_one_undo_step() async throws {
        try await MainActor.run {
            let (app, directory, editor) = try workspace("")
            defer { cleanup(app, directory) }
            let view = editor.terminal.textView
            press(view, "i")
            type(view, "hel")
            type(view, "lo")
            press(view, "\u{1b}")
            XCTAssertEqual(view.string, "hello")

            press(view, "u")

            XCTAssertEqual(view.string, "")
        }
    }

    func test_each_change_is_its_own_undo_step() async throws {
        try await MainActor.run {
            let (app, directory, editor) = try workspace("abcd")
            defer { cleanup(app, directory) }
            let view = editor.terminal.textView
            press(view, "x")
            press(view, "x")
            XCTAssertEqual(view.string, "cd")

            press(view, "u")

            XCTAssertEqual(view.string, "bcd")
        }
    }

    func test_a_macro_run_is_one_undo_step() async throws {
        try await MainActor.run {
            let (app, directory, editor) = try workspace("abcdef")
            defer { cleanup(app, directory) }
            let view = editor.terminal.textView
            for character in ["q", "a", "x", "x", "q"] { press(view, character) }
            XCTAssertEqual(view.string, "cdef")
            press(view, "@")
            press(view, "a")
            XCTAssertEqual(view.string, "ef")

            press(view, "u")

            XCTAssertEqual(view.string, "cdef")
        }
    }

    func test_a_macro_with_an_ex_command_and_an_edit_is_one_undo_step() async throws {
        try await MainActor.run {
            let (app, directory, editor) = try workspace("aaa aaa")
            defer { cleanup(app, directory) }
            let view = editor.terminal.textView
            press(view, "q")
            press(view, "a")
            submit(":s/a/b/", in: editor)
            press(view, "x")
            press(view, "q")
            XCTAssertEqual(view.string, "aa aaa")
            press(view, "@")
            press(view, "a")
            XCTAssertEqual(view.string, "a aaa")

            press(view, "u")

            XCTAssertEqual(view.string, "aa aaa")
        }
    }

    func test_norm_over_a_range_is_one_undo_step() async throws {
        try await MainActor.run {
            let (app, directory, editor) = try workspace("a\nb\nc")
            defer { cleanup(app, directory) }
            let view = editor.terminal.textView
            submit(":%norm Ax", in: editor)
            XCTAssertEqual(view.string, "ax\nbx\ncx")

            press(view, "u")

            XCTAssertEqual(view.string, "a\nb\nc")
        }
    }

    func test_a_visual_block_insert_is_one_undo_step() async throws {
        try await MainActor.run {
            let (app, directory, editor) = try workspace("ab\ncd\nef")
            defer { cleanup(app, directory) }
            let view = editor.terminal.textView
            press(view, "v", control: true)
            press(view, "j")
            press(view, "j")
            press(view, "I")
            type(view, "X")
            press(view, "\u{1b}")
            XCTAssertEqual(view.string, "Xab\nXcd\nXef")

            press(view, "u")

            XCTAssertEqual(view.string, "ab\ncd\nef")
        }
    }

    func test_the_edit_menu_undo_in_insert_mode_undoes_the_typing_without_crashing() async throws {
        try await MainActor.run {
            let (app, directory, editor) = try workspace("")
            defer { cleanup(app, directory) }
            let view = editor.terminal.textView
            press(view, "i")
            type(view, "abc")

            view.undo(nil)

            XCTAssertEqual(view.string, "")
            XCTAssertEqual(view.mode, .insert)
        }
    }

    // MARK: Autosave and recording

    func test_autosave_fires_after_an_engine_edit() async throws {
        try await MainActor.run {
            let (app, directory, editor) = try workspace("hello", name: "note.md")
            defer { cleanup(app, directory) }
            press(editor.terminal.textView, "x")
            XCTAssertTrue(editor.hasUnsavedChanges)

            RunLoop.main.run(until: Date().addingTimeInterval(0.9))

            XCTAssertEqual(
                try String(contentsOf: directory.appendingPathComponent("note.md")), "ello"
            )
            XCTAssertFalse(editor.hasUnsavedChanges)
        }
    }

    func test_text_committed_through_insert_text_reaches_the_dot_command() async throws {
        try await MainActor.run {
            let (app, directory, editor) = try workspace("ab")
            defer { cleanup(app, directory) }
            let view = editor.terminal.textView
            press(view, "i")
            type(view, "é")
            press(view, "\u{1b}")
            press(view, "l")

            press(view, ".")

            XCTAssertEqual(view.string, "ééab")
        }
    }

    func test_text_committed_through_insert_text_reaches_a_macro() async throws {
        try await MainActor.run {
            let (app, directory, editor) = try workspace("")
            defer { cleanup(app, directory) }
            let view = editor.terminal.textView
            press(view, "q")
            press(view, "q")
            press(view, "i")
            type(view, "é")
            press(view, "\u{1b}")
            press(view, "q")
            XCTAssertEqual(view.string, "é")

            press(view, "@")
            press(view, "q")

            XCTAssertEqual(view.string, "éé")
        }
    }

    func test_text_inserted_by_appkit_in_normal_mode_is_not_a_vim_change() async throws {
        try await MainActor.run {
            let (app, directory, editor) = try workspace("ab")
            defer { cleanup(app, directory) }
            let view = editor.terminal.textView
            press(view, "x")
            view.insertText("Z", replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertEqual(view.string, "Zb")

            press(view, ".")

            XCTAssertEqual(view.string, "Z")
            XCTAssertEqual(view.mode, .normal)
        }
    }

    // MARK: Shared state

    func test_a_yank_in_one_window_can_be_put_in_another() async throws {
        try await MainActor.run {
            let (app, directory, first) = try workspace("alpha beta")
            defer { cleanup(app, directory) }
            let second = try app.createWindow()
            press(first.terminal.textView, "y")
            press(first.terminal.textView, "w")

            press(second.terminal.textView, "p")

            XCTAssertEqual(second.terminal.textView.string, "alpha ")
        }
    }

    func test_set_in_one_window_applies_to_every_window() async throws {
        try await MainActor.run {
            let (app, directory, first) = try workspace("")
            defer { cleanup(app, directory) }
            let second = try app.createWindow()
            submit(":set ts=2", in: first)
            let view = second.terminal.textView
            press(view, "i")

            press(view, "\t")

            XCTAssertEqual(view.string, "  ")
        }
    }

    func test_a_bad_amberrc_line_shows_an_error_and_launch_continues() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            let rc = directory.appendingPathComponent("amberrc")
            try "set ts=2\nset bogus\nset sw=3\n".write(to: rc, atomically: true, encoding: .utf8)
            let app = AppDelegate(
                recoveryURL: directory.appendingPathComponent("Recovery.json"), rcURL: rc
            )
            defer { cleanup(app, directory) }

            try app.restoreWindows(reopeningRecent: false)

            let options = app.vimSession.session.options
            XCTAssertEqual([options.tabstop, options.shiftwidth], [2, 3])
            XCTAssertEqual(app.editors.count, 1)
            let status = app.editors[0].terminal.status.stringValue
            XCTAssertTrue(status.contains("line 2: E518"), status)
        }
    }

    func test_a_missing_amberrc_changes_nothing() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            let app = AppDelegate(
                recoveryURL: directory.appendingPathComponent("Recovery.json"),
                rcURL: directory.appendingPathComponent("absent")
            )
            defer { cleanup(app, directory) }

            try app.restoreWindows(reopeningRecent: false)

            XCTAssertEqual(app.vimSession.session.options, VimOptions())
            XCTAssertFalse(app.editors[0].terminal.status.stringValue.contains("amberrc"))
        }
    }

    // MARK: Keys

    func test_option_chords_are_swallowed_in_normal_mode() async throws {
        try await MainActor.run {
            let (terminal, window) = editorWindow()
            defer { window.contentView = nil }
            let view = terminal.textView
            view.string = "abc"
            view.setSelectedRange(NSRange(location: 0, length: 0))

            view.keyDown(with: key("≈", ignoring: "x", option: true))

            XCTAssertEqual(view.string, "abc")
            XCTAssertEqual(view.mode, .normal)
        }
    }

    func test_option_chords_type_their_character_in_insert_mode() async throws {
        try await MainActor.run {
            let (terminal, window) = editorWindow()
            defer { window.contentView = nil }
            let view = terminal.textView
            view.setMode(.insert)

            view.keyDown(with: key("å", ignoring: "a", option: true))

            XCTAssertEqual(view.string, "å")
        }
    }

    func test_escape_with_shift_still_ends_insert_mode() async throws {
        try await MainActor.run {
            let view = TerminalTextView(frame: .zero)
            view.setMode(.insert)

            view.keyDown(with: key("\u{1b}", shift: true))

            XCTAssertEqual(view.mode, .normal)
        }
    }

    func test_with_vim_off_appkit_handles_every_key() async throws {
        try await MainActor.run {
            let (terminal, window) = editorWindow()
            defer { window.contentView = nil }
            let view = terminal.textView
            view.vimEnabled = false

            for character in ["d", ":", "x"] { view.keyDown(with: key(character)) }

            XCTAssertEqual(view.string, "d:x")
            XCTAssertEqual(view.vim.pendingKeys, [])
        }
    }

    func test_replace_mode_overwrites_typed_characters() async throws {
        try await MainActor.run {
            let view = TerminalTextView(frame: .zero)
            view.string = "abcd"
            view.setSelectedRange(NSRange(location: 0, length: 0))
            press(view, "R")
            XCTAssertEqual(view.mode, .replace)

            press(view, "x")
            press(view, "y")

            XCTAssertEqual(view.string, "xycd")
        }
    }

    // MARK: IME composition

    func test_escape_during_composition_cancels_it_and_stays_in_insert_mode() async throws {
        try await MainActor.run {
            let (terminal, window) = editorWindow()
            defer { window.contentView = nil }
            let view = terminal.textView
            view.setMode(.insert)
            compose(view, "ni")

            view.keyDown(with: key("\u{1b}"))

            XCTAssertEqual(view.mode, .insert)
            XCTAssertEqual(view.vim.insertSession?.typed, [])
        }
    }

    func test_return_during_composition_does_not_reach_the_engine() async throws {
        try await MainActor.run {
            let (terminal, window) = editorWindow()
            defer { window.contentView = nil }
            let view = terminal.textView
            view.setMode(.insert)
            compose(view, "ni")

            view.keyDown(with: key("\r"))

            XCTAssertFalse(view.vim.insertSession?.typed.contains(VimKey(.enter)) ?? true)
        }
    }

    func test_backspace_during_composition_does_not_reach_the_engine() async throws {
        try await MainActor.run {
            let (terminal, window) = editorWindow()
            defer { window.contentView = nil }
            let view = terminal.textView
            view.string = "ab"
            view.setMode(.insert)
            view.setSelectedRange(NSRange(location: 2, length: 0))
            compose(view, "ni")

            view.keyDown(with: key("\u{7f}"))

            XCTAssertEqual(view.vim.insertSession?.typed, [])
            XCTAssertTrue(view.string.hasPrefix("ab"))
        }
    }

    // MARK: Replay limits

    func test_a_self_recursive_macro_stops_instead_of_hanging() async throws {
        try await MainActor.run {
            let (app, directory, editor) = try workspace("x")
            defer { cleanup(app, directory) }
            let view = editor.terminal.textView
            for character in ["q", "a", "@", "a", "q"] { press(view, character) }

            press(view, "@")
            press(view, "a")

            XCTAssertEqual(view.string, "x")
            XCTAssertEqual(view.mode, .normal)
        }
    }

    func test_a_replay_past_100000_keys_stops_with_an_error() async throws {
        try await MainActor.run {
            let (app, directory, editor) = try workspace("abc")
            defer { cleanup(app, directory) }
            let view = editor.terminal.textView
            for character in ["q", "a", "0", "q"] { press(view, character) }

            for character in ["9", "9", "9", "9", "9", "9", "@", "a"] { press(view, character) }

            XCTAssertTrue(editor.terminal.status.stringValue.contains("E223"))
            XCTAssertEqual(view.string, "abc")
        }
    }

    func test_global_norm_continues_past_a_line_whose_keys_fail() async throws {
        try await MainActor.run {
            let (app, directory, editor) = try workspace("ab\nxx\nab")
            defer { cleanup(app, directory) }

            submit(":g/./norm fbrZ", in: editor)

            XCTAssertEqual(editor.terminal.textView.string, "aZ\nxx\naZ")
        }
    }

    func test_global_stops_at_an_ex_error() async throws {
        try await MainActor.run {
            let (app, directory, editor) = try workspace("y1\ny2\ny3")
            defer { cleanup(app, directory) }

            submit(":g/y/m-2", in: editor)

            XCTAssertTrue(editor.terminal.status.stringValue.contains("E16"))
            XCTAssertEqual(editor.terminal.textView.string, "y1\ny2\ny3")
        }
    }

    func test_a_command_nested_past_the_recursion_limit_fails_with_an_error() async throws {
        try await MainActor.run {
            let (app, directory, editor) = try workspace("a")
            defer { cleanup(app, directory) }
            let view = editor.terminal.textView
            var succeeded = true
            @MainActor func nest(_ levels: Int) {
                if levels == 0 {
                    succeeded = view.runTextCommand(range: nil, command: .noHighlight)
                } else {
                    view.withUndoGroup { nest(levels - 1) }
                }
            }

            nest(100)

            XCTAssertFalse(succeeded)
            XCTAssertTrue(editor.terminal.status.stringValue.contains("E223"))
        }
    }

    // MARK: Refused edits

    func test_a_refused_edit_leaves_the_window_state_and_registers_as_before() async throws {
        try await MainActor.run {
            let (app, directory, editor) = try workspace("one\ntwo\nthree")
            defer { cleanup(app, directory) }
            let view = editor.terminal.textView
            press(view, "$")
            XCTAssertEqual(view.vim.desiredColumn, Int.max)
            let windowBefore = view.vim
            let refuser = Refuser()
            view.delegate = refuser

            submit(":1,2d", in: editor)

            XCTAssertEqual(view.string, "one\ntwo\nthree")
            XCTAssertEqual(view.vim, windowBefore)
            XCTAssertNil(editor.vimSession.session.registers.value("\"", clipboard: { nil }))
            XCTAssertEqual(view.currentBuffer().text as String, "one\ntwo\nthree")
        }
    }

    // MARK: Mouse

    func test_a_click_at_a_line_end_lands_on_the_last_character() async throws {
        try await MainActor.run {
            let view = TerminalTextView(frame: .zero)
            view.string = "hello\nworld"

            view.setSelectedRange(NSRange(location: 5, length: 0))

            XCTAssertEqual(view.selectedRange(), NSRange(location: 4, length: 0))
            XCTAssertEqual(view.mode, .normal)
        }
    }

    func test_a_drag_enters_visual_mode_with_the_dragged_text() async throws {
        try await MainActor.run {
            let view = TerminalTextView(frame: .zero)
            view.string = "hello"

            view.setSelectedRange(NSRange(location: 1, length: 3))

            XCTAssertEqual(view.mode, .visual)
            press(view, "d")
            XCTAssertEqual(view.string, "ho")
        }
    }

    func test_a_triple_click_enters_visual_line_mode() async throws {
        try await MainActor.run {
            let view = TerminalTextView(frame: .zero)
            view.string = "one\ntwo\nthree"
            view.mouseClick = (offset: 5, count: 3)

            view.setSelectedRange(NSRange(location: 4, length: 4))
            view.mouseClick = nil

            XCTAssertEqual(view.mode, .visualLine)
            press(view, "d")
            XCTAssertEqual(view.string, "one\nthree")
        }
    }

    func test_scrolling_moves_the_view_and_the_next_command_starts_in_view() async throws {
        try await MainActor.run {
            let (terminal, window) = editorWindow()
            defer { window.contentView = nil }
            let view = terminal.textView
            view.string = (1...500).map { "Line \($0)" }.joined(separator: "\n")
            terminal.layoutSubtreeIfNeeded()
            view.setSelectedRange(NSRange(location: 0, length: 0))
            view.scroll(NSPoint(x: 0, y: 3000))
            XCTAssertEqual(view.currentBuffer().lineIndex(of: view.selectedRange().location), 0)

            press(view, "j")

            let first = view.screenGeometry(view.currentBuffer()).firstVisibleLine
            let line = view.currentBuffer().lineIndex(of: view.selectedRange().location)
            XCTAssertEqual(line, first + 1)
        }
    }

    // MARK: Footer prompts

    func test_slash_submits_a_search_and_n_repeats_it() async throws {
        try await MainActor.run {
            let (app, directory, editor) = try workspace("one two three two")
            defer { cleanup(app, directory) }
            let view = editor.terminal.textView

            submit("/two", in: editor)
            XCTAssertEqual(view.selectedRange(), NSRange(location: 4, length: 0))
            press(view, "n")

            XCTAssertEqual(view.selectedRange(), NSRange(location: 14, length: 0))
        }
    }

    func test_question_mark_searches_backwards() async throws {
        try await MainActor.run {
            let (app, directory, editor) = try workspace("two one two")
            defer { cleanup(app, directory) }
            let view = editor.terminal.textView
            view.setSelectedRange(NSRange(location: 8, length: 0))

            submit("?one", in: editor)

            XCTAssertEqual(view.selectedRange(), NSRange(location: 4, length: 0))
        }
    }

    func test_a_search_cancelled_with_escape_reaches_the_macro_recording() async throws {
        try await MainActor.run {
            let (app, directory, editor) = try workspace("foo")
            defer { cleanup(app, directory) }
            let view = editor.terminal.textView
            press(view, "q")
            press(view, "a")
            press(view, "/")
            let field = editor.terminal.commandLine.currentEditor() as? NSTextView
            field?.string = "/foo"
            field?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
            press(view, "q")

            let register = editor.vimSession.session.registers.value("a", clipboard: { nil })

            XCTAssertEqual(register?.text, "/foo<Esc>")
        }
    }

    func test_up_in_the_command_line_recalls_the_previous_command() async throws {
        try await MainActor.run {
            let (app, directory, editor) = try workspace("")
            defer { cleanup(app, directory) }
            submit(":set ts=2", in: editor)
            press(editor.terminal.textView, ":")
            let field = editor.terminal.commandLine.currentEditor() as? NSTextView

            field?.doCommand(by: #selector(NSResponder.moveUp(_:)))

            XCTAssertEqual(editor.terminal.commandLine.stringValue, ":set ts=2")
        }
    }

    func test_a_command_run_from_the_command_line_can_be_repeated_with_at_colon() async throws {
        try await MainActor.run {
            let (app, directory, editor) = try workspace("a a a")
            defer { cleanup(app, directory) }
            submit(":s/a/b/", in: editor)
            XCTAssertEqual(editor.terminal.textView.string, "b a a")

            press(editor.terminal.textView, "@")
            press(editor.terminal.textView, ":")

            XCTAssertEqual(editor.terminal.textView.string, "b b a")
        }
    }

    func test_a_failing_ex_command_shows_vims_error_and_leaves_the_text() async throws {
        try await MainActor.run {
            let (app, directory, editor) = try workspace("text")
            defer { cleanup(app, directory) }

            submit(":nosuchcommand", in: editor)

            XCTAssertEqual(editor.terminal.textView.string, "text")
            XCTAssertTrue(editor.terminal.status.stringValue.contains("E492"))
        }
    }

    // MARK: Status

    func test_the_status_names_visual_line_mode_pending_keys_and_recording() async throws {
        try await MainActor.run {
            let (app, directory, editor) = try workspace("one\ntwo")
            defer { cleanup(app, directory) }
            let view = editor.terminal.textView
            press(view, "V")
            XCTAssertTrue(editor.terminal.status.stringValue.hasPrefix("[VISUAL LINE]"))
            press(view, "\u{1b}")
            press(view, "q")
            press(view, "a")
            press(view, "2")
            press(view, "d")

            XCTAssertTrue(editor.terminal.status.stringValue.hasPrefix(
                "[NORMAL]  recording @a  2d"
            ), editor.terminal.status.stringValue)
        }
    }

    func test_the_header_counts_lines_and_characters() async throws {
        try await MainActor.run {
            let (app, directory, editor) = try workspace("héllo\nworld")
            defer { cleanup(app, directory) }
            let view = editor.terminal.textView

            view.setSelectedRange(NSRange(location: 9, length: 0))

            XCTAssertEqual(editor.terminal.position.stringValue, "Ln 2   Col 4")
        }
    }

    // MARK: Live reload

    func test_a_reload_clears_a_pending_operator() async throws {
        try await MainActor.run {
            let (app, directory, editor) = try workspace("one\ntwo\nthree", name: "note.md")
            defer { cleanup(app, directory) }
            let view = editor.terminal.textView
            press(view, "d")
            try "one\ntwo\nthree\nfour".write(
                to: directory.appendingPathComponent("note.md"), atomically: true,
                encoding: .utf8
            )

            editor.checkDisk()
            press(view, "j")

            XCTAssertEqual(view.string, "one\ntwo\nthree\nfour")
            XCTAssertEqual(view.mode, .normal)
        }
    }

    func test_noautoread_stops_the_background_check_but_not_checktime() async throws {
        try await MainActor.run {
            let (app, directory, editor) = try workspace("before", name: "note.md")
            defer { cleanup(app, directory) }
            submit(":set noautoread", in: editor)
            try "after".write(
                to: directory.appendingPathComponent("note.md"), atomically: true,
                encoding: .utf8
            )

            editor.checkDisk(waitForQuiet: true)
            XCTAssertEqual(editor.terminal.textView.string, "before")
            submit(":checktime", in: editor)

            XCTAssertEqual(editor.terminal.textView.string, "after")
        }
    }

    // MARK: Helpers

    @MainActor private func press(
        _ view: TerminalTextView, _ character: String, control: Bool = false
    ) {
        view.keyDown(with: key(character, control: control))
    }

    @MainActor private func compose(_ view: TerminalTextView, _ text: String) {
        view.setMarkedText(
            text, selectedRange: NSRange(location: text.utf16.count, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
    }

    @MainActor private func type(_ view: TerminalTextView, _ text: String) {
        view.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    /// Opens the footer with the first character of `line`, types the rest and presses Return.
    @MainActor private func submit(_ line: String, in editor: EditorWindow) {
        let terminal = editor.terminal
        terminal.textView.keyDown(with: key(String(line.prefix(1))))
        guard let field = terminal.commandLine.currentEditor() as? NSTextView else {
            return XCTFail("The command line needs its field editor")
        }
        field.string = terminal.commandLine.stringValue + String(line.dropFirst())
        field.doCommand(by: #selector(NSResponder.insertNewline(_:)))
    }

    @MainActor private func key(
        _ character: String, ignoring: String? = nil, control: Bool = false,
        option: Bool = false, shift: Bool = false
    ) -> NSEvent {
        var flags = NSEvent.ModifierFlags()
        if control { flags.insert(.control) }
        if option { flags.insert(.option) }
        if shift { flags.insert(.shift) }
        return NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, characters: character,
            charactersIgnoringModifiers: ignoring ?? character, isARepeat: false, keyCode: 0
        )!
    }

    @MainActor private func editorWindow() -> (TerminalView, NSWindow) {
        _ = NSApplication.shared
        let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        let window = NSWindow(
            contentRect: terminal.frame, styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = terminal
        terminal.layoutSubtreeIfNeeded()
        window.makeFirstResponder(terminal.textView)
        return (terminal, window)
    }

    @MainActor private func workspace(
        _ text: String, name: String? = nil
    ) throws -> (AppDelegate, URL, EditorWindow) {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let app = AppDelegate(recoveryURL: directory.appendingPathComponent("Recovery.json"))
        guard let name else {
            let editor = try app.createWindow()
            editor.terminal.textView.string = text
            editor.terminal.textView.setSelectedRange(NSRange(location: 0, length: 0))
            return (app, directory, editor)
        }
        let file = directory.appendingPathComponent(name)
        try text.write(to: file, atomically: true, encoding: .utf8)
        return (app, directory, try app.createWindow(fileURL: file.resolvingSymlinksInPath()))
    }

    @MainActor private func cleanup(_ app: AppDelegate, _ directory: URL) {
        for editor in app.editors { editor.window.close() }
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private final class Refuser: NSObject, NSTextViewDelegate {
    func textView(
        _ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?
    ) -> Bool { false }
}
