import XCTest
@testable import NotepadCore

/// Expected positions were taken from Vim 9.1 (`vim -u NONE -N` with `ts=4 sw=4 et so=0`).
final class VimMotionTests: XCTestCase {
    // MARK: h l, Backspace and Space

    func test_h_and_l_move_by_character_within_the_line() {
        assertVim("ab|cd", "h", "a|bcd")
        assertVim("a|bc", "l", "ab|c")
        assertVim("ab|cd", "<Left>", "a|bcd")
        assertVim("ab|cd", "<Right>", "abc|d")
    }

    func test_a_count_on_h_and_l_stops_at_the_line_edge() {
        assertVim("ab|cd", "5h", "|abcd")
        assertVim("a|bc", "5l", "ab|c")
    }

    func test_h_at_the_line_start_fails_without_moving() {
        let run = assertVim("|abc", "h", "|abc")
        XCTAssertEqual(run.effects, [.failure])
    }

    func test_l_never_moves_onto_the_line_break() {
        let run = assertVim("ab|c\nd", "l", "ab|c\nd")
        XCTAssertEqual(run.effects, [.failure])
    }

    func test_space_and_backspace_wrap_to_the_next_and_previous_line() {
        assertVim("ab|c\nde", "1<Space>", "abc\n|de")
        assertVim("ab|c\nde", "3<Space>", "abc\nd|e")
        assertVim("ab\n|cd", "<BS>", "a|b\ncd")
    }

    // MARK: j k

    func test_j_and_k_keep_the_desired_column_across_a_short_line() {
        assertVim("abcd|ef\nab\nabcdef", "j", "abcdef\na|b\nabcdef")
        assertVim("abcd|ef\nab\nabcdef", "jj", "abcdef\nab\nabcd|ef")
        assertVim("a|bc\n\nabc", "j", "abc\n|\nabc")
        assertVim("a|bc\n\nabc", "jj", "abc\n\na|bc")
    }

    func test_the_up_and_down_arrows_move_like_k_and_j_with_counts() {
        assertVim("ab|cd\nefgh\nij", "<Down>", "abcd\nef|gh\nij")
        assertVim("ab|cd\nefgh\nij", "2<Down>", "abcd\nefgh\ni|j")
        assertVim("ab\nefgh\ni|j", "<Up>", "ab\ne|fgh\nij")
        assertVim("ab\nefgh\ni|j", "2<Up>", "a|b\nefgh\nij")
    }

    func test_a_count_on_j_and_k_stops_at_the_first_and_last_line() {
        assertVim("a|b\ncd\nef", "5j", "ab\ncd\ne|f")
        assertVim("ab\ncd\ne|f", "2k", "a|b\ncd\nef")
    }

    func test_j_on_the_last_line_fails() {
        let run = assertVim("ab\ncd\ne|f", "j", "ab\ncd\ne|f")
        XCTAssertEqual(run.effects, [.failure])
    }

    func test_the_desired_column_is_measured_in_tabstop_columns() {
        assertVim("\t|x\nabcdefg", "j", "\tx\nabcd|efg")
        assertVim("abcdefg\n\t|x", "k", "abcd|efg\n\tx")
    }

    func test_j_after_dollar_goes_to_the_end_of_each_line() {
        assertVim("a|bc\nabcdef\nab", "$j", "abc\nabcde|f\nab")
        assertVim("a|bc\nabcdef\nab", "$jj", "abc\nabcdef\na|b")
    }

    // MARK: gj gk

    func test_gj_and_gk_move_by_screen_line_from_the_geometry() {
        let long = "abcdefghijklmnopqrstuvwxy"
        assertVim("abc|defghijklmnopqrstuvwxy\nab", "gj", "abcdefghijklmno|pqrstuvwxy\nab",
                  wrapWidth: 12)
        assertVim("abc|defghijklmnopqrstuvwxy\nab", "2gj", "abcdefghijklmnopqrstuvwx|y\nab",
                  wrapWidth: 12)
        assertVim("abc|defghijklmnopqrstuvwxy\nab", "3gj", long + "\na|b", wrapWidth: 12)
        assertVim(long + "\na|b", "2gk", "abcdefghijklm|nopqrstuvwxy\nab", wrapWidth: 12)
        assertVim(long + "\nabcdefghijklmnop|qrstuvwxy", "gk",
                  long + "\nabcd|efghijklmnopqrstuvwxy", wrapWidth: 12)
    }

