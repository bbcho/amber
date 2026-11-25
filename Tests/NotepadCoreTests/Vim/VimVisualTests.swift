import XCTest
@testable import NotepadCore

/// Expected text, cursors, registers and marks were taken from Vim 9.1 (`vim -u NONE -N` with
/// `ts=4 sw=4 et so=0`), except where a test says Amber differs. In the rendered text `[...]`
/// is a selection and `|` the cursor, which in Visual mode sits on the character after it.
final class VimVisualTests: XCTestCase {
    // MARK: Selections

    func test_v_selects_from_the_anchor_through_the_character_under_the_cursor() {
        let run = assertVim("a|bcd", "vl", "a[b|c]d")
        XCTAssertEqual(run.window.mode, .visual)
        assertVim("abc|d", "vhh", "a[|bcd]")
    }

    func test_v_dollar_puts_the_cursor_after_the_last_character_and_takes_the_line_break() {
        assertVim("a|bc\nde", "v$", "a[bc|\n]de")
        assertVim("a|bc\ndefg\nh", "v$j", "a[bc\ndefg|\n]h")
    }

    func test_l_in_visual_mode_may_reach_the_end_of_the_line() {
        assertVim("ab|c\nd", "vl", "ab[c|\n]d")
        assertVim("ab|c", "vll", "ab[c|]")
    }

    func test_v_on_an_empty_line_selects_its_line_break() {
        assertVim("|\nab", "v", "[|\n]ab")
    }

    func test_V_selects_whole_lines_with_their_line_breaks() {
        let run = assertVim("a|bc\nde\nf", "Vj", "[abc\nd|e\n]f")
        XCTAssertEqual(run.window.mode, .visualLine)
        assertVim("ab\nc|d", "V", "ab\n[c|d]")
    }

    func test_control_v_selects_one_range_per_line_and_none_on_lines_that_end_before_it() {
        let run = assertVim("ab|cdef\na\nabc\nabcdef", "<C-v>3jl",
                            "ab[cd]ef\na\nab[c]\nab[c|d]ef")
        XCTAssertEqual(run.window.mode, .visualBlock)
        XCTAssertEqual(run.window.cursor, 16)
    }

    func test_control_v_counts_a_tab_up_to_the_next_tabstop() {
        assertVim("a\tbc\nabc|defgh", "<C-v>lk", "a[\t|b]c\nabc[de]fgh")
    }

    func test_control_v_dollar_selects_to_the_end_of_every_line() {
        assertVim("a|bcdef\nab\nabcd", "<C-v>2j$", "a[bcdef]\na[b]\na[bcd|]")
    }

    func test_a_block_selection_reports_one_range_for_every_line() {
        let run = assertVim("ab|cdef\na\nabc", "<C-v>2j", "ab[c]def\na\nab[|c]")
        XCTAssertEqual(run.selections, [NSRange(location: 2, length: 1),
                                        NSRange(location: 8, length: 0),
                                        NSRange(location: 11, length: 1)])
    }

    // MARK: Switching and leaving

    func test_typing_another_visual_key_switches_mode_and_keeps_the_anchor() {
        assertVim("a|bc\nde", "vjV", "[abc\nd|e]")
        assertVim("a|bc\nde", "vj<C-v>", "a[b]c\nd[|e]")
        assertVim("a|bc\nde", "Vjv", "a[bc\nd|e]")
    }

    func test_the_mode_key_again_or_escape_leaves_visual_mode() {
        let run = assertVim("a|bc", "vlv", "ab|c")
        XCTAssertEqual(run.window.mode, .normal)
        assertVim("a|bc", "Vl<Esc>", "ab|c")
        assertVim("a|bc\nd", "v$<Esc>", "ab|c\nd")
        assertVim("a|bc\nde", "<C-v>j<C-v>", "abc\nd|e")
    }

    func test_an_unknown_key_beeps_and_stays_in_visual_mode() {
        let run = assertVim("a|bc", "vlzq", "a[b|c]")
        XCTAssertEqual(run.effects, [.failure])
    }

    // MARK: o O gv and the Visual marks

    func test_o_moves_the_cursor_to_the_other_end() {
        assertVim("a|bcdef\n123456", "vjlo", "a[|bcdef\n123]456")
        assertVim("a|bcdef\n123456", "vjlo<Esc>", "a|bcdef\n123456")
        assertVim("a|bcdef\n123456", "vjllO", "a[|bcdef\n1234]56")
    }

    func test_O_in_block_mode_moves_the_cursor_to_the_other_corner_on_its_line() {
        assertVim("a|bcdef\n123456", "<C-v>jllO", "a[bcd]ef\n1[|234]56")
        assertVim("a|bcdef\n123456", "<C-v>jllO<Esc>", "abcdef\n1|23456")
    }

