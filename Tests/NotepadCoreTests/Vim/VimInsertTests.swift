import XCTest
@testable import NotepadCore

/// Expected text and cursors were taken from Vim 9.1 (`vim -u NONE -N` with
/// `ts=4 sw=4 et so=0`, so `backspace=indent,eol,start`), except where a test says Amber
/// differs.
final class VimInsertTests: XCTestCase {
    // MARK: Leaving Insert mode

    func test_control_bracket_and_control_c_leave_insert_mode_like_escape() {
        assertVim("|one", "3ix<C-[>", "xx|xone")
        let run = assertVim("|one", "3ix<C-c>", "xx|xone")
        XCTAssertEqual(run.window.mode, .normal)
    }

    func test_escape_with_control_held_still_leaves_insert_mode() {
        let run = assertVim("|one", "ix<C-Esc>", "|xone")
        XCTAssertEqual(run.window.mode, .normal)
    }

    func test_control_bracket_and_control_c_cancel_a_pending_normal_command() {
        let run = assertVim("o|ne", "2d<C-c>x", "o|e")
        XCTAssertEqual(run.effects, [])
        assertVim("o|ne", "2d<C-[>x", "o|e")
    }

    // MARK: Backspace, Control-W and Control-U

    func test_backspace_deletes_before_the_insert_start() {
        assertVim("one |two\nthree", "a<BS><BS><BS><BS><BS>y<Esc>", "|ywo\nthree")
    }

    func test_backspace_at_a_line_start_joins_the_line_to_the_one_above() {
        assertVim("one two\n|three", "I<BS><BS>z<Esc>", "one tw|zthree")
        assertVim("a\r\n|b", "i<BS><Esc>", "|ab")
    }

    func test_backspace_at_the_start_of_the_text_does_nothing() {
        let run = assertVim("|ab", "i<BS>x<Esc>", "|xab")
        XCTAssertEqual(run.effects, [])
    }

    func test_backspace_deletes_a_whole_grapheme_cluster() {
        assertVim("a👍🏽|b", "i<BS><Esc>", "|ab")
    }

    func test_control_w_deletes_a_word_and_stops_once_at_the_insert_start() {
        assertVim("one |two\nthree", "ifoo<C-w>x<Esc>", "one |xtwo\nthree")
        assertVim("one |two\nthree", "ifoo<C-w><C-w>x<Esc>", "|xtwo\nthree")
    }

    func test_control_w_stops_at_a_change_of_character_class() {
        assertVim("|", "ifoo.bar<C-w>x<Esc>", "foo.|x")
        assertVim("|", "ifoo..<C-w>x<Esc>", "foo|x")
    }

    func test_control_w_at_a_line_start_joins_the_lines() {
        assertVim("one two\n|three", "a<C-w><C-w><C-w>z<Esc>", "one |zhree")
    }

    func test_control_u_deletes_to_the_insert_start_then_to_the_line_start() {
        assertVim("one |two\nthree", "ifoo bar<C-u>z<Esc>", "one |ztwo\nthree")
        assertVim("one |two\nthree", "ifoo bar<C-u><C-u>z<Esc>", "|ztwo\nthree")
    }

    func test_control_u_keeps_the_indent_under_autoindent() {
        let indented = session { $0.autoindent = true }
        assertVim("    foo ba|r\nx", "A<C-u>z<Esc>", "    |z\nx", session: indented)
        assertVim("    foo ba|r\nx", "A<C-u><C-u>z<Esc>", "|z\nx", session: indented)
    }

    // MARK: Control-T and Control-D

    func test_control_t_and_control_d_change_the_indent_by_a_shiftwidth() {
        assertVim("    |one two", "i<C-t>x<Esc>", "        |xone two")
        assertVim("    |one two", "i<C-t><C-t><C-d>x<Esc>", "        |xone two")
        assertVim("    |one two", "a<C-d>x<Esc>", "o|xne two")
    }

    func test_control_t_and_control_d_round_the_indent_to_a_shiftwidth() {
        assertVim("|      one two", "i<C-t>x<Esc>", "  |x      one two")
        assertVim("  |    one two", "i<C-d>x<Esc>", "|x    one two")
        assertVim("  |    one two", "i<C-t>x<Esc>", "    |x    one two")
    }

    func test_control_d_without_an_indent_changes_nothing() {
        assertVim("thre|e", "a<C-d>x<Esc>", "three|x")
    }

    func test_control_t_uses_tabs_without_expandtab() {
        let tabs = session { $0.expandtab = false }
        assertVim("  |one", "i<C-t>x<Esc>", "\t|xone", session: tabs)
    }

    // MARK: Control-R

    func test_control_r_inserts_the_named_register() {
        assertVim("|one two\nthree", "yiwjA <C-r>\"<C-r>0<Esc>", "one two\nthree oneon|e")
    }

