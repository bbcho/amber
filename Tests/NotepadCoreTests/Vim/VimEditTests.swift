import XCTest
@testable import NotepadCore

/// Expected text, cursors and registers were taken from Vim 9.1 (`vim -u NONE -N` with
/// `ts=4 sw=4 et so=0 nrformats=bin,hex`), except where a test says Amber differs.
final class VimEditTests: XCTestCase {
    // MARK: x X s S D C Y

    func test_x_deletes_characters_under_and_after_the_cursor_within_the_line() {
        let run = assertVim("foo b|ar baz", "3x", "foo b|baz")
        XCTAssertEqual(run.register("-"), charwise("ar "))
        assertVim("foo b|ar baz", "30x", "foo |b")
    }

    func test_x_on_an_empty_line_does_nothing() {
        let run = assertVim("foo\n|\nbar", "x", "foo\n|\nbar")
        XCTAssertEqual(run.effects, [])
    }

    func test_x_deletes_a_whole_grapheme_cluster() {
        // Vim 9.1 splits the skin-tone modifier off; Amber keeps the cluster whole.
        let run = assertVim("|👍🏽a", "x", "|a")
        XCTAssertEqual(run.register("-"), charwise("👍🏽"))
    }

    func test_X_deletes_characters_before_the_cursor() {
        assertVim("foo b|ar baz", "3X", "fo|ar baz")
        assertVim("a|b", "X", "|b")
        XCTAssertEqual(runVim("|foo", "X").effects, [])
    }

    func test_D_deletes_to_the_end_of_the_line_and_a_count_takes_more_lines() {
        assertVim("foo b|ar baz", "D", "foo |b")
        let run = assertVim("foo b|ar baz\nqux\nend", "2D", "foo |b\nend")
        XCTAssertEqual(run.register("1"), charwise("ar baz\nqux"))
    }

    func test_C_and_s_and_S_change_text() {
        assertVim("foo b|ar baz", "CX<Esc>", "foo b|X")
        assertVim("foo b|ar baz", "2sX<Esc>", "foo b|X baz")
        assertVim("  foo\n  b|ar\nbaz", "2SX<Esc>", "  foo\n|X")
    }

    func test_Y_yanks_lines_without_moving() {
        let run = assertVim("foo\nb|ar\nbaz", "2Y", "foo\nb|ar\nbaz")
        XCTAssertEqual(run.register("0"), linewise("bar\nbaz\n"))
    }

    // MARK: r R ~

    func test_r_replaces_characters_and_leaves_the_cursor_on_the_last() {
        assertVim("a|bc", "rx", "a|xc")
        assertVim("a|bc", "2rx", "ax|x")
    }

    func test_r_with_a_count_past_the_line_end_fails() {
        let run = assertVim("a|bc", "3rx", "a|bc")
        XCTAssertEqual(run.effects, [.failure])
        XCTAssertEqual(runVim("|", "rx").effects, [.failure])
    }

    func test_r_enter_replaces_the_characters_with_one_line_break() {
        assertVim("a|bc", "r<CR>", "a\n|c")
        assertVim("a|bcd", "2r<CR>", "a\n|d")
        assertVim("a|bc\r\nd", "r<CR>", "a\r\n|c\r\nd")
    }

    func test_r_replaces_a_whole_grapheme_cluster() {
        // Vim 9.1 keeps the skin-tone modifier; Amber replaces the whole cluster.
        assertVim("|👍🏽a", "rx", "|xa")
    }

    func test_R_overwrites_and_extends_past_the_line_end() {
        assertVim("a|bcd", "RXY<Esc>", "aX|Yd")
        let run = assertVim("a|b", "RXYZ<Esc>", "aXY|Z")
        XCTAssertEqual(run.window.mode, .normal)
    }

    func test_a_count_on_R_overwrites_again() {
        assertVim("a|bcdefgh", "2RXY<Esc>", "aXYX|Yfgh")
    }