    func test_gv_reselects_the_last_selection_by_line_and_column_after_an_edit() {
        assertVim("a|bcdef\n123456", "vjl<Esc>gg0gv", "a[bcdef\n12|3]456")
        assertVim("ab|cdef\n123456", "vjl<Esc>gg0xgvd", "bc|56")
        assertVim("a|bcdef\nab\nabcd", "<C-v>2j$<Esc>gggv", "a[bcdef]\na[b]\na[bcd|]")
    }

    func test_gv_in_visual_mode_exchanges_the_current_and_the_previous_selection() {
        assertVim("a|bcdef\n123456", "vl<Esc>jVgvd", "a|def\n123456")
    }

    func test_gv_without_a_previous_selection_fails() {
        let run = assertVim("a|b", "gv", "a|b")
        XCTAssertEqual(run.effects, [.failure])
    }

    func test_the_visual_marks_hold_the_last_selection() {
        assertVim("a|bcdef\n123456", "vjh<Esc>gg`>", "abcdef\n|123456")
        assertVim("abcdef\n12|3456", "vkl<Esc>G`<lt>", "abc|def\n123456")
        assertVim("abcdef\n12|3456", "vkl<Esc>gg`>", "abcdef\n12|3456")
        assertVim("a|bcdef\n123456", "Vj<Esc>gg`>", "abcdef\n12345|6")
        assertVim("abcdef\n12|3456", "Vk<Esc>G`<lt>", "|abcdef\n123456")
    }

    // MARK: Operators in every mode

    private static let before = "  aB|cd\n  eFgh\nij"

    /// Every operator after `vj`, `Vj` and `<C-v>jl` on `before`, with Vim's result. `=` copies
    /// the previous line's indent in Amber, which here gives the same text as Vim.
    private static let operatorCases: [(keys: String, after: String)] = [
        ("vjd", "  aB|h\nij"), ("vjcXY<Esc>", "  aBX|Yh\nij"), ("vjy", "  aB|cd\n  eFgh\nij"),
        ("vj<lt>", "|aBcd\neFgh\nij"), ("vj>", "      |aBcd\n      eFgh\nij"),
        ("vj2>", "          |aBcd\n          eFgh\nij"),
        ("vjgu", "  aB|cd\n  efgh\nij"), ("vjgU", "  aB|CD\n  EFGh\nij"),
        ("vjg~", "  aB|CD\n  EfGh\nij"), ("vjg?", "  aB|pq\n  rSth\nij"),
        ("vj=", "|aBcd\neFgh\nij"), ("vjgq", "  |aBcd eFgh\nij"),
        ("vjx", "  aB|h\nij"), ("vjX", "|ij"), ("vjD", "|ij"), ("vjCXY<Esc>", "X|Y\nij"),
        ("vjsXY<Esc>", "  aBX|Yh\nij"), ("vjSXY<Esc>", "X|Y\nij"), ("vjRXY<Esc>", "X|Y\nij"),
        ("vjY", "|  aBcd\n  eFgh\nij"), ("vj~", "  aB|CD\n  EfGh\nij"),
        ("vju", "  aB|cd\n  efgh\nij"), ("vjU", "  aB|CD\n  EFGh\nij"),
        ("vjJ", "  aBcd| eFgh\nij"), ("vjgJ", "  aBcd|  eFgh\nij"),
        ("vjrx", "  aB|xx\nxxxxxh\nij"),

        ("Vjd", "|ij"), ("VjcXY<Esc>", "X|Y\nij"), ("Vjy", "|  aBcd\n  eFgh\nij"),
        ("Vj<lt>", "|aBcd\neFgh\nij"), ("Vj>", "      |aBcd\n      eFgh\nij"),
        ("Vj2>", "          |aBcd\n          eFgh\nij"),
        ("Vjgu", "|  abcd\n  efgh\nij"), ("VjgU", "|  ABCD\n  EFGH\nij"),
        ("Vjg~", "|  AbCD\n  EfGH\nij"), ("Vjg?", "|  nOpq\n  rStu\nij"),
        ("Vj=", "|aBcd\neFgh\nij"), ("Vjgq", "  |aBcd eFgh\nij"),
        ("Vjx", "|ij"), ("VjX", "|ij"), ("VjD", "|ij"), ("VjCXY<Esc>", "X|Y\nij"),
        ("VjsXY<Esc>", "X|Y\nij"), ("VjSXY<Esc>", "X|Y\nij"), ("VjRXY<Esc>", "X|Y\nij"),
        ("VjY", "|  aBcd\n  eFgh\nij"), ("Vj~", "|  AbCD\n  EfGH\nij"),
        ("Vju", "|  abcd\n  efgh\nij"), ("VjU", "|  ABCD\n  EFGH\nij"),
        ("VjJ", "  aBcd| eFgh\nij"), ("VjgJ", "  aBcd|  eFgh\nij"),
        ("Vjrx", "|xxxxxx\nxxxxxx\nij"),

        ("<C-v>jld", "  a|B\n  eF\nij"), ("<C-v>jlcXY<Esc>", "  aBX|Y\n  eFXY\nij"),
        ("<C-v>jly", "  aB|cd\n  eFgh\nij"), ("<C-v>jl<lt>", "  aB|cd\n  eFgh\nij"),
        ("<C-v>jl>", "  aB|    cd\n  eF    gh\nij"),
        ("<C-v>jl2>", "  aB|        cd\n  eF        gh\nij"),
        ("<C-v>jlgu", "  aB|cd\n  eFgh\nij"), ("<C-v>jlgU", "  aB|CD\n  eFGH\nij"),
        ("<C-v>jlg~", "  aB|CD\n  eFGH\nij"), ("<C-v>jlg?", "  aB|pq\n  eFtu\nij"),
        ("<C-v>jl=", "|aBcd\neFgh\nij"), ("<C-v>jlgq", "  |aBcd eFgh\nij"),
        ("<C-v>jlx", "  a|B\n  eF\nij"), ("<C-v>jlX", "  a|B\n  eF\nij"),
        ("<C-v>jlD", "  a|B\n  eF\nij"), ("<C-v>jlCXY<Esc>", "  aBX|Y\n  eFXY\nij"),
        ("<C-v>jlsXY<Esc>", "  aBX|Y\n  eFXY\nij"), ("<C-v>jlSXY<Esc>", "X|Y\nij"),
        ("<C-v>jlRXY<Esc>", "X|Y\nij"), ("<C-v>jlY", "  aB|cd\n  eFgh\nij"),
        ("<C-v>jl~", "  aB|CD\n  eFGH\nij"), ("<C-v>jlu", "  aB|cd\n  eFgh\nij"),
        ("<C-v>jlU", "  aB|CD\n  eFGH\nij"), ("<C-v>jlJ", "  aBcd| eFgh\nij"),
        ("<C-v>jlgJ", "  aBcd|  eFgh\nij"), ("<C-v>jlrx", "  aB|xx\n  eFxx\nij"),
    ]

