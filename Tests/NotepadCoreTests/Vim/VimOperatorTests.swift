import XCTest
@testable import NotepadCore

/// Expected text, cursors and registers were taken from Vim 9.1 (`vim -u NONE -N` with
/// `ts=4 sw=4 et so=0 nrformats=bin,hex`), except where a test says Amber differs.
final class VimOperatorTests: XCTestCase {
    // MARK: d

    func test_d_with_a_word_motion_deletes_to_the_next_word_into_the_small_delete_register() {
        let run = assertVim("foo |bar baz\nqux", "dw", "foo |baz\nqux")
        XCTAssertEqual(run.register("\""), charwise("bar "))
        XCTAssertEqual(run.register("-"), charwise("bar "))
        XCTAssertNil(run.register("1"))
    }

    func test_dw_on_the_last_word_of_a_line_stops_at_the_line_end() {
        assertVim("foo |bar\n  qux x", "dw", "foo| \n  qux x")
        assertVim("foo b|ar", "dw", "foo |b")
    }

    func test_dw_across_lines_with_a_count_fills_register_one() {
        let run = assertVim("|foo bar\n  qux x", "3dw", "|x")
        XCTAssertEqual(run.register("1"), charwise("foo bar\n  qux "))
        XCTAssertNil(run.register("-"))
    }

    func test_a_count_before_and_after_the_operator_multiply() {
        let run = assertVim("f|oo\n  bar\nbaz", "2d3w", "|f")
        XCTAssertEqual(run.register("\""), charwise("oo\n  bar\nbaz"))
        assertVim("|a b c d e f g h", "2d2w", "|e f g h")
    }

    func test_dd_deletes_lines_and_lands_on_the_first_non_blank() {
        let run = assertVim("foo\n  b|ar\nbaz", "dd", "foo\n|baz")
        XCTAssertEqual(run.register("1"), linewise("  bar\n"))
        assertVim("foo\nb|ar\n  baz", "dd", "foo\n  |baz")
    }

    func test_dd_on_the_last_line_also_removes_the_preceding_line_break() {
        assertVim("foo\n  bar\nb|az", "dd", "foo\n  |bar")
        assertVim("foo\nb|az\n", "dd", "|foo\n")
        assertVim("a|bc", "dd", "|")
    }

    func test_dd_keeps_crlf_line_breaks() {
        let run = assertVim("a\r\nb|c\r\nd", "dd", "a\r\n|d")
        XCTAssertEqual(run.register("\""), linewise("bc\n"))
        assertVim("a\r\nb|c", "dd", "|a")
    }

    func test_dd_takes_a_whole_emoji_line() {
        let run = assertVim("x\n|👍🏽b\ny", "dd", "x\n|y")
        XCTAssertEqual(run.register("\""), linewise("👍🏽b\n"))
    }

    func test_a_count_on_dd_past_the_end_deletes_to_the_last_line() {
        assertVim("f|oo\n  bar\nbaz", "5dd", "|")
    }

    func test_a_count_on_dd_from_the_last_line_fails() {
        let run = assertVim("a\n  |foo", "2dd", "a\n  |foo")
        XCTAssertEqual(run.effects, [.failure])
    }

    func test_linewise_motions_delete_whole_lines() {
        assertVim("foo\n  b|ar\nbaz", "dk", "|baz")
        assertVim("a\n|b\nc", "d2j", "|a")
        assertVim("foo\nba|r\nbaz", "dgg", "|baz")
        assertVim("foo\nba|r\nbaz", "dG", "|foo")
    }

    func test_a_linewise_motion_that_cannot_move_cancels_the_operator() {
        let run = assertVim("|a\nb", "dk", "|a\nb")
        XCTAssertEqual(run.effects, [.failure])
    }

    func test_inclusive_and_exclusive_character_motions() {
        assertVim("a|bc def", "dfe", "a|f")
        assertVim("a|bc def", "dte", "a|ef")
        assertVim("abc d|ef", "dFb", "a|ef")
        assertVim("abc d|ef", "dTb", "ab|ef")
        assertVim("a|bc", "d0", "|bc")
        assertVim("  a|bc", "d^", "  |bc")
        assertVim("  ab|c", "dg_", "  a|b")
        assertVim("ab|c\nde", "d2$", "a|b")
    }

    func test_d_percent_fills_both_register_one_and_the_small_delete_register() {
        let run = assertVim("a (b|c) d", "d%", "a |) d")
        XCTAssertEqual(run.register("1"), charwise("(bc"))
        XCTAssertEqual(run.register("-"), charwise("(bc"))
    }