    func test_tilde_toggles_case_and_moves_right() {
        assertVim("a|bc", "~", "aB|c")
        assertVim("a|bc", "5~", "aB|C")
        assertVim("a|bC d", "3~", "aBc |d")
        assertVim("x|a", "~~~", "x|A")
    }

    func test_tilde_on_an_empty_line_fails() {
        XCTAssertEqual(runVim("|", "~").effects, [.failure])
    }

    // MARK: J gJ

    func test_J_joins_with_one_space_after_removing_the_indent() {
        assertVim("|foo\n  bar", "J", "foo| bar")
        assertVim("|foo\n\tbar", "J", "foo| bar")
        assertVim("|a\nb\nc\nd", "3J", "a b| c\nd")
    }

    func test_J_adds_two_spaces_after_a_sentence_end() {
        assertVim("|foo.\nbar", "J", "foo.|  bar")
    }

    func test_J_adds_no_space_after_a_blank_or_before_a_parenthesis() {
        assertVim("|foo \n  bar", "J", "foo |bar")
        assertVim("|foo\n)bar", "J", "foo|)bar")
    }

    func test_J_with_an_empty_line_adds_no_space() {
        assertVim("|foo\n\nbar", "J", "fo|o\nbar")
        assertVim("|foo\n  \nbar", "3J", "foo| bar")
    }

    func test_J_on_the_last_line_fails() {
        let run = assertVim("a\nb\nc|de", "J", "a\nb\nc|de")
        XCTAssertEqual(run.effects, [.failure])
    }

    func test_a_count_on_J_past_the_last_line_stops_there() {
        assertVim("|a\nb\nc", "9J", "a b| c")
        let run = assertVim("a\nb\nc|de", "5J", "a\nb\n|cde")
        XCTAssertEqual(run.effects, [])
    }

    func test_gJ_joins_without_changing_blanks() {
        assertVim("|a\n  b", "gJ", "a|  b")
        assertVim("|a\n  b\nc", "3gJ", "a  b|c")
    }

    func test_J_keeps_crlf_and_emoji() {
        assertVim("|a\r\nb\r\nc", "J", "a| b\r\nc")
        assertVim("|👍🏽\n👍🏽", "J", "👍🏽| 👍🏽")
    }

    // MARK: p P gp gP ]p [p

    func test_p_puts_characters_after_the_cursor_and_lands_on_the_last() {
        assertVim("|foo bar", "yiwwp", "foo bfo|oar")
        assertVim("|foo bar", "yiww3p", "foo bfoofoofo|oar")
        assertVim("|foo bar", "yiw$p", "foo barfo|o")
    }

    func test_P_puts_characters_before_the_cursor() {
        assertVim("|foo bar", "yiwwP", "foo fo|obar")
    }

    func test_gp_and_gP_leave_the_cursor_after_the_text() {
        assertVim("|foo bar", "yiwwgp", "foo bfoo|ar")
        assertVim("|foo bar", "yiwwgP", "foo foo|bar")
        assertVim("|foo bar", "yiw$gp", "foo barfo|o")
    }

    func test_p_on_an_empty_line_puts_at_the_cursor() {
        assertVim("a|bc\n\ndef", "yiwjp", "abc\nab|c\ndef")
        assertVim("a|bc\n\ndef", "yiwjP", "abc\nab|c\ndef")
    }

    func test_p_of_characters_over_lines_lands_on_the_start_of_the_text() {
        let yanked = charwise("bc\nde")
        var start = VimSession()
        start.registers.yank(yanked, into: nil)
        assertVim("a|bc\ndef", "p", "ab|bc\ndec\ndef", session: start)
        assertVim("abc\nd|ef", "P", "abc\nd|bc\ndeef", session: start)
        assertVim("abc\nd|ef", "2p", "abc\nde|bc\ndebc\ndef", session: start)
        assertVim("a|bc\ndef", "gp", "abbc\nde|c\ndef", session: start)
        assertVim("a|bc\ndef", "gP", "abc\nde|bc\ndef", session: start)
    }