    func test_control_r_inserts_a_linewise_register_with_its_line_break() {
        assertVim("|one two\nxyz", "yyjli<C-r>\"<Esc>", "one two\nxone two\n|yz")
        assertVim("|one\r\nxy", "yyjli<C-r>\"<Esc>", "one\r\nxone\r\n|y")
    }

    func test_control_r_with_an_invalid_register_stays_in_insert_mode() {
        let pending = runVim("one |two", "iab<C-r><Esc>")
        XCTAssertEqual(pending.window.mode, .insert)
        assertVim("one |two", "iab<C-r><Esc><Esc>", "one a|btwo")
    }

    func test_control_r_dot_inserts_the_last_inserted_text() {
        assertVim("one |two\nthree", "ifoo<BS>x<Esc>j0i<C-r>.<Esc>", "one foxtwo\nfo|xthree")
    }

    func test_control_r_in_replace_mode_overwrites_and_backspace_restores() {
        assertVim("|one two\nxyz", "yiwjlR<C-r>\"<Esc>", "one two\nxon|e")
        assertVim("|one two\nxyz", "yiwjlR<C-r>\"<BS><BS><Esc>", "one two\nx|oz")
    }

    // MARK: Replace mode Backspace

    func test_replace_mode_backspace_restores_the_overwritten_characters() {
        assertVim("one |two\nthree", "Rab<BS><BS><BS><BS><BS><Esc>", "|one two\nthree")
    }

    func test_replace_mode_backspace_deletes_characters_added_past_the_line_end() {
        assertVim("one |two\nthree", "Rabcdef<BS><BS><BS><BS><BS><Esc>", "one |awo\nthree")
    }

    func test_replace_mode_backspace_removes_a_typed_line_break() {
        assertVim("    |one two\nthree", "Rab<CR>cd<Esc>", "    ab\nc|dtwo\nthree")
        assertVim("    |one two\nthree", "Rab<CR>cd<BS><BS><BS><Esc>", "    a|be two\nthree")
    }

    func test_a_count_on_replace_repeats_the_keys_with_backspace() {
        assertVim("one |two\nthree", "2Rab<BS>c<Esc>", "one aca|c\nthree")
    }

    // MARK: Counts and repeats

    func test_a_count_types_the_keys_again_including_backspace() {
        assertVim("|one two", "3ifoo<BS>x<Esc>", "foxfoxfo|xone two")
    }

    func test_a_count_keeps_the_insert_start_for_control_u() {
        assertVim("one |two\nthree", "3ifoo<C-u>x<Esc>", "one |xtwo\nthree")
        assertVim("one |two\nthree", "3ifoo<C-w>x<Esc>", "one |xtwo\nthree")
    }

    func test_a_count_repeats_a_backspace_over_a_typed_line_break() {
        assertVim("one |two\nthree", "3ia<CR>b<BS><BS>c<Esc>", "one acaca|ctwo\nthree")
    }

    func test_a_count_repeats_control_t() {
        assertVim("    |one two", "2i<C-t>x<Esc>", "            x|xone two")
    }

    func test_dot_replays_an_insert_with_backspace() {
        assertVim("|one", "ifoo<BS>x<Esc>.", "fofo|xxone")
    }

    func test_the_dot_register_holds_the_text_the_insert_left() {
        XCTAssertEqual(runVim("|one", "ifoo<BS>x<Esc>").register("."), charwise("fox"))
        XCTAssertEqual(runVim("|one", "ifoo<C-w>x<Esc>").register("."), charwise("x"))
        XCTAssertEqual(runVim("a|\r\nb", "ax<CR>y<Esc>").register("."), charwise("x\ny"))
        // Vim 9.1 keeps the raw Control-T byte ("\u{14}x"); Amber keeps only typed text.
        XCTAssertEqual(runVim("    |one", "i<C-t>x<Esc>").register("."), charwise("x"))
    }

    func test_control_j_types_a_line_break() {
        assertVim("one |two\nxyz", "i<C-j>x<Esc>", "one \n|xtwo\nxyz")
    }

    // MARK: Typing reported by the adapter

    func test_typed_text_moves_the_cursor_and_is_repeated_by_dot() {
        var driver = VimDriver("|one\ntwo")
        driver.press("i")
        driver.type("abc")
        XCTAssertEqual(driver.window.cursor, 3)
        driver.press("<Esc>j0.")
        XCTAssertEqual(driver.run.rendered, "abcone\nab|ctwo")
    }

    func test_typed_text_mixes_with_engine_keys_in_a_repeat() {
        var driver = VimDriver("|one\ntwo")
        driver.press("i")
        driver.type("foo")
        driver.press("<BS>")
        driver.type("x")
        driver.press("<Esc>j0.")
        XCTAssertEqual(driver.run.rendered, "foxone\nfo|xtwo")
        XCTAssertEqual(driver.run.register("."), charwise("fox"))
    }

    func test_typed_text_outside_insert_mode_is_ignored() {
        let window = VimWindowState(cursor: 1)
        let result = VimEngine.recordTyped("x", window: window, session: VimSession())
        XCTAssertEqual(result.window, window)
    }
}
