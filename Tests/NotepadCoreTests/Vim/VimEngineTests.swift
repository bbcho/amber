import XCTest
@testable import NotepadCore

final class VimEngineTests: XCTestCase {
    private func lineOf(_ run: VimRun) -> Int {
        VimBuffer(run.text as NSString).lineIndex(of: run.window.cursor)
    }

    // MARK: Normal mode never rests on a line break

    func test_an_incoming_cursor_on_a_line_break_moves_onto_the_last_character() {
        assertVim("ab|\ncd", "<Esc>", "a|b\ncd")
        assertVim("ab\r|\ncd", "<Esc>", "a|b\r\ncd")
    }

    func test_an_incoming_cursor_after_the_final_line_break_moves_onto_the_last_line() {
        assertVim("ab\n|", "<Esc>", "a|b\n")
        assertVim("ab\n\n|", "<Esc>", "ab\n|\n")
    }

    func test_the_cursor_stays_at_the_start_of_an_empty_line() {
        assertVim("ab\n|\ncd", "<Esc>", "ab\n|\ncd")
        assertVim("|", "<Esc>", "|")
    }

    func test_motions_never_leave_the_cursor_on_a_line_break() {
        assertVim("a|bc\nd", "3l", "ab|c\nd")
        assertVim("a|bc\nd", "$", "ab|c\nd")
        assertVim("abc|def\nab\n", "j", "abcdef\na|b\n")
        assertVim("abc|def\r\nab\r\n", "j", "abcdef\r\na|b\r\n")
    }

    // MARK: Results

    func test_a_normal_mode_result_selects_the_cursor_without_edits() {
        let result = VimEngine.handle(VimKey(.character("l")), window: VimWindowState(),
                                      session: VimSession(), text: "abc",
                                      screen: .fake(lines: 10), clipboard: { nil })
        XCTAssertEqual(result.window.cursor, 1)
        XCTAssertEqual(result.selections, [NSRange(location: 1, length: 0)])
        XCTAssertEqual(result.edits, [])
        XCTAssertEqual(result.effects, [])
    }

    // MARK: Pending keys, counts and registers

    func test_a_partial_command_waits_in_the_pending_keys() {
        let run = runVim("|abc", "2g")
        XCTAssertEqual(run.window.pendingKeys, [VimKey(.character("g"))])
        XCTAssertEqual(run.window.count, 2)
        XCTAssertEqual(run.window.cursor, 0)
    }

    func test_escape_cancels_a_pending_command_and_count_without_failing() {
        let run = runVim("a|bc", "3f<Esc>")
        XCTAssertEqual(run.window.pendingKeys, [])
        XCTAssertNil(run.window.count)
        XCTAssertEqual(run.effects, [])
        assertVim("a|bc", "3<Esc>l", "ab|c")
    }

    func test_zero_is_a_motion_alone_and_a_digit_inside_a_count() {
        assertVim("|abcdefghijklmn", "10l", "abcdefghij|klmn")
        assertVim("abc|d", "0", "|abcd")
    }

    func test_a_register_prefix_is_held_for_the_next_command() {
        let run = runVim("|abc", "\"a")
        XCTAssertEqual(run.window.register, "a")
        XCTAssertEqual(run.window.pendingKeys, [])
        XCTAssertNil(runVim("|abc", "\"al").window.register)
    }

    func test_an_invalid_register_name_fails() {
        let run = runVim("|abc", "\"!")
        XCTAssertNil(run.window.register)
        XCTAssertEqual(run.effects, [.failure])
    }

    func test_an_unknown_command_fails_and_clears_the_pending_keys() {
        let run = runVim("|abc", "2g<Del>")
        XCTAssertEqual(run.window.pendingKeys, [])
        XCTAssertNil(run.window.count)
        XCTAssertEqual(run.effects, [.failure])
    }