    func test_gj_on_the_last_screen_line_fails() {
        let run = assertVim("abc\na|b", "gj", "abc\na|b", wrapWidth: 12)
        XCTAssertEqual(run.effects, [.failure])
    }

    // MARK: Words

    func test_w_treats_emoji_as_their_own_word_class() {
        assertVim("foo|😀😀bar.baz qux", "w", "foo😀😀|bar.baz qux")
        assertVim("|foo😀😀bar.baz qux", "2w", "foo😀😀|bar.baz qux")
        assertVim("|foo😀😀bar.baz qux", "5w", "foo😀😀bar.baz |qux")
        assertVim("|a.😀b", "3w", "a.😀|b")
    }

    func test_hiragana_katakana_and_kanji_are_word_classes_of_their_own() {
        let text = "|abcひらがなdef カタカナ漢字 x"
        assertVim(text, "w", "abc|ひらがなdef カタカナ漢字 x")
        assertVim(text, "2w", "abcひらがな|def カタカナ漢字 x")
        assertVim(text, "3w", "abcひらがなdef |カタカナ漢字 x")
        assertVim(text, "4w", "abcひらがなdef カタカナ|漢字 x")
        assertVim(text, "5w", "abcひらがなdef カタカナ漢字 |x")
        assertVim(
            "abcひらがなdef カタカナ漢字 |x", "3b", "abcひらがな|def カタカナ漢字 x"
        )
        assertVim(text, "3e", "abcひらがなde|f カタカナ漢字 x")
    }

    func test_hangul_and_ideographic_punctuation_are_word_classes_of_their_own() {
        assertVim("|한국어abc、x", "w", "한국어|abc、x")
        assertVim("|한국어abc、x", "2w", "한국어abc|、x")
        assertVim("|한국어abc、x", "3w", "한국어abc、|x")
    }

    func test_w_stops_at_punctuation_and_on_an_empty_line() {
        assertVim("|foo.bar  baz\n\n  qux", "w", "foo|.bar  baz\n\n  qux")
        assertVim("|foo.bar  baz\n\n  qux", "4w", "foo.bar  baz\n|\n  qux")
        assertVim("|foo.bar  baz\n\n  qux", "6w", "foo.bar  baz\n\n  qu|x")
    }

    func test_w_on_the_last_character_fails() {
        let run = assertVim("ab c|d", "w", "ab c|d")
        XCTAssertEqual(run.effects, [.failure])
    }

    func test_big_words_skip_punctuation() {
        assertVim("|foo.bar  baz\n\n  qux", "2W", "foo.bar  baz\n|\n  qux")
        assertVim("|foo.bar  baz\n\n  qux", "E", "foo.ba|r  baz\n\n  qux")
        assertVim("foo.bar  baz\n\n  q|ux", "3B", "foo.bar  |baz\n\n  qux")
        assertVim("foo.bar  baz\n\n  q|ux", "2gE", "foo.bar  ba|z\n\n  qux")
    }

    func test_e_b_and_ge_move_by_word_ends_and_starts() {
        assertVim("|foo.bar  baz\n\n  qux", "3e", "foo.ba|r  baz\n\n  qux")
        assertVim("foo.bar  baz\n\n  q|ux", "b", "foo.bar  baz\n\n  |qux")
        assertVim("foo.bar  baz\n\n  q|ux", "2b", "foo.bar  baz\n|\n  qux")
        assertVim("foo.bar  baz\n\n  q|ux", "ge", "foo.bar  baz\n|\n  qux")
        assertVim("foo.bar  baz\n\n  q|ux", "2ge", "foo.bar  ba|z\n\n  qux")
        assertVim("foo.bar  baz\n\n  q|ux", "3ge", "foo.ba|r  baz\n\n  qux")
        assertVim("ab\n|cd", "ge", "a|b\ncd")
    }

    func test_b_at_the_start_of_the_text_fails() {
        let run = assertVim("|ab", "b", "|ab")
        XCTAssertEqual(run.effects, [.failure])
    }

    // MARK: Line positions