    func test_d_brace_ending_in_column_one_stops_at_the_previous_line_end() {
        let run = assertVim("a\n  f|oo\nbar\n\nx", "d}", "a\n  |f\n\nx")
        XCTAssertEqual(run.register("\""), charwise("oo\nbar"))
    }

    func test_d_brace_from_the_indent_becomes_linewise() {
        let run = assertVim("a\n  |foo\nbar\n\nx", "d}", "a\n|\nx")
        XCTAssertEqual(run.register("\""), linewise("  foo\nbar\n"))
    }

    func test_a_multiline_delete_leaving_only_blanks_from_the_indent_is_linewise() {
        let run = assertVim("|foo\nbar", "d}", "|")
        XCTAssertEqual(run.register("\""), linewise("foo\nbar\n"))
    }

    func test_dollar_on_an_empty_line_deletes_nothing() {
        let run = assertVim("x\n\n|\ny", "d$", "x\n\n|\ny")
        XCTAssertNil(run.register("\""))
        XCTAssertEqual(run.effects, [])
    }

    func test_dl_on_an_empty_line_deletes_nothing_without_failing() {
        let run = assertVim("foo\n|\nbar", "dl", "foo\n|\nbar")
        XCTAssertEqual(run.effects, [])
    }

    func test_dh_at_the_line_start_deletes_nothing_without_failing() {
        let run = assertVim("|ab", "dh", "|ab")
        XCTAssertEqual(run.effects, [])
        assertVim("a|b", "dh", "|b")
    }

    func test_shift_with_h_at_the_line_start_still_shifts_the_line() {
        assertVim("|foo\nbar", ">h", "    |foo\nbar")
    }

    func test_d_space_takes_the_last_character_before_counting_the_line_break() {
        XCTAssertEqual(assertVim("|a\nb", "d<Space>", "|\nb").register("\""), charwise("a"))
        assertVim("  |a", "d<Space>", " | ")
        XCTAssertEqual(assertVim("|ab\ncd", "3d<Space>", "|cd").register("\""),
                       linewise("ab\n"))
        XCTAssertEqual(assertVim("|ab\ncd", "4d<Space>", "|d").register("\""),
                       charwise("ab\nc"))
        XCTAssertEqual(assertVim("|ab\ncd\nef", "5d<Space>", "|ef").register("\""),
                       linewise("ab\ncd\n"))
        XCTAssertEqual(assertVim("|ab\ncd", "y3<Space>", "|ab\ncd").register("\""),
                       linewise("ab\n"))
    }

    func test_d_backspace_at_a_line_start_deletes_only_the_line_break() {
        XCTAssertEqual(assertVim("ab\n|cd", "d<BS>", "ab|cd").register("\""), charwise("\n"))
        XCTAssertEqual(assertVim("ab\n|cd", "2d<BS>", "a|cd").register("\""),
                       charwise("b\n"))
        assertVim("ab\n|cd", "c<BS>X<Esc>", "ab|Xcd")
        XCTAssertEqual(assertVim("\n|cd", "d<BS>", "|cd").register("\""), linewise("\n"))
    }

    func test_y_backspace_at_a_line_start_yanks_the_last_character_before() {
        XCTAssertEqual(assertVim("ab\n|cd", "y<BS>", "a|b\ncd").register("\""), charwise("b"))
    }

    func test_dw_at_the_end_of_the_text_still_deletes_without_failing() {
        let run = assertVim("foo |bar", "d2e", "foo| ")
        XCTAssertEqual(run.effects, [])
    }

    func test_db_that_cannot_start_moving_cancels_the_operator_but_moves_the_cursor() {
        let run = assertVim("\nf|oo", "3db", "|\nfoo")
        XCTAssertEqual(run.effects, [.failure])
        XCTAssertNil(run.register("\""))
        assertVim("\nfoo b|ar", "3dge", "|\nfoo bar")
    }

    func test_db_that_reaches_the_start_of_the_text_deletes() {
        let run = assertVim("foo bar\nbaz |x", "9db", "|x")
        XCTAssertEqual(run.register("\""), charwise("foo bar\nbaz "))
    }

    func test_escape_cancels_a_pending_operator() {
        let run = assertVim("a|bc", "d<Esc>l", "ab|c")
        XCTAssertEqual(run.window.mode, .normal)
        XCTAssertEqual(run.effects, [])
    }

    func test_an_operator_waits_in_operator_pending_mode() {
        let run = runVim("a|bc", "2d3")
        XCTAssertEqual(run.window.mode, .operatorPending)
        XCTAssertEqual(run.window.operatorKeys, [VimKey(.character("d"))])
        XCTAssertEqual(run.window.leadingCount, 2)
        XCTAssertEqual(run.window.count, 3)
    }