    func test_every_operator_works_in_every_visual_mode() {
        for (keys, after) in Self.operatorCases {
            let run = assertVim(Self.before, keys, after)
            XCTAssertEqual(run.window.mode, .normal, keys)
        }
    }

    private static let registerCases: [(keys: String, value: RegisterValue)] = [
        ("vjd", charwise("cd\n  eFg")), ("vjy", charwise("cd\n  eFg")),
        ("vjX", linewise("  aBcd\n  eFgh\n")), ("vjY", linewise("  aBcd\n  eFgh\n")),
        ("vjCXY<Esc>", linewise("  aBcd\n  eFgh\n")), ("Vjd", linewise("  aBcd\n  eFgh\n")),
        ("Vjy", linewise("  aBcd\n  eFgh\n")), ("<C-v>jld", blockwise("cd\ngh", width: 2)),
        ("<C-v>jlY", blockwise("cd\ngh", width: 2)), ("<C-v>jlX", blockwise("cd\ngh", width: 2)),
        ("<C-v>jlSXY<Esc>", linewise("  aBcd\n  eFgh\n")),
    ]

    func test_visual_deletes_and_yanks_fill_the_registers_as_vim_does() {
        for (keys, value) in Self.registerCases {
            let run = runVim(Self.before, keys)
            XCTAssertEqual(run.register("\""), value, keys)
        }
        let small = runVim("a|bcd", "vld")
        XCTAssertEqual(small.register("-"), charwise("bc"))
        XCTAssertNil(small.register("1"))
        XCTAssertEqual(runVim(Self.before, "vjd").register("1"), charwise("cd\n  eFg"))
        XCTAssertEqual(runVim(Self.before, "<C-v>jld").register("1"),
                       blockwise("cd\ngh", width: 2))
        XCTAssertEqual(runVim("a|bcd", "<C-v>ld").register("-"), blockwise("bc", width: 2))
    }

    func test_a_register_name_before_a_visual_operator_picks_the_register() {
        let run = assertVim("a|bcd", "vl\"ay", "a|bcd")
        XCTAssertEqual(run.register("a"), charwise("bc"))
    }

    func test_v_dollar_yank_takes_the_line_break_as_a_newline_in_crlf_text() {
        let run = assertVim("a|bc\r\nd", "v$y", "a|bc\r\nd")
        XCTAssertEqual(run.register("\""), charwise("bc\n"))
        assertVim("a|bc\r\nd\r\ne", "v$d", "a|d\r\ne")
    }

    func test_a_charwise_delete_from_the_indent_keeps_its_lines() {
        // Unlike `d` with a motion, Visual `d` never turns into a linewise delete.
        assertVim("|  ab\n  cd", "vjd", "| cd")
    }