    func test_dollar_rests_on_the_last_character() {
        assertVim("a|bc def", "$", "abc de|f")
        assertVim("a|bc def", "<End>", "abc de|f")
    }

    func test_a_count_on_dollar_goes_to_the_end_of_a_later_line() {
        assertVim("a|bc\ndef\nx", "2$", "abc\nde|f\nx")
        assertVim("a|bc\ndef\nx", "5$", "abc\ndef\n|x")
    }

    func test_zero_and_caret_go_to_the_line_start_and_first_non_blank() {
        assertVim("   ab|c", "0", "|   abc")
        assertVim("   ab|c", "<Home>", "|   abc")
        assertVim("   ab|c", "^", "   |abc")
        assertVim("  |  \nx", "^", "   | \nx")
    }

    func test_g_underscore_goes_to_the_last_non_blank_of_a_later_line() {
        assertVim("abc  \n|de  ", "g_", "abc  \nd|e  ")
        assertVim("|abc  \nde  ", "2g_", "abc  \nd|e  ")
    }

    func test_bar_goes_to_a_screen_column() {
        assertVim("|abcdef", "4|", "abc|def")
        assertVim("|abcdef", "20|", "abcde|f")
        assertVim("|\tab", "3|", "|\tab")
    }

    func test_bar_sets_the_desired_column_beyond_a_short_line() {
        assertVim("|abc\nabcdefgh", "6|j", "abc\nabcde|fgh")
    }

    // MARK: Lines

    func test_gg_and_G_go_to_a_line_on_its_first_non_blank() {
        assertVim("a\n  b\nc|", "gg", "|a\n  b\nc")
        assertVim("a\n  b\nc|", "2G", "a\n  |b\nc")
        assertVim("a\n  b\nc|", "2gg", "a\n  |b\nc")
        assertVim("|a\n  b\n  c", "G", "a\n  b\n  |c")
        assertVim("|a\n  b\n  c", "9G", "a\n  b\n  |c")
    }

    func test_plus_minus_underscore_and_enter_go_to_first_non_blanks() {
        assertVim("|  a\n  b\n  c", "+", "  a\n  |b\n  c")
        assertVim("|  a\n  b\n  c", "2<CR>", "  a\n  b\n  |c")
        assertVim("  a\n  b\n  |c", "-", "  a\n  |b\n  c")
        assertVim("  a\n  b\n  |c", "2-", "  |a\n  b\n  c")
        assertVim("a|b\n  c\nd", "_", "|ab\n  c\nd")
        assertVim("a|b\n  c\nd", "2_", "ab\n  |c\nd")
    }

    // MARK: f t ; ,

    func test_f_and_t_find_a_character_with_a_count() {
        assertVim("a|bcabcabc", "fc", "ab|cabcabc")
        assertVim("a|bcabcabc", "2fc", "abcab|cabc")
        assertVim("a|bcabcabc", "tc", "a|bcabcabc")
        assertVim("abcabca|bc", "Fa", "abcabc|abc")
        assertVim("abcabca|bc", "Ta", "abcabca|bc")
        assertVim("a😀|b😀c", "f😀", "a😀b|😀c")
    }

    func test_semicolon_repeats_and_comma_reverses_the_last_find() {
        assertVim("a|bcabcabc", "fc;", "abcab|cabc")
        assertVim("a|bcabcabc", "fc;,", "ab|cabcabc")
        assertVim("abcabca|bc", "Ta;", "abca|bcabc")
    }

    func test_semicolon_after_t_skips_the_adjacent_match_unless_counted() {
        assertVim("a|bcabcabc", "tc;", "abca|bcabc")
        assertVim("a|bcabcabc", "tc2;", "abca|bcabc")
        assertVim("a|bcabcabc", "tc;,", "abc|abcabc")
        assertVim("|abab", "tb;", "ab|ab")
        assertVim("|a,b,c,d", "t,1;", "a,|b,c,d")
    }

    func test_control_j_and_control_n_move_down_and_control_p_moves_up() {
        assertVim("o|ne two\nxyz", "<C-j>", "one two\nx|yz")
        assertVim("o|ne two\nxyz", "<C-n>", "one two\nx|yz")
        assertVim("one two\nx|yz", "<C-p>", "o|ne two\nxyz")
    }