    func test_p_puts_lines_below_and_lands_on_the_first_non_blank() {
        assertVim("a|b\ncd", "yjjp", "ab\ncd\n|ab\ncd")
        assertVim("a|b\ncd\nef", "yyj2p", "ab\ncd\n|ab\nab\nef")
        assertVim("a|b\ncd", "yyGp", "ab\ncd\n|ab")
        assertVim("|  a\nb", "yyjp", "  a\nb\n  |a")
    }

    func test_P_puts_lines_above() {
        assertVim("a|b\ncd", "yjjP", "ab\n|ab\ncd\ncd")
        assertVim("|a\nb\nc", "yjP", "|a\nb\na\nb\nc")
    }

    func test_gp_and_gP_with_lines_land_on_the_line_after() {
        assertVim("a|b\ncd\nef", "yyjgp", "ab\ncd\nab\n|ef")
        assertVim("a|b\ncd\nef", "yyjgP", "ab\nab\n|cd\nef")
        assertVim("a|b\ncd", "yyjgp", "ab\ncd\n|ab")
    }

    func test_p_of_lines_keeps_the_document_line_breaks() {
        assertVim("a|b\r\ncd\r\n", "yyp", "ab\r\n|ab\r\ncd\r\n")
        assertVim("a|b\r\ncd", "yyjp", "ab\r\ncd\r\n|ab")
    }

    func test_p_of_lines_after_a_final_line_break() {
        assertVim("a|b\ncd\n", "yyjp", "ab\ncd\n|ab\n")
    }

    func test_p_of_an_emoji_lands_on_the_whole_cluster() {
        assertVim("|👍🏽 x", "ylwp", "👍🏽 x|👍🏽")
    }

    func test_bracket_p_adjusts_the_indent_to_the_current_line() {
        assertVim("  a|b\n      cd", "yyj]p", "  ab\n      cd\n      |ab")
        assertVim("  a|b\n      cd", "yyj[p", "  ab\n      |ab\n      cd")
        assertVim("      a|b\n  cd", "yyj]p", "      ab\n  cd\n  |ab")
        assertVim("  a|b\n  x\ncd", "yjG]p", "  ab\n  x\ncd\n|ab\nx")
    }

    func test_bracket_p_with_characters_is_p() {
        assertVim("  a|b\ncd", "yiwj]p", "  ab\ncda|b")
    }

    func test_p_from_an_empty_register_fails_with_e353() {
        let run = assertVim("a|b", "\"ap", "a|b")
        XCTAssertEqual(run.effects, [.message("E353: Nothing in register a"), .failure])
        XCTAssertEqual(runVim("|", "p").effects,
                       [.message("E353: Nothing in register \""), .failure])
    }

    // MARK: Control-A and Control-X

    func test_control_a_adds_the_count_to_the_number_at_or_after_the_cursor() {
        assertVim("x |7 y", "<C-a>", "x |8 y")
        assertVim("x |7 y", "5<C-a>", "x 1|2 y")
        assertVim("|x 7 y", "<C-a>", "x |8 y")
        assertVim("x| 9-3", "<C-a>", "x 1|0-3")
        assertVim("word1|0", "<C-a>", "word1|1")
    }

    func test_control_x_subtracts_and_crosses_zero() {
        assertVim("x |7 y", "10<C-x>", "x -|3 y")
        assertVim("x |1 y", "2<C-x>", "x -|1 y")
    }

    func test_a_minus_before_the_number_makes_it_negative() {
        assertVim("x -|7 y", "<C-a>", "x -|6 y")
        assertVim("x |-7 y", "10<C-a>", "x |3 y")
        assertVim("x |-1 y", "<C-a>", "x |0 y")
        assertVim("a-|1", "<C-a>", "a|0")
    }