    func test_visual_line_delete_keeps_crlf_line_breaks() {
        assertVim("a\r\nb|c\r\nd\r\n", "Vd", "a\r\n|d\r\n")
    }

    func test_yank_and_delete_set_the_change_marks() {
        let yank = runVim("foo |bar baz\nqux", "v$y")
        XCTAssertEqual(yank.window.marks["["], Mark(line: 0, column: 4))
        XCTAssertEqual(yank.window.marks["]"], Mark(line: 0, column: 10))
        let block = runVim(Self.before, "<C-v>jld")
        XCTAssertEqual(block.window.marks["["], Mark(line: 0, column: 4))
        XCTAssertEqual(block.window.marks["]"], Mark(line: 1, column: 4))
        let lines = runVim(Self.before, "Vjy")
        XCTAssertEqual(lines.window.marks["["], Mark(line: 0, column: 0))
        XCTAssertEqual(lines.window.marks["]"], Mark(line: 1, column: Int.max))
        let word = runVim("foo |bar baz\nqux", "yw")
        XCTAssertEqual(word.window.marks["]"], Mark(line: 0, column: 7))
        let deleted = runVim("foo\nbar\n|baz", "dd")
        XCTAssertEqual(deleted.window.marks["["], Mark(line: 2, column: 0))
    }

    // MARK: Blocks

    func test_block_delete_and_yank_on_ragged_lines() {
        let run = assertVim("ab|cdef\na\nabc\nabcdef", "<C-v>3jld", "ab|ef\na\nab\nabef")
        XCTAssertEqual(run.register("\""), blockwise("cd\n  \nc\ncd", width: 2))
        let dollar = assertVim("a|bcdef\n\nabcd", "<C-v>2j$y", "a|bcdef\n\nabcd")
        XCTAssertEqual(dollar.register("\""), blockwise("bcdef\n      \nbcd", width: 5))
    }

    func test_block_delete_splits_a_tab_into_the_spaces_outside_the_block() {
        let run = assertVim("a\tbc\nab|cdefgh", "<C-v>llkd", "a |c\nabfgh")
        XCTAssertEqual(run.register("\""), blockwise("  b\ncde", width: 3))
        assertVim("ab|cd\na\tb\nabcd", "<C-v>2jd", "ab|d\na  b\nabd")
    }

    func test_block_D_and_C_reach_the_end_of_every_line() {
        let run = assertVim("a|bcdef\n\nabcd\na", "<C-v>3jD", "|a\n\na\na")
        XCTAssertEqual(run.register("\""), blockwise("bcdef\n      \nbcd\n", width: 5))
        assertVim("a|bcdef\n\nabcd\na", "<C-v>3jCXY<Esc>", "aX|Y\n\naXY\naXY")
    }

    func test_block_I_inserts_on_every_line_that_reaches_the_block() {
        assertVim("a|bcdef\na\nabcd", "<C-v>2jIXY<Esc>", "a|XYbcdef\naXY\naXYbcd")
        assertVim("a|bcdef\n\nabcd", "<C-v>2jIX<Esc>", "a|Xbcdef\n\naXbcd")
        assertVim("a|bc\ndef", "<C-v>IX<Esc>", "a|Xbc\ndef")
    }

    func test_block_I_splits_a_tab_that_straddles_the_block() {
        assertVim("ab|cd\na\tb\nabcd", "<C-v>2jIX<Esc>", "ab|Xcd\na X  b\nabXcd")
        assertVim("a\tbc\nab|cdefgh", "<C-v>kIX<Esc>", "a|X\tbc\naXbcdefgh")
    }

    func test_block_I_with_a_line_break_inserts_only_once() {
        assertVim("a|bc\ndef", "<C-v>jIX<CR>Y<Esc>", "aX\n|Ybc\ndef")
    }

    func test_block_A_appends_after_the_block_and_pads_short_lines() {
        assertVim("a|bcdef\na\nabcd", "<C-v>2jlAXY<Esc>", "a|bcXYdef\na  XY\nabcXYd")
        assertVim("a|bcdef\n\nabcd", "<C-v>2jlAX<Esc>", "a|bcXdef\n   X\nabcXd")
        assertVim("a|bc\ndef", "<C-v>AX<Esc>", "a|bXc\ndef")
        assertVim("ab|cd\na\tb\nabcd", "<C-v>2jAX<Esc>", "ab|cXd\na  X b\nabcXd")
        assertVim("a\tbc\nab|cdefgh", "<C-v>kAX<Esc>", "a|\tXbc\nabcdXefgh")
    }