    func test_an_unknown_key_after_an_operator_fails_and_returns_to_normal_mode() {
        let run = runVim("a|bc", "d<C-x>")
        XCTAssertEqual(run.window.mode, .normal)
        XCTAssertEqual(run.window.operatorKeys, [])
        XCTAssertEqual(run.effects, [.failure])
    }

    // MARK: c

    func test_cw_on_a_word_changes_to_its_end() {
        let run = assertVim("foo b|ar baz", "cwX<Esc>", "foo b|X baz")
        XCTAssertEqual(run.register("-"), charwise("ar"))
        XCTAssertEqual(run.window.mode, .normal)
        assertVim("fo|o", "cwX<Esc>", "fo|X")
        assertVim("foo |bar baz", "2cwX<Esc>", "foo |X")
        assertVim("|a b c", "2c2wX<Esc>", "|X")
    }

    func test_cw_on_blanks_changes_up_to_the_next_word() {
        assertVim("foo  |  bar", "cwX<Esc>", "foo  |Xbar")
    }

    func test_ce_changes_to_the_end_of_the_word() {
        assertVim("foo |bar baz", "ceX<Esc>", "foo |X baz")
    }

    func test_cc_replaces_the_lines_with_one_empty_line() {
        let run = assertVim("  foo\n  b|ar\nbaz", "ccX<Esc>", "  foo\n|X\nbaz")
        XCTAssertEqual(run.register("1"), linewise("  bar\n"))
        assertVim("foo\nba|r\nbaz", "cjX<Esc>", "foo\n|X")
        assertVim("x\n  |a", "c_X<Esc>", "x\n|X")
    }

    func test_cc_keeps_the_indent_with_autoindent() {
        assertVim("  foo\n  b|ar\nbaz", "ccX<Esc>", "  foo\n  |X\nbaz",
                  session: session { $0.autoindent = true })
    }

    func test_c_with_a_text_object() {
        assertVim("x |(a) y", "ci(Z<Esc>", "x (|Z) y")
    }

    func test_c_enters_insert_mode_at_the_start_of_the_change() {
        let run = runVim("foo b|ar baz", "cw")
        XCTAssertEqual(run.window.mode, .insert)
        XCTAssertEqual(run.text, "foo b baz")
        XCTAssertEqual(run.window.cursor, 5)
    }

    // MARK: y

    func test_yw_yanks_into_the_unnamed_register_and_register_zero() {
        let run = assertVim("|foo bar\nbaz", "yw", "|foo bar\nbaz")
        XCTAssertEqual(run.register("\""), charwise("foo "))
        XCTAssertEqual(run.register("0"), charwise("foo "))
        XCTAssertEqual(run.effects, [])
    }

    func test_yank_moves_the_cursor_to_the_start_of_the_text() {
        assertVim("foo b|ar\nbaz", "yiw", "foo |bar\nbaz")
        assertVim("foo\nb|ar\nbaz", "yk", "f|oo\nbar\nbaz")
        assertVim("f(a, (b|), c)", "yi(", "f(a, (|b), c)")
    }

    func test_yank_of_lines_keeps_the_cursor() {
        let run = assertVim("foo\nb|ar\nbaz", "yj", "foo\nb|ar\nbaz")
        XCTAssertEqual(run.register("0"), linewise("bar\nbaz\n"))
        XCTAssertEqual(assertVim("foo\nb|ar\nbaz", "yy", "foo\nb|ar\nbaz").register("0"),
                       linewise("bar\n"))
        XCTAssertEqual(assertVim("|a", "y_", "|a").register("0"), linewise("a\n"))
    }

    func test_y_brace_from_the_indent_yanks_lines() {
        let run = assertVim("a\n  |foo\nbar\n\nx", "y}", "a\n  |foo\nbar\n\nx")
        XCTAssertEqual(run.register("0"), linewise("  foo\nbar\n"))
    }

    func test_y_dollar_yanks_to_the_end_of_the_line() {
        let run = assertVim("foo b|ar baz", "y$", "foo b|ar baz")
        XCTAssertEqual(run.register("0"), charwise("ar baz"))
    }

    func test_yl_on_an_empty_line_yanks_empty_text() {
        let run = assertVim("foo\n|\nbar", "yl", "foo\n|\nbar")
        XCTAssertEqual(run.register("0"), charwise(""))
    }

    // MARK: < and >