    func test_leading_zeros_keep_the_width_of_a_decimal_number() {
        assertVim("x |007 y", "<C-a>", "x 00|8 y")
        assertVim("x |009 y", "<C-a>", "x 01|0 y")
        assertVim("x |010 y", "<C-x>", "x 00|9 y")
    }

    func test_decimal_numbers_use_an_unsigned_magnitude() {
        assertVim("x |9223372036854775807 y", "<C-a>", "x 922337203685477580|8 y")
        assertVim("x |18446744073709551615 y", "<C-a>", "x -1844674407370955161|5 y")
    }

    func test_hex_numbers_under_nrformats() {
        assertVim("x 0x0|f y", "<C-a>", "x 0x1|0 y")
        assertVim("x |0xff y", "<C-a>", "x 0x10|0 y")
        assertVim("x |0xff y", "<C-x>", "x 0xf|e y")
        assertVim("x |0x00 y", "<C-x>", "x 0xfffffffffffffff|f y")
        assertVim("x 0|x1f", "<C-a>", "x 0x2|0")
        assertVim("x |0XFE y", "<C-a>", "x 0XF|F y")
    }

    func test_binary_numbers_under_nrformats() {
        assertVim("x |0b101 y", "<C-a>", "x 0b11|0 y")
        assertVim("x |0b000 y", "<C-a>", "x 0b00|1 y")
    }

    func test_without_hex_in_nrformats_a_hex_number_is_decimal() {
        assertVim("x |0x7 y", "<C-a>", "x |1x7 y", session: session { $0.nrformats = "" })
    }

    func test_a_zero_x_without_hex_digits_is_decimal() {
        assertVim("x |0x", "<C-a>", "x |1x")
    }

    func test_control_a_without_a_number_fails() {
        let run = assertVim("x |abc y", "<C-a>", "x |abc y")
        XCTAssertEqual(run.effects, [.failure])
        XCTAssertEqual(runVim("x 0x0F| y", "<C-a>").effects, [.failure])
    }

    // MARK: Insert mode

    func test_i_a_I_A_insert_text_and_escape_steps_left() {
        assertVim("a|bc", "ifoo<Esc>", "afo|obc")
        assertVim("a|bc", "afoo<Esc>", "abfo|oc")
        assertVim("  a|bc", "Ifoo<Esc>", "  fo|oabc")
        assertVim("  a|bc", "Afoo<Esc>", "  abcfo|o")
        assertVim("|", "afoo<Esc>", "fo|o")
    }

    func test_escape_at_the_line_start_stays() {
        assertVim("a|bc", "i<Esc>", "|abc")
        assertVim("|abc", "i<Esc>", "|abc")
    }

    func test_insert_mode_reports_its_mode_and_cursor() {
        let run = runVim("a|bc", "ixy")
        XCTAssertEqual(run.window.mode, .insert)
        XCTAssertEqual(run.rendered, "axy|bc")
    }

    func test_a_count_on_insert_repeats_the_text() {
        assertVim("a|bc", "3ix<Esc>", "axx|xbc")
        assertVim("a|bc", "3axy<Esc>", "abxyxyx|yc")
    }

    func test_o_and_O_open_lines() {
        assertVim("a|bc\nd", "ofoo<Esc>", "abc\nfo|o\nd")
        assertVim("a|bc\nd", "Ofoo<Esc>", "fo|o\nabc\nd")
        assertVim("a|bc\nd", "2ofoo<Esc>", "abc\nfoo\nfo|o\nd")
        assertVim("|", "ofoo<Esc>", "\nfo|o")
    }

    func test_o_copies_the_indent_with_autoindent() {
        assertVim("  a|bc\nd", "ofoo<Esc>", "  abc\n  fo|o\nd",
                  session: session { $0.autoindent = true })
    }