    func test_block_dollar_A_appends_at_the_end_of_every_line() {
        assertVim("a|bcdef\na\nabcd", "<C-v>2j$AXY<Esc>", "a|bcdefXY\naXY\nabcdXY")
        assertVim("a|bcdef\n\nabcd", "<C-v>2j$AX<Esc>", "a|bcdefX\nX\nabcdX")
    }

    func test_block_c_replaces_the_block_on_every_line_that_reaches_it() {
        let run = assertVim("a|bcdef\n\nabcd\nab\nabcde", "<C-v>4jlcXY<Esc>",
                            "aX|Ydef\n\naXYd\naXY\naXYde")
        XCTAssertEqual(run.register("\""), blockwise("bc\n  \nbc\nb\nbc", width: 2))
        assertVim("ab|cd\na\tb\nabcd", "<C-v>2jcX<Esc>", "ab|Xd\na X b\nabXd")
    }

    func test_block_r_replaces_every_column_and_splits_tabs() {
        assertVim("a|bcdef\na\nabcd", "<C-v>2jlrX", "a|XXdef\na\naXXd")
        assertVim("a\tbc\nab|cdefgh", "<C-v>llkrX", "a| XXXc\nabXXXfgh")
        assertVim("ab|cd\na\tb\nabcd", "<C-v>2jrX", "ab|Xd\na X b\nabXd")
    }

    func test_block_x_deletes_the_block() {
        assertVim("a|bcdef\na\nabcd", "<C-v>lx", "a|def\na\nabcd")
    }

    func test_block_case_change_skips_tabs() {
        assertVim("ab|cd\na\tb\nabcd", "<C-v>2jU", "ab|Cd\na\tb\nabCd")
        assertVim("a|bcd\nef", "<C-v>j$U", "a|BCD\neF")
    }

    func test_block_shift_moves_the_text_from_the_block_start() {
        assertVim("a|  bc\nd\tef", "<C-v>j>", "a|      bc\nd       ef")
        assertVim("ab|c\n\nd\nefg", "<C-v>3j>", "ab|    c\n\nd\nef    g")
        assertVim("a|      bc\nd\tef\nx  y", "<C-v>jj<lt>", "a|  bc\ndef\nxy")
        assertVim("ab|c\n\nd\ne    fg", "<C-v>3j<lt>", "ab|c\n\nd\ne fg")
        let noExpand = session { $0.expandtab = false }
        assertVim("a|bc\ndef", "<C-v>j>", "a|\t bc\nd\t ef", session: noExpand)
    }

    func test_block_edits_keep_crlf_line_breaks() {
        assertVim("ab|c\r\ndef\r\n", "<C-v>jd", "a|b\r\nde\r\n")
        assertVim("a|bc\r\ndef", "<C-v>jIX<Esc>", "a|Xbc\r\ndXef")
    }

    // MARK: Putting a blockwise register

    func test_p_puts_a_block_after_the_cursor_column_on_each_line() {
        let run = assertVim("|ab\ncd\nxyz\n123", "<C-v>jlyjjp", "ab\ncd\nx|abyz\n1cd23")
        XCTAssertEqual(run.window.marks["["], Mark(line: 2, column: 1))
        XCTAssertEqual(run.window.marks["]"], Mark(line: 3, column: 2))
        assertVim("|abc", "<C-v>lyp", "a|abbc")
    }

    func test_P_puts_a_block_before_the_cursor_and_a_count_repeats_it_across() {
        assertVim("|abcdef\nab\nabc\nabcdef", "<C-v>3jlyggP", "|ababcdef\nabab\nababc\nababcdef")
        assertVim("|abcdef\nab\nabc\nabcdef", "<C-v>3jlygg2p",
                  "a|ababbcdef\naababb\naababbc\naababbcdef")
        assertVim("|ab\ncd\nxyz", "<C-v>jlyG03P", "ab\ncd\n|abababxyz\ncdcdcd")
    }

    func test_a_block_put_pads_short_lines_and_adds_lines_past_the_end() {
        assertVim("|abcdef\nab\nabc\nabcdef", "<C-v>3jlyG$p",
                  "abcdef\nab\nabc\nabcdef|ab\n      ab\n      ab\n      ab")
        assertVim("|ab\ncd\nxyz", "<C-v>jlyGp", "ab\ncd\nx|abyz\n cd")
        assertVim("ab|cdef\nab\nabc\nabcdef\n12345\n1", "<C-v>jy5G$p",
                  "abcdef\nab\nabc\nabcdef\n12345|c\n1    ")
        assertVim("|ab\ncd\n\n123", "<C-v>jlyjjp", "ab\ncd\n|ab\ncd123")
    }

    func test_a_block_put_pads_lines_that_continue_to_the_block_width() {
        assertVim("|a\tb\ncd\nxyz\n123", "<C-v>j$yGp", "a\tb\ncd\nxyz\n1|a\tb23\n cd")
        assertVim("|ab\ncd\nx\tz\n123", "<C-v>jlyjjlp", "ab\ncd\nx\t|abz\n123 cd")
    }