    func test_a_find_that_matches_nothing_fails_and_stays_on_the_line() {
        let run = assertVim("a|bc", "fz", "a|bc")
        XCTAssertEqual(run.effects, [.failure])
        assertVim("a|bc\nc", "fc;", "ab|c\nc")
        let reversed = assertVim("abcabca|bc", "Ta,", "abcabca|bc")
        XCTAssertEqual(reversed.effects, [.failure])
    }

    func test_semicolon_without_an_earlier_find_fails() {
        let run = assertVim("a|bc", ";", "a|bc")
        XCTAssertEqual(run.effects, [.failure])
    }

    func test_the_last_find_is_shared_through_the_session() {
        let first = runVim("a|bcabc", "fc")
        XCTAssertEqual(first.session.lastFind, LastFind(character: "c", kind: .forward))
        assertVim("abca|bc", ";", "abcab|c", session: first.session)
    }

    // MARK: Sentences

    func test_close_paren_moves_to_the_next_sentence() {
        let text = "Hello |world. This is it.  Next one!\nNew line here."
        assertVim(text, ")", "Hello world. |This is it.  Next one!\nNew line here.")
        assertVim(text, "2)", "Hello world. This is it.  |Next one!\nNew line here.")
        assertVim(text, "3)", "Hello world. This is it.  Next one!\n|New line here.")
    }

    func test_open_paren_moves_to_the_start_of_a_sentence() {
        assertVim("Hello |world. This is it.  Next one!\nNew line here.", "(",
                  "|Hello world. This is it.  Next one!\nNew line here.")
        let text = "Hello world. This is it.  Next one!\nNew line h|ere."
        assertVim(text, "(", "Hello world. This is it.  Next one!\n|New line here.")
        assertVim(text, "2(", "Hello world. This is it.  |Next one!\nNew line here.")
        assertVim(text, "3(", "Hello world. |This is it.  Next one!\nNew line here.")
    }

    func test_an_empty_line_is_a_sentence_boundary() {
        let start = "One. T|wo.\n\nThree. Four."
        assertVim(start, ")", "One. Two.\n|\nThree. Four.")
        assertVim(start, "2)", "One. Two.\n\n|Three. Four.")
        assertVim(start, "3)", "One. Two.\n\nThree. |Four.")
        let end = "One. Two.\n\nThree. F|our."
        assertVim(end, "(", "One. Two.\n\nThree. |Four.")
        assertVim(end, "2(", "One. Two.\n\n|Three. Four.")
        assertVim(end, "3(", "One. Two.\n|\nThree. Four.")
        assertVim(end, "4(", "One. |Two.\n\nThree. Four.")
    }

    func test_closing_quotes_and_parens_end_a_sentence() {
        let text = "He |said \"Hi.\" Then (he left.) Done."
        assertVim(text, ")", "He said \"Hi.\" |Then (he left.) Done.")
        assertVim(text, "2)", "He said \"Hi.\" Then (he left.) |Done.")
        assertVim(text, "3)", "He said \"Hi.\" Then (he left.) Done|.")
    }

    // MARK: Paragraphs

    func test_close_brace_moves_to_the_next_empty_line() {
        let text = "|a\nb\n\nc\nd\n\n\ne"
        assertVim(text, "}", "a\nb\n|\nc\nd\n\n\ne")
        assertVim(text, "2}", "a\nb\n\nc\nd\n|\n\ne")
        assertVim(text, "3}", "a\nb\n\nc\nd\n\n\n|e")
        assertVim("|a\nb\n\n", "}", "a\nb\n|\n")
    }

    func test_close_brace_past_the_last_paragraph_fails() {
        let run = assertVim("|a\nb\n\nc\nd\n\n\ne", "4}", "|a\nb\n\nc\nd\n\n\ne")
        XCTAssertEqual(run.effects, [.failure])
    }

    func test_a_line_of_spaces_is_not_a_paragraph_boundary() {
        assertVim("|a\nb\n  \nc", "}", "a\nb\n  \n|c")
    }

    func test_open_brace_moves_to_the_previous_empty_line() {
        let text = "a\nb\n\nc\nd\n\n\ne|f"
        assertVim(text, "{", "a\nb\n\nc\nd\n\n|\nef")
        assertVim(text, "2{", "a\nb\n|\nc\nd\n\n\nef")
        assertVim(text, "3{", "|a\nb\n\nc\nd\n\n\nef")
        let run = assertVim(text, "4{", text)
        XCTAssertEqual(run.effects, [.failure])
    }