    func test_o_keeps_crlf_line_breaks() {
        assertVim("a|bc\r\nd", "ofoo<Esc>", "abc\r\nfo|o\r\nd")
        assertVim("a\r\nb|c", "ofoo<Esc>", "a\r\nbc\r\nfo|o")
    }

    func test_gi_inserts_where_insert_mode_last_stopped() {
        assertVim("a|bc\nd", "ix<Esc>jgiy<Esc>", "ax|ybc\nd")
        assertVim("a|bc\nd", "gix<Esc>", "a|xbc\nd")
    }

    func test_tab_in_insert_mode_inserts_spaces_to_the_next_tabstop_under_expandtab() {
        assertVim("a|b", "i<Tab>x<Esc>", "a   |xb")
        assertVim("|ab", "i<Tab>x<Esc>.", "        |xxab")
        assertVim("a|b", "2i<Tab><Esc>", "a      | b")
    }

    func test_tab_in_insert_mode_inserts_a_tab_without_expandtab() {
        assertVim("|ab", "i<Tab>x<Esc>.", "\t\t|xxab", session: session { $0.expandtab = false })
    }

    func test_enter_in_insert_mode_breaks_the_line() {
        assertVim("a|bc", "i<CR><Esc>", "a\n|bc")
        assertVim("a|bc\r\nd", "i<CR><Esc>", "a\r\n|bc\r\nd")
        assertVim("|abc", "ofoo<CR>bar<Esc>.", "abc\nfoo\nbar\nfoo\nba|r")
    }

    func test_enter_in_insert_mode_copies_the_indent_with_autoindent() {
        let indented = session { $0.autoindent = true }
        assertVim("  a|bc", "i<CR><Esc>", "  a\n | bc", session: indented)
        assertVim("  |abc", "ofoo<CR>bar<Esc>.", "  abc\n  foo\n  bar\n  foo\n  ba|r",
                  session: indented)
        assertVim("  a|bc", "2ix<CR>y<Esc>", "  ax\n  yx\n  |ybc", session: indented)
    }

    func test_the_dot_register_holds_tabs_and_line_breaks_as_typed() {
        let run = assertVim("a|b", "ix<Tab>y<CR>z<Esc>", "ax  y\n|zb")
        XCTAssertEqual(run.register("."), charwise("x\ty\nz"))
    }

    func test_the_dot_register_holds_the_last_inserted_text() {
        let run = assertVim("a|bc", "ixy<Esc>\".p", "axyx|ybc")
        XCTAssertEqual(run.register("."), charwise("xy"))
    }

    // MARK: gq

    func test_gq_wraps_lines_at_textwidth() {
        let narrow = session { $0.textwidth = 10 }
        assertVim("|aaa bbb ccc ddd eee fff", "gqq", "aaa bbb\nccc ddd\n|eee fff",
                  session: narrow)
        assertVim("|aaa bbb ccc ddd eee fff", "gqgq", "aaa bbb\nccc ddd\n|eee fff",
                  session: narrow)
        assertVim("|aaa    bbb   ccc", "gqq", "aaa    bbb\n|ccc", session: narrow)
        assertVim("|aaaaaaaaaaaaaa bbb", "gqq", "aaaaaaaaaaaaaa\n|bbb", session: narrow)
    }

    func test_gq_joins_the_lines_of_a_paragraph_first() {
        let narrow = session { $0.textwidth = 10 }
        assertVim("|aaa bbb\nccc ddd eee fff\n\nggg hhh", "gqip",
                  "aaa bbb\nccc ddd\n|eee fff\n\nggg hhh", session: narrow)
        assertVim("|aaa bbb\nccc ddd eee fff\n\nggg hhh", "gqG",
                  "aaa bbb\nccc ddd\neee fff\n\n|ggg hhh", session: narrow)
        assertVim("|aaa\n  bbb ccc ddd eee fff", "gqj", "aaa bbb\nccc ddd\n|eee fff",
                  session: narrow)
        assertVim("|aaa\n  \nbbb", "gqG", "aaa\n  \n|bbb", session: narrow)
    }