    func test_gp_and_gP_leave_the_cursor_after_the_put_block() {
        assertVim("|ab\ncd\nxyz\n123", "<C-v>jlyjjgp", "ab\ncd\nxabyz\n1cd|23")
        assertVim("|ab\ncd\nxyz\n123", "<C-v>jlyjjgP", "ab\ncd\nabxyz\ncd|123")
    }

    func test_a_block_put_past_the_end_uses_the_document_line_break() {
        assertVim("|ab\r\ncd\r\nxyz", "<C-v>jlyGp", "ab\r\ncd\r\nx|abyz\r\n cd")
        assertVim("|ab\r\ncd\r\nxyz\r\n", "<C-v>jlyGp", "ab\r\ncd\r\nx|abyz\r\n cd\r\n")
    }

    // MARK: Escape with a pending key

    func test_escape_cancels_a_pending_key_and_keeps_the_selection() {
        for keys in ["vlr<Esc>x", "vl\"<Esc>x", "vlg<Esc>x", "vlf<Esc>x", "vlm<Esc>x",
                     "vli<Esc>x"] {
            assertVim("|abcdef", keys, "|cdef")
        }
    }

    func test_escape_after_a_count_or_a_register_leaves_visual_mode() {
        assertVim("|abcdef", "vl2<Esc>x", "a|cdef")
        assertVim("|abcdef", "vl\"a<Esc>x", "a|cdef")
        assertVim("|abcdef", "vl<Esc>x", "a|cdef")
    }

    // MARK: Text objects

    /// Vim 9.1's selection after each text object, typed once or again to extend it.
    private static let textObjectCases: [(before: String, keys: String, after: String)] = [
        ("foo b|ar baz qux", "viw", "foo [ba|r] baz qux"),
        ("foo b|ar baz qux", "viwiw", "foo [bar| ]baz qux"),
        ("foo b|ar baz qux", "viwiwiw", "foo [bar ba|z] qux"),
        ("foo b|ar baz qux", "vaw", "foo [bar| ]baz qux"),
        ("foo b|ar baz qux", "vawaw", "foo [bar baz| ]qux"),
        ("foo b|ar baz qux", "v2iw", "foo [bar| ]baz qux"),
        ("foo b|ar baz qux", "v3aw", "foo[ bar baz qu|x]"),
        ("foo bar b|az qux", "vhiw", "foo bar[| ba]z qux"),
        ("foo bar b|az qux", "vhaw", "foo [|bar ba]z qux"),
        ("foo bar b|az qux", "vhiwiw", "foo [|bar ba]z qux"),
        ("foo b|ar baz qux", "Viw", "foo [ba|r] baz qux"),
        ("foo b|ar baz qux", "vliw", "foo b[ar| ]baz qux"),
        ("foo bar b|az", "vaw", "foo bar[ ba|z]"),
        ("One. Tw|o three. Four five. Six.", "vis", "One. [Two three|.] Four five. Six."),
        ("One. Tw|o three. Four five. Six.", "visis", "One. [Two three.| ]Four five. Six."),
        ("One. Tw|o three. Four five. Six.", "vas", "One. [Two three.| ]Four five. Six."),
        ("One. Tw|o three. Four five. Six.", "vasas", "One. [Two three. Four five.| ]Six."),
        ("One. Two three. Fo|ur five. Six.", "vhis", "One. Two three. [|Fou]r five. Six."),
        ("One. Two three. Fo|ur five. Six.", "vhas", "One. Two three.[| Fou]r five. Six."),
        ("a\n|b\nc\n\nd\ne\n\nf", "vip", "[a\nb\n|c\n]\nd\ne\n\nf"),
        ("a\n|b\nc\n\nd\ne\n\nf", "vipip", "[a\nb\nc\n|\n]d\ne\n\nf"),
        ("a\n|b\nc\n\nd\ne\n\nf", "vap", "[a\nb\nc\n|\n]d\ne\n\nf"),
        ("a\n|b\nc\n\nd\ne\n\nf", "vapap", "[a\nb\nc\n\nd\ne\n|\n]f"),
        ("a\n|b\nc\n\nd\ne\n\nf", "v2ap", "[a\nb\nc\n\nd\ne\n|\n]f"),
        ("a\n|b\nc\n\nd\ne\n\nf", "Vip", "[a\nb\n|c\n]\nd\ne\n\nf"),
        ("a\nb\nc\n\nd\n|e\n\nf", "vkip", "a\nb\nc\n[|\nd\ne]\n\nf"),
        ("a\nb\nc\n\nd\n|e\n\nf", "vkkip", "[|a\nb\nc\n\nd\ne]\n\nf"),
        ("f(a, (b|c), d)", "vi(", "f(a, ([b|c]), d)"),
        ("f(a, (b|c), d)", "vi(i(", "f([a, (bc), |d])"),
        ("f(a, (b|c), d)", "va(", "f(a, [(bc|)], d)"),
        ("f(a, (b|c), d)", "va(a(", "f[(a, (bc), d|)]"),
        ("f(a, (b|c), d)", "v2i(", "f([a, (bc), |d])"),
        ("f(a, (|bc), d)", "vli(", "f([a, (bc), |d])"),
        ("f(a, (bc|), d)", "vhi(", "f(a, ([b|c]), d)"),
        ("f(a, (b|c), d)", "vib", "f(a, ([b|c]), d)"),
        ("f(a, (b|c), d)", "vi)a(", "f(a, [(bc|)], d)"),
        ("x = {\n  |a\n}", "vi{", "x = {\n[  a|\n]}"),
        ("x = {\n  |a\n}", "va{", "x = [{\n  a\n|}]"),
        ("a \"b|cd\" e \"f\" g", "vi\"", "a \"[bc|d]\" e \"f\" g"),
        ("a \"b|cd\" e \"f\" g", "vi\"i\"", "a [\"bcd|\"] e \"f\" g"),
        ("a \"b|cd\" e \"f\" g", "va\"", "a [\"bcd\"| ]e \"f\" g"),
        ("a \"b|cd\" e \"f\" g", "va\"a\"", "a [\"bcd\" e \"f\"| ]g"),
        ("a \"b|cd\" e \"f\" g", "v2i\"", "a [\"bcd|\"] e \"f\" g"),
        ("a \"b|cd\" e \"f\" g", "vla\"", "a [\"bcd\"| ]e \"f\" g"),
        ("a \"b|cd\" e \"f\" g", "vi\"a\"", "a [\"bcd\"| ]e \"f\" g"),
        ("a \"|bcd\" e \"f\" g", "vlli\"", "a [\"bcd|\"] e \"f\" g"),
        ("a \"bc|d\" e \"f\" g", "vhhi\"", "a [|\"bcd\"] e \"f\" g"),
    ]