    func test_visual_modes_leave_the_state_alone_until_they_are_built() {
        var window = VimWindowState()
        window.mode = .visual
        let run = runVim("a|bc", "l", window: window)
        XCTAssertEqual(run.window.cursor, 1)
        XCTAssertEqual(run.window.mode, .visual)
        XCTAssertEqual(run.effects, [])
    }

    // MARK: Marks

    func test_backtick_returns_to_a_mark_and_quote_to_its_line() {
        assertVim("ab|c\nd\nef", "maG`a", "ab|c\nd\nef")
        assertVim("ab|c\nd\n  ef", "maG'a", "|abc\nd\n  ef")
    }

    func test_a_mark_is_stored_as_a_line_and_column() {
        let run = runVim("abc\nd|ef", "mq")
        XCTAssertEqual(run.window.marks["q"], Mark(line: 1, column: 1))
    }

    func test_an_unset_mark_fails_with_e20() {
        let run = assertVim("ab|c", "`b", "ab|c")
        XCTAssertEqual(run.effects, [.message("E20: Mark not set"), .failure])
    }

    func test_double_quote_marks_return_to_the_position_before_the_last_jump() {
        assertVim("ab|c\nd\n  ef", "G``", "ab|c\nd\n  ef")
        assertVim("ab|c\nd\n  ef", "G''", "|abc\nd\n  ef")
        assertVim("ab|c\nd\n  ef", "''", "|abc\nd\n  ef")
    }

    func test_quote_quote_twice_swaps_back() {
        let text = numberedLines(40)
        let run = runVim(text, "5G''''")
        XCTAssertEqual(run.rendered, numberedLines(40, cursorLine: 4, column: 2))
    }

    func test_bracket_and_visual_marks_are_read_from_the_window() {
        var window = VimWindowState()
        window.marks["["] = Mark(line: 1, column: 1)
        window.lastVisual = LastVisual(mode: .visual, anchor: Mark(line: 2, column: 1),
                                       cursor: Mark(line: 0, column: 2))
        assertVim("|abc\ndef\nghi", "`[", "abc\nd|ef\nghi", window: window)
        assertVim("|abc\ndef\nghi", "`<lt>", "ab|c\ndef\nghi", window: window)
        assertVim("|abc\ndef\nghi", "`>", "abc\ndef\ng|hi", window: window)
    }

    // MARK: Jump list

    func test_control_o_walks_back_through_the_jump_list() {
        let text = numberedLines(40)
        XCTAssertEqual(lineOf(runVim(text, "10G20G30G<C-o>")), 19)
        XCTAssertEqual(lineOf(runVim(text, "10G20G30G<C-o><C-o>")), 9)
        XCTAssertEqual(lineOf(runVim(text, "10G20G30G3<C-o>")), 0)
    }

    func test_control_o_past_the_oldest_jump_fails() {
        let run = runVim(numberedLines(40), "10G20G30G4<C-o>")
        XCTAssertEqual(lineOf(run), 29)
        XCTAssertEqual(run.effects, [.failure])
        XCTAssertEqual(runVim(numberedLines(40), "<C-o>").effects, [.failure])
    }

    func test_control_i_and_tab_walk_forward_again() {
        let text = numberedLines(40)
        XCTAssertEqual(lineOf(runVim(text, "10G20G30G<C-o><C-o><C-i>")), 19)
        XCTAssertEqual(lineOf(runVim(text, "10G20G30G<C-o><C-o><Tab>")), 19)
        let past = runVim(text, "10G20G30G<C-o><C-i><C-i>")
        XCTAssertEqual(lineOf(past), 29)
        XCTAssertEqual(past.effects, [.failure])
    }

    func test_the_jump_list_keeps_one_entry_per_line() {
        let text = numberedLines(40)
        XCTAssertEqual(lineOf(runVim(text, "10G20G10G<C-o>")), 19)
        XCTAssertEqual(lineOf(runVim(text, "10G20G10G<C-o><C-o>")), 0)
    }

    func test_quote_quote_is_itself_a_jump() {
        XCTAssertEqual(lineOf(runVim(numberedLines(40), "10G20G''<C-o>")), 19)
    }
}