    func test_gq_keeps_the_first_indent_and_indents_the_rest_only_with_autoindent() {
        assertVim("|  aaa bbb ccc ddd eee fff", "gqq", "  aaa bbb\nccc ddd\n|eee fff",
                  session: session { $0.textwidth = 10 })
        assertVim("|  aaa bbb ccc ddd eee fff", "gqq", "  aaa bbb\n  ccc ddd\n  |eee fff",
                  session: session { $0.textwidth = 10; $0.autoindent = true })
    }

    func test_gq_without_textwidth_wraps_at_79() {
        let letters = "a b c d e f g h i j k l m n o p q r s t u v w x y z "
        let long = letters + letters + "a b c d"
        let first = letters + letters.prefix(27)
        assertVim("|" + long, "gqq", first + "\n|o p q r s t u v w x y z a b c d")
    }

    func test_gq_keeps_crlf_line_breaks() {
        assertVim("|aaa bbb ccc\r\nx", "gqq", "aaa bbb\r\n|ccc\r\nx",
                  session: session { $0.textwidth = 10 })
    }

    // MARK: Registers

    func test_a_named_register_takes_deletes_yanks_and_changes() {
        let deleted = runVim("a |b c d", "\"a2dw")
        XCTAssertEqual(deleted.text, "a d")
        XCTAssertEqual(deleted.register("a"), charwise("b c "))
        XCTAssertEqual(deleted.register("1"), charwise("b c "))
        XCTAssertEqual(runVim("|foo bar", "\"ayiw").register("a"), charwise("foo"))
        let changed = assertVim("a |b c", "\"acwX<Esc>\"ap", "a X|b c")
        XCTAssertEqual(changed.register("a"), charwise("b"))
    }

    func test_an_uppercase_register_appends() {
        assertVim("a|b c", "\"ayiww\"Ayiw\"Ap", "ab cab|c")
        let lines = assertVim("|a\nb", "\"ayy\"Ayy\"ap", "a\n|a\na\nb")
        XCTAssertEqual(lines.register("a"), linewise("a\na\n"))
        let mixed = runVim("a |b c d", "\"ayy\"Ayw")
        XCTAssertEqual(mixed.register("a"), linewise("a b c d\nb \n"))
        XCTAssertEqual(runVim("a |b c d", "\"adw\"Adw").register("a"), charwise("b c "))
    }

    func test_counts_around_a_register_multiply() {
        let run = assertVim("|abcdefg", "2\"a3x", "|g")
        XCTAssertEqual(run.register("a"), charwise("abcdef"))
        XCTAssertNil(run.window.register)
    }

    func test_the_black_hole_register_keeps_the_other_registers() {
        let run = assertVim("|abc def", "yiw\"_dd", "|")
        XCTAssertEqual(run.register("\""), charwise("abc"))
        XCTAssertNil(run.register("1"))
        assertVim("|a b c", "yiw\"_dwP", "|ab c")
    }

    func test_the_plus_register_sets_the_system_clipboard() {
        let run = assertVim("|foo bar", "\"+yiw", "|foo bar")
        XCTAssertEqual(run.effects, [.setClipboard("foo")])
        XCTAssertEqual(runVim("|foo\nbar", "\"*dd").effects, [.setClipboard("foo\n")])
    }

    func test_the_plus_register_puts_from_the_system_clipboard() {
        assertVim("|ab", "\"+p", "ax|yb", clipboard: "xy")
        assertVim("|ab", "\"+p", "ab\n|xy", clipboard: "xy\n")
    }

    func test_clipboard_unnamed_sends_unnamed_yanks_to_the_clipboard() {
        let run = runVim("|foo bar", "yiw", session: session { $0.clipboard = "unnamed" })
        XCTAssertEqual(run.effects, [.setClipboard("foo")])
    }