    func test_text_objects_select_and_extend_the_visual_selection_as_vim_does() {
        for (before, keys, after) in Self.textObjectCases {
            let run = assertVim(before, keys, after)
            XCTAssertEqual(run.effects, [], keys)
        }
    }

    func test_a_paragraph_object_makes_the_selection_linewise_and_a_word_charwise() {
        XCTAssertEqual(runVim("a\n|b\nc\n\nd", "vip").window.mode, .visualLine)
        XCTAssertEqual(runVim("foo b|ar", "Viw").window.mode, .visual)
        XCTAssertEqual(runVim("f(|a)", "<C-v>i(").window.mode, .visual)
    }

    func test_a_text_object_that_finds_nothing_beeps_and_keeps_the_selection() {
        let empty = assertVim("x = (|) y", "vi(", "x = ([|)] y")
        XCTAssertEqual(empty.effects, [.failure])
        let outer = assertVim("x = {\n  |a\n}", "vi{i{", "x = {\n[  a|\n]}")
        XCTAssertEqual(outer.effects, [.failure])
    }

    // MARK: Putting over a selection

    func test_p_replaces_the_selection_and_puts_the_replaced_text_in_the_unnamed_register() {
        let run = assertVim("|abc def", "yiwwvlp", "abc ab|cf")
        XCTAssertEqual(run.register("\""), charwise("de"))
        XCTAssertEqual(run.register("-"), charwise("de"))
        assertVim("|abc def", "yiwwvl2p", "abc abcab|cf")
    }

    func test_P_replaces_the_selection_and_keeps_the_registers() {
        let run = assertVim("|abc def", "yiwwvlP", "abc ab|cf")
        XCTAssertEqual(run.register("\""), charwise("abc"))
        XCTAssertNil(run.register("-"))
        let lines = assertVim("|XY\nabcdef\n123", "yyjVjP", "XY\n|XY")
        XCTAssertEqual(lines.register("\""), linewise("XY\n"))
    }

    func test_putting_lines_over_a_charwise_selection_splits_the_line() {
        assertVim("|XY\nabcdef", "yyj$hvlp", "XY\nabcd\n|XY\n")
        assertVim("|XY\nab\ncdef", "yyjlvjp", "XY\na\n|XY\nef")
        assertVim("|XY\nabcdef\n123", "yyjv$p", "XY\n\n|XY\n123")
        assertVim("|XY\r\nab\r\ncdef", "yyjlvjp", "XY\r\na\r\n|XY\r\nef")
    }