    func test_shift_right_adds_a_shiftwidth_and_lands_on_the_first_non_blank() {
        assertVim("  foo\n|bar\nbaz", ">>", "  foo\n    |bar\nbaz")
        assertVim("  foo\n |bar\nbaz", ">>", "  foo\n     |bar\nbaz")
        assertVim("  foo\n|bar\nbaz", "2>>", "  foo\n    |bar\n    baz")
        assertVim("  foo\n|bar\nbaz", ">j", "  foo\n    |bar\n    baz")
    }

    func test_shift_left_removes_a_shiftwidth() {
        assertVim("  foo\n  b|ar\nbaz", "<lt><lt>", "  foo\n|bar\nbaz")
        assertVim("  foo\n      b|ar\nbaz", "<lt><lt>", "  foo\n  |bar\nbaz")
        assertVim("|\tfoo", "<lt><lt>", "|foo")
    }

    func test_shift_rebuilds_tab_indent_with_spaces_under_expandtab() {
        assertVim("|  \tfoo", ">>", "        |foo")
        assertVim("|\tfoo", ">>", "        |foo")
    }

    func test_shift_uses_tabs_without_expandtab() {
        assertVim("|  foo", ">>", "\t  |foo", session: session { $0.expandtab = false })
    }

    func test_shift_skips_empty_lines() {
        assertVim("|foo\n\nbar", ">2j", "    |foo\n\n    bar")
        assertVim("|foo\n\nbar", ">ip", "    |foo\n\nbar")
    }

    func test_shift_keeps_crlf_and_emoji() {
        assertVim("|a\r\nb\r\nc", "2>>", "    |a\r\n    b\r\nc")
        assertVim("👍🏽|x", ">>", "    |👍🏽x")
    }

    // MARK: gu gU g~ g?

    func test_gU_uppercases_a_motion_or_text_object_and_keeps_the_cursor_at_its_start() {
        assertVim("foo b|ar baz", "gUiw", "foo |BAR baz")
        assertVim("foo b|ar", "gUb", "foo |Bar")
        assertVim("a\nfoo b|ar", "gUk", "|A\nFOO BAR")
    }

    func test_gUU_and_gUgU_uppercase_the_line() {
        assertVim("foo b|ar baz", "gUU", "|FOO BAR BAZ")
        assertVim("foo b|ar baz", "gUgU", "|FOO BAR BAZ")
        assertVim("  |foo", "gUU", "  |FOO")
        assertVim("|  foo", "gUU", "|  FOO")
    }

    func test_a_count_on_gUU_keeps_the_cursor() {
        assertVim("foo b|ar\nbaz", "2gUU", "FOO B|AR\nBAZ")
    }

    func test_gu_lowercases() {
        assertVim("FOO B|AR BAZ", "guw", "FOO B|ar BAZ")
        assertVim("FOO B|AR BAZ", "guu", "|foo bar baz")
        assertVim("FOO B|AR BAZ", "gugu", "|foo bar baz")
    }

    func test_g_tilde_toggles_case() {
        assertVim("Foo B|ar baz", "g~w", "Foo B|AR baz")
        assertVim("Foo B|ar baz", "g~~", "|fOO bAR BAZ")
        assertVim("Foo B|ar baz", "g~g~", "|fOO bAR BAZ")
    }

    func test_g_question_rotates_letters_by_thirteen() {
        assertVim("foo b|ar Baz", "g?w", "foo b|ne Baz")
        assertVim("foo b|ar Baz", "g??", "|sbb one Onm")
        assertVim("foo b|ar Baz", "g?g?", "|sbb one Onm")
    }

    func test_case_operators_map_one_character_to_one_character() {
        assertVim("stra|ße", "gUiw", "|STRAẞE")
        assertVim("|émile", "gUiw", "|ÉMILE")
    }

    func test_case_operators_write_no_register() {
        XCTAssertNil(runVim("x |abc", "\"agUiw").register("a"))
    }

    // MARK: =

    func test_equals_copies_the_indent_of_the_previous_line() {
        assertVim("    foo\n|bar\n  baz", "=j", "    foo\n    |bar\n    baz")
        assertVim("  foo\n      b|ar", "==", "  foo\n  |bar")
    }

    func test_equals_skips_blank_lines_when_choosing_the_indent_and_empties_them() {
        assertVim("  foo\n   \n|bar", "==", "  foo\n   \n  |bar")
        assertVim("  foo\n|   \nbar", "=j", "  foo\n|\n  bar")
    }

    func test_equals_on_the_first_line_removes_its_indent() {
        assertVim("  f|oo", "==", "|foo")
    }

    func test_equals_with_a_text_object() {
        assertVim("  x\n\na\nb|c\n d", "=ip", "  x\n\n  |a\n  bc\n  d")
    }
}