    func test_yank_into_a_read_only_register_fails() {
        let run = runVim("|foo", "\".yiw")
        XCTAssertEqual(run.effects, [.failure])
        XCTAssertNil(run.register("\""))
    }

    // MARK: Repeat, undo and redo

    func test_dot_repeats_dw_and_a_new_count_replaces_the_old() {
        assertVim("|a b c d e f", "dw.", "|c d e f")
        assertVim("|a b c d e f", "dw3.", "|e f")
        assertVim("|a b c d e f", "2dw.", "|e f")
        assertVim("|a b c d e f", "2dw3..", "|")
    }

    func test_dot_returns_the_recorded_keys_as_a_replay() {
        let run = runVim("|a b c d e f", "2dw3.")
        XCTAssertTrue(run.effects.contains(.replay(try VimKey.parse("3dw"))))
        XCTAssertEqual(run.session.lastChange?.keys, try VimKey.parse("dw"))
        XCTAssertEqual(run.session.lastChange?.count, 3)
    }

    func test_dot_repeats_an_insert_change() {
        assertVim("foo |bar baz", "ciwX<Esc>w.", "foo X |X")
        assertVim("foo |bar baz qux", "ciwX<Esc>w2.", "foo X |Xqux")
        assertVim("|abc", "afoo<Esc>.", "afoofo|obc")
        assertVim("|abc", "ofoo<Esc>.", "abc\nfoo\nfo|o")
        assertVim("|ab", "3ix<Esc>.", "xxxx|xxab")
        assertVim("|ab", "3ix<Esc>2.", "xxx|xxab")
    }

    func test_dot_repeats_x_shift_and_put_with_a_new_count() {
        assertVim("|abcdefghij", "3x.", "|ghij")
        assertVim("|abcdefghij", "3x2.", "|fghij")
        assertVim("|a\nb\nc\nd", ">>j.", "    a\n    |b\nc\nd")
        assertVim("|a\nb\nc\nd", ">>j2.", "    a\n    |b\n    c\nd")
        assertVim("|a b", "yiwwp.", "a ba|a")
        assertVim("|a b", "yiwwp3.", "a baaa|a")
        assertVim("|a\nb", "yyp.", "a\na\n|a\nb")
    }

    func test_dot_repeats_other_edits() {
        assertVim("|abcdef", "2rxll.", "xxcx|xf")
        assertVim("|aaaa", "~.", "AA|aa")
        assertVim("|7", "5<C-a>.", "1|7")
        assertVim("|a\nb\nc\nd\ne", "3J2.", "a b c| d\ne")
        assertVim("a |b c d", "\"adw.", "a |d")
    }

    func test_dot_after_a_put_from_a_numbered_register_uses_the_next_one() {
        assertVim("|a\nb\nc\nd", "dddddd\"1p.", "d\nc\n|b")
        assertVim("|a\nb\nc\nd", "dddddd\"1p..", "d\nc\nb\n|a")
    }

    func test_dot_with_a_register_uses_that_register() {
        let run = runVim("a |b c d", "dw\"a.")
        XCTAssertEqual(run.register("a"), charwise("c "))
    }

    func test_yanks_and_motions_are_not_repeated_by_dot() {
        assertVim("|a b c", "dwyiww.", "b| ")
    }

    func test_dot_without_a_change_fails() {
        XCTAssertEqual(runVim("|abc", ".").effects, [.failure])
    }

    func test_u_and_control_r_ask_the_adapter_to_undo_and_redo() {
        XCTAssertEqual(runVim("|abc", "u").effects, [.undo(1)])
        XCTAssertEqual(runVim("|abc", "3u").effects, [.undo(3)])
        XCTAssertEqual(runVim("|abc", "<C-r>").effects, [.redo(1)])
        XCTAssertEqual(runVim("|abc", "2<C-r>").effects, [.redo(2)])
    }
}