    func test_putting_over_a_linewise_selection_replaces_the_lines() {
        let run = assertVim("|XY\nabcdef\n123", "yyjVp", "XY\n|XY\n123")
        XCTAssertEqual(run.register("\""), linewise("abcdef\n"))
        assertVim("|XY\nabcdef\n123", "ylj0Vp", "XY\n|X\n123")
        assertVim("|ab\ncd\nwxyz\n1234", "<C-v>jlyjj0lVp", "ab\ncd\n|ab\ncd\n1234")
        assertVim("ab\r\n|cd\r\nef", "yyjVp", "ab\r\ncd\r\n|cd")
    }

    func test_putting_characters_over_a_multiline_charwise_selection() {
        assertVim("|XY\nabcdef\n123", "ylj0lvjp", "XY\na|X3")
    }

    func test_putting_one_line_of_characters_over_a_block_repeats_it_on_every_line() {
        assertVim("|XY\nabcdef\n123456", "y$j0l<C-v>jlp", "XY\naX|Ydef\n1XY456")
        assertVim("|XY\nabcdef\n123", "y$j0l<C-v>jlp", "XY\naX|Ydef\n1XY")
    }

    func test_putting_lines_over_a_block_puts_them_below_or_above_it() {
        assertVim("|XY\nabcdef\n123456", "yyj0l<C-v>jlp", "XY\nadef\n1456\n|XY")
        assertVim("|XY\nabcdef\n123456", "yyj0l<C-v>jlP", "XY\n|XY\nadef\n1456")
    }

    func test_putting_a_block_over_a_selection_puts_it_where_the_selection_started() {
        assertVim("|ab\ncd\nwxyz\n1234", "<C-v>jlyjj0l<C-v>jlp", "ab\ncd\nw|abz\n1cd4")
        assertVim("|ab\ncd\nwxyz\n1234", "<C-v>jlyjj0l<C-v>lp", "ab\ncd\nw|abz\n1cd234")
        assertVim("|ab\ncd\nwxyz\n1234", "<C-v>jlyjj0lvlp", "ab\ncd\nw|abz\n1cd234")
    }

    func test_putting_several_lines_of_characters_over_a_block() {
        assertVim("|X\nY\nabcdef\n123456", "vjyjj0l<C-v>jlp", "X\nY\na|X\nYdef\n1456")
    }

    func test_gv_after_a_visual_put_selects_the_put_text() {
        assertVim("|abc def", "yiwwvlpgvd", "abc |f")
        assertVim("|abc def\nxy", "yiwwvjpgvd", "abc| ")
    }

    func test_a_visual_put_from_an_empty_register_deletes_the_selection_and_fails() {
        let run = assertVim("ab|cdef\n123", "vlp", "ab|ef\n123")
        XCTAssertEqual(run.effects, [.message("E353: Nothing in register \""), .failure])
        XCTAssertEqual(run.register("\""), charwise("cd"))
    }

    // MARK: Repeating

    func test_dot_repeats_a_charwise_change_over_the_same_number_of_characters() {
        assertVim("|abcdefgh\n12345678", "vlldj0.", "defgh\n|45678")
        assertVim("|abcdefgh\n12", "vlldj0.", "defgh\n|")
    }

    func test_dot_repeats_a_multiline_charwise_change_to_the_same_end_column() {
        assertVim("ab|cdef\n123456\nABCDEF\nuvwxyz", "vjld2j0.", "ab56\nABCDEF\n|yz")
        assertVim("a|bc\ndef\nghi\njkl", "v$dj0.", "adef\n|jkl")
    }

    func test_dot_repeats_a_linewise_change_over_the_same_number_of_lines() {
        assertVim("|a\nb\nc\nd\ne", "Vjd.", "|e")
        assertVim("|a\nb\nc\nd", "Vj2>jj.", "        a\n        b\n        |c\n        d")
    }

    func test_dot_repeats_a_block_change_over_the_same_block_size() {
        let text = "a|bcdef\n123456\nABCDEF\nuvwxyz"
        assertVim(text, "<C-v>jlx2j0.", "adef\n1456\n|CDEF\nwxyz")
        assertVim(text, "<C-v>jIX<Esc>2j0.", "aXbcdef\n1X23456\n|XABCDEF\nXuvwxyz")
        assertVim(text, "<C-v>j$d2j0.", "a\n1\n|\n")
    }

    func test_dot_leaves_the_last_selection_for_gv() {
        assertVim("|abcdefgh\n12345678", "vlldj0.gvd", "|gh\n45678")
    }

    func test_a_count_before_v_selects_that_many_characters_or_the_last_size_again() {
        assertVim("|abcdefgh\n12345678", "3vd", "|defgh\n12345678")
        assertVim("|abcdefgh\n12345678", "vlyj02vd", "abcdefgh\n|5678")
        assertVim("|a\nb\nc\nd", "2Vd", "|c\nd")
    }
}

func blockwise(_ text: String, width: Int) -> RegisterValue {
    RegisterValue(text: text, kind: .blockwise(width: width))
}