    // MARK: Percent

    func test_percent_jumps_between_nested_brackets() {
        assertVim("if |(a[(b)] {c})", "%", "if (a[(b)] {c}|)")
        assertVim("if (a[(b)] {c}|)", "%", "if |(a[(b)] {c})")
        assertVim("if (a[(|b)] {c})", "%", "if (a[|(b)] {c})")
        assertVim("i|f (a[(b)] {c})", "%", "if (a[(b)] {c}|)")
    }

    func test_percent_matches_across_lines() {
        assertVim("fn {\n  (x)\n|}", "%", "fn |{\n  (x)\n}")
        assertVim("|fn {\n  (x)\n}", "%", "fn {\n  (x)\n|}")
    }

    func test_percent_without_a_bracket_or_match_fails() {
        XCTAssertEqual(runVim("no |brackets", "%").effects, [.failure])
        XCTAssertEqual(runVim("(a\n|b", "%").effects, [.failure])
        XCTAssertEqual(runVim("|(a\nb", "%").effects, [.failure])
        XCTAssertEqual(runVim("a)|b", "%").effects, [.failure])
    }

    func test_a_count_on_percent_goes_to_that_percentage_of_the_lines() {
        let text = (1...10).map(String.init).joined(separator: "\n")
        XCTAssertEqual(runVim("|" + text, "50%").window.cursor, 8)
        XCTAssertEqual(runVim("|" + text, "33%").window.cursor, 6)
        XCTAssertEqual(runVim("|" + text, "100%").window.cursor, 18)
        XCTAssertEqual(runVim("|" + text, "1%").window.cursor, 0)
        XCTAssertEqual(runVim("|" + text, "101%").effects, [.failure])
    }

    // MARK: H M L

    func test_H_M_and_L_go_to_lines_of_the_view() {
        let text = numberedLines(30, cursorLine: 5, column: 1)
        func line(_ keys: String, _ so: Int = 0) -> Int {
            var session = VimSession()
            session.options.scrolloff = so
            let start = so == 0 ? text : numberedLines(30, cursorLine: 9, column: 1)
            let run = runVim(start, keys, session: session, lines: 10, top: 5)
            return VimBuffer(run.text as NSString).lineIndex(of: run.window.cursor)
        }
        XCTAssertEqual([line("H"), line("3H"), line("M"), line("L"), line("3L")],
                       [5, 7, 9, 14, 12])
        XCTAssertEqual([line("20H"), line("20L")], [14, 5])
        XCTAssertEqual([line("H", 3), line("3H", 3), line("M", 3), line("L", 3)],
                       [8, 8, 9, 11])
        XCTAssertEqual([line("20H", 3), line("20L", 3)], [11, 8])
    }

    func test_H_and_L_land_on_the_first_non_blank() {
        let text = numberedLines(30, cursorLine: 5, column: 1)
        let bottom = runVim(text, "L", lines: 10, top: 5)
        XCTAssertEqual(bottom.rendered, numberedLines(30, cursorLine: 14, column: 2))
    }

    func test_scrolloff_does_not_apply_at_the_start_of_the_text() {
        var session = VimSession()
        session.options.scrolloff = 3
        let text = numberedLines(30, cursorLine: 0, column: 1)
        XCTAssertEqual(runVim(text, "H", session: session, lines: 10).rendered,
                       numberedLines(30, cursorLine: 0, column: 2))
        XCTAssertEqual(runVim(text, "L", session: session, lines: 10).rendered,
                       numberedLines(30, cursorLine: 6, column: 2))
    }

    func test_M_uses_the_middle_of_the_lines_shown_when_the_text_is_short() {
        XCTAssertEqual(runVim(numberedLines(4, column: 1), "M", lines: 10).rendered,
                       numberedLines(4, cursorLine: 1))
        XCTAssertEqual(runVim(numberedLines(5, column: 1), "M", lines: 10).rendered,
                       numberedLines(5, cursorLine: 2, column: 2))
        XCTAssertEqual(runVim(numberedLines(4, column: 1), "L", lines: 10).rendered,
                       numberedLines(4, cursorLine: 3))
    }
}
