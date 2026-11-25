import XCTest
@testable import NotepadCore

/// Expected text, cursors, registers and messages were taken from Vim 9.1 run headless with
/// Amber's option defaults (`-u NONE -N -X -c 'set ts=4 sw=4 et so=0'`), outside Ex mode.
final class ExRunnerTests: XCTestCase {
    private let numbered = "  l1\n|l2 x\nl3\nl4 x\nl5"
    private let five = "|  one\ntwo\n  three\nfour\nfive"

    private func messages(_ run: VimRun) -> [String] {
        run.effects.compactMap { effect in
            if case .message(let text) = effect { return text }
            return nil
        }
    }

    private func assertFails(_ before: String, _ keys: String, _ message: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        let run = runWithEx(before, keys)
        XCTAssertEqual(run.rendered, before, keys, file: file, line: line)
        XCTAssertEqual(Array(run.effects.suffix(2)), [.message(message), .failure], keys,
                       file: file, line: line)
    }

    // MARK: Ranges

    func test_a_line_number_goes_to_that_line_and_zero_to_the_first_non_blank_of_the_first() {
        assertEx(numbered, ":3<CR>", "  l1\nl2 x\n|l3\nl4 x\nl5")
        assertEx(numbered, ":0<CR>", "  |l1\nl2 x\nl3\nl4 x\nl5")
        assertEx(numbered, ":$<CR>", "  l1\nl2 x\nl3\nl4 x\n|l5")
    }

    func test_a_line_past_the_end_goes_to_the_last_line() {
        assertEx(numbered, ":9<CR>", "  l1\nl2 x\nl3\nl4 x\n|l5")
    }

    func test_offsets_count_from_the_current_line() {
        assertEx(numbered, ":.+2<CR>", "  l1\nl2 x\nl3\n|l4 x\nl5")
        assertEx(numbered, ":+<CR>", "  l1\nl2 x\n|l3\nl4 x\nl5")
        assertEx(numbered, ":++<CR>", "  l1\nl2 x\nl3\n|l4 x\nl5")
        assertEx(numbered, ":-<CR>", "  |l1\nl2 x\nl3\nl4 x\nl5")
    }

    func test_going_to_a_line_is_a_jump() {
        assertEx(numbered, ":4<CR>''", "  l1\n|l2 x\nl3\nl4 x\nl5")
    }

    func test_a_semicolon_moves_the_cursor_before_the_next_address() {
        assertEx(numbered, ":3;+1d<CR>", "  l1\nl2 x\n|l5")
        assertEx(numbered, ":3,+1d<CR>", "  l1\nl2 x\n|l4 x\nl5")
    }

    func test_a_search_address_starts_on_the_next_or_previous_line_and_wraps() {
        assertEx(numbered, ":/x/d<CR>", "  l1\nl2 x\nl3\n|l5")
        assertEx(numbered, ":?x?d<CR>", "  l1\nl2 x\nl3\n|l5")
        assertEx(numbered, ":/l2/d<CR>", "  l1\n|l3\nl4 x\nl5")
    }

    func test_consecutive_searches_start_from_the_line_the_last_one_found() {
        assertEx(numbered, ":/x//x/d<CR>", "  l1\n|l3\nl4 x\nl5")
        assertEx(numbered, ":2;/x/d<CR>", "  l1\n|l5")
        assertEx(numbered, ":/x/+1d<CR>", "  l1\nl2 x\nl3\n|l4 x")
    }

    func test_dollar_marks_and_extra_addresses() {
        assertEx(numbered, ":$-1,$d<CR>", "  l1\nl2 x\n|l3")
        assertEx(numbered, "ma:1<CR>:'ad<CR>", "  l1\n|l3\nl4 x\nl5")
        assertEx(numbered, ":1,2,3,4d<CR>", "  l1\nl2 x\n|l5")
    }

    func test_empty_addresses_are_the_current_line() {
        assertEx(numbered, ":,3d<CR>", "  l1\n|l4 x\nl5")
        assertEx(numbered, ":;d<CR>", "  l1\n|l3\nl4 x\nl5")
    }

    func test_line_zero_counts_as_line_one_for_a_delete() {
        assertEx(numbered, ":0d<CR>", "|l2 x\nl3\nl4 x\nl5")
        assertEx(numbered, ":0;/l2/d<CR>", "|l3\nl4 x\nl5")
    }

    func test_percent_deletes_every_line() {
        assertEx(numbered, ":%d<CR>", "|")
    }

    // MARK: Range errors

    func test_a_line_past_the_end_in_a_range_is_an_invalid_range() {
        assertFails(numbered, ":9d<CR>", "E16: Invalid range")
        assertFails(numbered, ":1,9d<CR>", "E16: Invalid range")
        assertFails(numbered, ":-9<CR>", "E16: Invalid range")
    }

    func test_a_backwards_range_is_rejected() {
        assertFails(numbered, ":3,2d<CR>", "E493: Backwards range given")
        assertFails(numbered, ":4;?x?d<CR>", "E493: Backwards range given")
    }

    func test_a_missing_pattern_or_mark_is_reported() {
        assertFails(numbered, ":/zz/d<CR>", "E486: Pattern not found: zz")
        assertFails(numbered, ":'zd<CR>", "E20: Mark not set")
        assertFails(numbered, ":'<lt>,'>d<CR>", "E20: Mark not set")
    }

    // MARK: Delete, yank, move, copy

    func test_delete_removes_the_lines_into_the_register_and_reports_more_than_two() {
        let run = assertEx(five, ":2,3d<CR>", "  one\n|four\nfive")
        XCTAssertEqual(run.register("\""), linewise("two\n  three\n"))
        XCTAssertEqual(run.register("1"), linewise("two\n  three\n"))
        XCTAssertEqual(messages(run), [])
        XCTAssertEqual(messages(runWithEx(five, ":1,3d<CR>")), ["3 fewer lines"])
    }

    func test_delete_with_a_register_and_count_counts_from_the_cursor_line() {
        let run = assertEx("  one\n|two\n  three\nfour\nfive", ":d a 2<CR>", "  one\n|four\nfive")
        XCTAssertEqual(run.register("a"), linewise("two\n  three\n"))
        assertEx("  one\n|two\n  three\nfour\nfive", ":d3<CR>", "  one\n|five")
    }

    func test_yank_keeps_the_text_and_the_cursor() {
        let run = assertEx("  one\ntwo\n  |three\nfour\nfive", ":1,2y<CR>",
                           "  one\ntwo\n  |three\nfour\nfive")
        XCTAssertEqual(run.register("\""), linewise("  one\ntwo\n"))
        XCTAssertEqual(run.register("0"), linewise("  one\ntwo\n"))
        XCTAssertEqual(messages(runWithEx(five, ":1,3y<CR>")), ["3 lines yanked"])
    }

    func test_move_puts_the_lines_below_the_target_with_the_cursor_on_the_last() {
        assertEx(five, ":1,2m$<CR>", "  three\nfour\nfive\n  one\n|two")
        assertEx(five, ":4m0<CR>", "|four\n  one\ntwo\n  three\nfive")
        XCTAssertEqual(messages(runWithEx(five, ":1,3m$<CR>")), ["3 lines moved"])
    }

    func test_moving_lines_into_themselves_is_rejected() {
        assertFails(five, ":1,3m2<CR>", "E134: Cannot move a range of lines into itself")
    }

    func test_copy_puts_copies_below_the_target_with_the_cursor_on_the_last() {
        assertEx(five, ":1,2t4<CR>", "  one\ntwo\n  three\nfour\n  one\n|two\nfive")
        assertEx("  one\ntwo\n|  three\nfour\nfive", ":co0<CR>",
                 "  |three\n  one\ntwo\n  three\nfour\nfive")
        XCTAssertEqual(messages(runWithEx(five, ":1,3t$<CR>")), ["3 more lines"])
    }

    // MARK: Join and shift

    func test_join_joins_the_range_or_the_line_and_the_next() {
        assertEx(five, ":1,3j<CR>", "  |one two three\nfour\nfive")
        assertEx(five, ":j!<CR>", "  |onetwo\n  three\nfour\nfive")
        assertEx("  one\n|two\n  three\nfour\nfive", ":j 3<CR>", "  one\n|two three four\nfive")
    }

    func test_a_join_count_adds_to_the_address_count_as_in_vim() {
        let lines = "|a\nb\nc\nd\ne"
        assertEx(lines, ":j<CR>", "|a b\nc\nd\ne")
        assertEx(lines, ":j 1<CR>", "|a b\nc\nd\ne")
        assertEx(lines, ":j 3<CR>", "|a b c\nd\ne")
        XCTAssertEqual(runWithEx(lines, ":2j 1<CR>").text, "a\nb\nc\nd\ne")
    }

    func test_join_of_one_given_line_does_nothing_and_on_the_last_line_fails() {
        let same = assertEx(five, ":2,2j<CR>", five)
        XCTAssertEqual(same.effects, [.openCommandLine(":"), .ex("2,2j")])
        let run = runWithEx("one\n|two", ":j<CR>")
        XCTAssertEqual(run.rendered, "one\n|two")
        XCTAssertEqual(Array(run.effects.suffix(2)), [.ex("j"), .failure])
    }

    func test_shift_moves_lines_by_shiftwidth_per_angle_bracket() {
        assertEx(five, ":2,3><CR>", "  one\n    two\n      |three\nfour\nfive")
        assertEx(five, ":>> 2<CR>", "          one\n        |two\n  three\nfour\nfive")
        let run = assertEx(five, ":1,3<lt><CR>", "one\ntwo\n|three\nfour\nfive")
        XCTAssertEqual(messages(run), ["3 lines <ed 1 time"])
    }

    // MARK: Put, undo, highlighting

    func test_put_adds_the_register_as_lines_below_or_above() {
        let lines = "|a\nb\nc\nd\ne"
        let run = assertEx(lines, ":1,3d<CR>:pu<CR>", "d\na\nb\n|c\ne")
        XCTAssertEqual(messages(run), ["3 fewer lines", "3 more lines"])
        assertEx(lines, ":1,3d<CR>:0pu<CR>", "a\nb\n|c\nd\ne")
        assertEx(lines, ":1,3d<CR>:pu!<CR>", "a\nb\n|c\nd\ne")
        assertEx("a\n|b\nc", ":1,2y a<CR>:$pu a<CR>", "a\nb\nc\na\n|b")
    }

    func test_put_puts_a_characterwise_register_as_a_line() {
        assertEx("|ab\ncd", "yl:pu<CR>", "ab\n|a\ncd")
    }

    func test_put_from_an_empty_register_fails() {
        assertFails("|a", ":pu x<CR>", "E353: Nothing in register x")
        assertFails("|a", ":pu<CR>", "E353: Nothing in register \"")
    }

    func test_undo_redo_and_noh_become_effects() {
        XCTAssertEqual(runWithEx("|a", ":u<CR>").effects.last, .undo(1))
        XCTAssertEqual(runWithEx("|a", ":red<CR>").effects.last, .redo(1))
        XCTAssertEqual(runWithEx("|a", ":noh<CR>").effects.last, .highlightSearch(nil))
    }

    // MARK: Substitute

    private let foo = "|a foo Foo foo\nfoo bar\n  x foo"

    func test_substitute_replaces_the_first_match_or_with_g_every_match() {
        assertEx(foo, ":s/foo/X/<CR>", "|a X Foo foo\nfoo bar\n  x foo")
        assertEx(foo, ":s/foo/X/g<CR>", "|a X Foo X\nfoo bar\n  x foo")
    }

    func test_substitute_flags_i_and_capital_i_override_ignorecase() {
        assertEx(foo, ":s/foo/X/gi<CR>", "|a X X X\nfoo bar\n  x foo")
        assertEx(foo, ":s/foo/X/gI<CR>", "|a X Foo X\nfoo bar\n  x foo",
                 session: session { $0.ignorecase = true })
    }

    func test_the_n_flag_counts_matches_without_changing_the_text() {
        let all = assertEx(foo, ":%s/foo/X/gn<CR>", foo)
        XCTAssertEqual(messages(all), ["4 matches on 3 lines"])
        XCTAssertEqual(messages(runWithEx(foo, ":%s/foo/X/n<CR>")), ["3 matches on 3 lines"])
        XCTAssertEqual(messages(runWithEx("|foo", ":s/o/x/n<CR>")), ["1 match on 1 line"])
    }

    func test_a_missing_match_fails_unless_the_e_flag_is_given() {
        assertFails(foo, ":s/zzz/X/<CR>", "E486: Pattern not found: zzz")
        let quiet = assertEx(foo, ":s/zzz/X/e<CR>", foo)
        XCTAssertFalse(quiet.effects.contains(.failure))
    }

    func test_a_count_substitutes_that_many_lines_from_the_last_line_of_the_range() {
        let run = assertEx(foo, ":s/foo/X/g 2<CR>", "a X Foo X\n|X bar\n  x foo")
        XCTAssertEqual(messages(run), ["3 substitutions on 2 lines"])
        assertEx(foo, ":2s/foo/X/ 2<CR>", "a foo Foo foo\nX bar\n  |x X")
    }

    func test_the_cursor_ends_on_the_last_substituted_line_and_the_substitute_is_a_jump() {
        let run = assertEx(foo, ":%s/foo/X/<CR>", "a X Foo foo\nX bar\n  |x X")
        XCTAssertEqual(messages(run), ["3 substitutions on 3 lines"])
        assertEx(foo, ":%s/foo/X/<CR>``", "|a X Foo foo\nX bar\n  x X")
    }

    func test_tilde_in_the_replacement_is_the_previous_replacement() {
        assertEx(foo, ":s/a/Q/<CR>:2s/bar/~~/<CR>", "Q foo Foo foo\n|foo QQ\n  x foo")
    }

    func test_case_markers_change_the_case_of_the_replacement() {
        assertEx(foo, ":s/\\(foo\\) \\(Foo\\)/\\U\\1\\E-\\l\\2/<CR>",
                 "|a FOO-foo foo\nfoo bar\n  x foo")
    }

    func test_case_markers_never_read_private_use_characters_from_the_text() {
        assertEx("|a\u{E000}b", ":s/.*/\\U&/<CR>", "|A\u{E000}B")
    }

    func test_an_empty_pattern_uses_the_last_search_and_ampersand_keeps_the_flags() {
        assertEx(foo, ":s/foo/X/g<CR>:2s//Y/&<CR>", "a X Foo X\n|Y bar\n  x foo")
    }

    func test_the_substitute_pattern_becomes_the_last_search() {
        let run = runWithEx("|foo bar", ":s/bar/X/<CR>")
        XCTAssertEqual(run.session.lastSearch?.pattern, "bar")
        XCTAssertEqual(run.register("/"), charwise("bar"))
        XCTAssertTrue(run.effects.contains(.highlightSearch("bar")))
    }

    func test_ampersand_and_s_alone_repeat_the_last_substitute_without_its_flags() {
        assertEx(foo, ":s/foo/X/<CR>:2&<CR>", "a X Foo foo\n|X bar\n  x foo")
        assertEx(foo, ":s/foo/X/g<CR>:%&&<CR>", "a X Foo X\nX bar\n  |x X")
        assertEx(foo, ":s/foo/X/g<CR>:3s<CR>", "a X Foo X\nfoo bar\n  |x X")
    }

    func test_repeating_without_a_previous_substitute_fails() {
        assertFails(foo, ":s<CR>", "E33: No previous substitute regular expression")
        assertFails(foo, ":&&<CR>", "E33: No previous substitute regular expression")
        assertFails(foo, ":s//x/<CR>", "E35: No previous regular expression")
    }

    func test_normal_ampersand_runs_colon_s_and_g_ampersand_runs_it_on_every_line() {
        let run = assertEx(foo, ":s/foo/X/g<CR>j&", "a X Foo X\n|X bar\n  x foo")
        XCTAssertEqual(run.register(":"), charwise("s"))
        let all = assertEx(foo, ":s/foo/X/<CR>g&", "a X Foo X\nX bar\n  |x X")
        XCTAssertEqual(messages(all), ["3 substitutions on 3 lines"])
        XCTAssertEqual(all.register(":"), charwise("s/foo/X/"))
    }

    func test_a_count_before_ampersand_is_a_range() {
        assertEx("|ab\nab\nab", ":s/a/x/<CR>2&", "xb\n|xb\nab")
    }

    func test_backslash_r_splits_the_line_with_the_documents_line_break() {
        assertEx(foo, ":s/ /\\r/g<CR>", "a\nfoo\nFoo\n|foo\nfoo bar\n  x foo")
        assertEx("|a foo\r\nb", ":s/ /\\r/<CR>", "a\r\n|foo\r\nb")
    }

    func test_empty_matches_follow_vims_rules_for_g() {
        assertEx("|xxaxbc", ":s/x*/-/g<CR>", "|-a-b-c")
        assertEx("|xxaxbc", ":s/a*/-/g<CR>", "|-x-x-x-b-c")
        assertEx("|xxaxbc", ":s/b\\|/-/g<CR>", "|-x-x-a-x-c")
        assertEx("|xxaxbc", ":s/$/!/g<CR>", "|xxaxbc!")
    }

    func test_a_match_inside_a_grapheme_cluster_is_not_a_match() {
        assertFails("|e\u{301} ab", ":s/e/x/<CR>", "E486: Pattern not found: e")
    }

    func test_a_substitute_over_every_line_is_one_edit() {
        let lines = Array(repeating: "foo foo", count: 10_000).joined(separator: "\n")
        let range = ExRange(addresses: [ExAddress(.line(1)), ExAddress(.last)])
        let substitute = ExSubstitute(pattern: "foo", replacement: "bar",
                                      flags: SubstituteFlags(global: true), count: nil)
        let result = ExRunner.run(.substitute(substitute), range: range,
                                  window: VimWindowState(), session: VimSession(),
                                  text: lines as NSString, clipboard: { nil })
        XCTAssertEqual(result.edits.count, 1)
        guard let edit = result.edits.first else { return }
        let after = (lines as NSString).replacingCharacters(in: edit.range,
                                                            with: edit.replacement)
        XCTAssertEqual(after, Array(repeating: "bar bar", count: 10_000)
            .joined(separator: "\n"))
    }

    /// One megabyte in 20,000 lines, half of them holding `foo`.
    private let megabyte = (0..<20_000).map { index in
        index % 2 == 0 ? "some text with foo and more words to pad the line \(index)"
            : "a plain line without the word, just padding it out \(index)"
    }.joined(separator: "\n") as NSString

    private func timed(_ command: ExTextCommand) -> (VimResult, TimeInterval) {
        let range = ExRange(addresses: [ExAddress(.line(1)), ExAddress(.last)])
        let start = Date()
        let result = ExRunner.run(command, range: range, window: VimWindowState(),
                                  session: VimSession(), text: megabyte, clipboard: { nil })
        return (result, Date().timeIntervalSince(start))
    }

    func test_a_substitute_over_one_megabyte_with_ten_thousand_matches_is_fast() {
        XCTAssertGreaterThan(megabyte.length, 1_000_000)
        let substitute = ExSubstitute(pattern: "foo", replacement: "bar",
                                      flags: SubstituteFlags(global: true), count: nil)
        let (result, elapsed) = timed(.substitute(substitute))
        XCTAssertEqual(result.edits.count, 1)
        XCTAssertTrue(result.effects.contains(.message("10000 substitutions on 10000 lines")))
        XCTAssertLessThan(elapsed, 0.25)
    }

    func test_a_global_delete_over_one_megabyte_with_ten_thousand_matches_is_fast() {
        let (result, elapsed) = timed(.global(pattern: "foo", matching: true, command: "d"))
        XCTAssertEqual(result.edits.count, 1)
        XCTAssertTrue(result.effects.contains(.message("10000 fewer lines")))
        XCTAssertLessThan(elapsed, 0.25)
    }

    // MARK: Global

    private let global = "|a1\nb2\na3\na4\nc5"

    func test_global_runs_the_command_on_every_matching_line() {
        let run = assertEx(global, ":g/a/d<CR>", "b2\n|c5")
        XCTAssertEqual(messages(run), ["3 fewer lines"])
        assertEx(global, ":g#a#d<CR>", "b2\n|c5")
        assertEx(global, ":2,4g/a/d<CR>", "a1\nb2\n|c5")
    }

    func test_vglobal_and_global_bang_run_on_the_lines_that_do_not_match() {
        assertEx(global, ":v/a/d<CR>", "a1\na3\n|a4")
        assertEx(global, ":g!/a/d<CR>", "a1\na3\n|a4")
    }

    func test_global_skips_marked_lines_that_an_earlier_command_deleted() {
        assertEx(global, ":g/a/j<CR>", "a1 b2\n|a3 a4\nc5")
    }

    func test_global_marks_lines_before_running_so_moves_reverse_the_text() {
        assertEx(global, ":g/^/m0<CR>", "|c5\na4\na3\nb2\na1")
    }

    func test_global_with_substitute_reports_the_total_once() {
        let run = assertEx(global, ":g/a/s/\\d/N/<CR>", "aN\nb2\naN\n|aN\nc5")
        XCTAssertEqual(messages(run), ["3 substitutions on 3 lines"])
        assertEx("|xxaxbc\nabc x\nx", ":g/x/s//Q/<CR>", "Qxaxbc\nabc Q\n|Q")
    }

    func test_global_without_a_match_says_so_without_failing() {
        let none = runWithEx(global, ":g/zzz/d<CR>")
        XCTAssertEqual(messages(none), ["Pattern not found: zzz"])
        XCTAssertFalse(none.effects.contains(.failure))
        XCTAssertEqual(messages(runWithEx(global, ":v/./d<CR>")),
                       ["Pattern found in every line: ."])
    }

    func test_global_without_a_command_lists_the_matching_lines() {
        let run = assertEx(global, ":g/a/<CR>", "a1\nb2\na3\n|a4\nc5")
        XCTAssertEqual(messages(run), ["a1\na3\na4"])
    }

    func test_global_stops_at_the_first_error() {
        let run = runWithEx("|x1\nx2\nx3", ":g/x/s/x/y/<CR>:g/y/m 99<CR>")
        XCTAssertEqual(run.text, "y1\ny2\ny3")
        XCTAssertEqual(Array(run.effects.suffix(2)), [.message("E16: Invalid range"), .failure])
    }

    func test_global_stops_at_an_early_error_before_later_lines_would_change() {
        let run = runWithEx("|y1\ny2\ny3", ":g/y/m-2<CR>")
        XCTAssertEqual(run.text, "y1\ny2\ny3")
        XCTAssertEqual(Array(run.effects.suffix(2)), [.message("E16: Invalid range"), .failure])
    }

    func test_global_without_a_previous_pattern_fails() {
        assertFails(global, ":g//d<CR>", "E35: No previous regular expression")
    }

    // MARK: Normal

    private let indented = "|  a1\na2\na3\na4\na5"

    func test_normal_with_a_range_runs_the_keys_from_the_start_of_each_line() {
        assertEx(indented, ":2,3norm $x<CR>", "  a1\na\n|a\na4\na5")
        assertEx(indented, ":%norm ix<CR>", "x  a1\nxa2\nxa3\nxa4\n|xa5")
    }

    func test_normal_with_a_range_counts_line_numbers_not_lines() {
        assertEx(indented, ":%norm dd<CR>", "|")
        assertEx(indented, ":%norm Ox<CR>", "x\nx\nx\nx\n|x\n  a1\na2\na3\na4\na5")
    }

    func test_normal_without_a_range_runs_at_the_cursor_and_ends_insert_mode() {
        assertEx("  a|1\na2", ":norm ix<CR>", "  a|x1\na2")
    }

    func test_trailing_blanks_are_part_of_the_keys_and_the_replacement() {
        assertEx("|a", ":norm A <CR>:norm Ax<CR>", "a |x")
        assertEx("|xa\nb\nxc", ":g/x/norm A <CR>", "xa \nb\nxc| ")
        assertEx("|a\nb", ":s/a/ <CR>", "| \nb")
    }

    func test_a_failure_ends_the_keys_for_that_line_only() {
        assertEx("|az\nb\ncz", ":g/./norm fzAx<CR>", "azx\nb\ncz|x")
        assertEx(indented, ":%norm fzAx<CR>", "  a1\na2\na3\na4\n|a5")
    }

    func test_global_with_normal_skips_lines_deleted_by_earlier_runs() {
        assertEx(global, ":g/a/norm dd<CR>", "b2\n|c5")
        assertEx(indented, ":g/a[24]/norm jdd<CR>", "  a1\na2\n|a4")
        assertEx(indented, ":g/a/norm Jx<CR>", "  a1a2\na3a4\n|a5")
    }

    func test_global_with_normal_follows_lines_moved_by_inserts_above_them() {
        assertEx(indented, ":g/a/norm Ox<CR>", "x\n  a1\nx\na2\nx\na3\nx\na4\n|x\na5")
        assertEx(global, ":g!/a/norm Ax<CR>", "a1\nb2x\na3\na4\nc5|x")
    }

    func test_line_marks_follow_edits_and_drop_lines_deleted_or_joined_to_the_one_above() {
        var text = "ab\ncd\nef\ngh" as NSString
        var marks = ExLineMarks(lines: [1, 2, 3], in: VimBuffer(text))
        let edits = [
            TextEdit(range: NSRange(location: 0, length: 1), replacement: ""),
            TextEdit(range: NSRange(location: 4, length: 1), replacement: ""),
            TextEdit(range: NSRange(location: 2, length: 0), replacement: "x\n"),
            TextEdit(range: NSRange(location: 4, length: 5), replacement: ""),
        ]
        for edit in edits {
            marks.update(after: edit, in: text)
            text = text.replacingCharacters(in: edit.range, with: edit.replacement) as NSString
        }
        XCTAssertEqual(text, "b\nx\ngh")
        XCTAssertEqual(marks.next(), 4)
        XCTAssertNil(marks.next())
    }

    func test_normal_returns_its_keys_and_lines_for_the_adapter() {
        let text = "a1\nb2\na3" as NSString
        let range = ExRange(addresses: [ExAddress(.line(2)), ExAddress(.last)])
        let numbers = ExRunner.run(.normal(keys: "Ax\u{1B}"), range: range,
                                   window: VimWindowState(), session: VimSession(),
                                   text: text, clipboard: { nil })
        let keys = try? VimKey.parse("Ax<Esc>")
        XCTAssertEqual(numbers.effects, [.replayLines(LineReplay(keys: keys ?? [],
                                                                 lines: .numbers(1...2)))])
        let marked = ExRunner.run(.global(pattern: "a", matching: true, command: "norm Ax"),
                                  range: nil, window: VimWindowState(), session: VimSession(),
                                  text: text, clipboard: { nil })
        XCTAssertEqual(marked.effects.last, .replayLines(LineReplay(
            keys: Array((keys ?? []).dropLast()), lines: .marked([0, 2]))))
    }

    // MARK: Sort

    private let unsorted = "b10\na2\nB3\na2\nx\nc-1\n|A2"

    func test_sort_orders_lines_by_their_bytes_and_bang_reverses() {
        assertEx(unsorted, ":sort<CR>", "|A2\nB3\na2\na2\nb10\nc-1\nx")
        assertEx(unsorted, ":sort!<CR>", "|x\nc-1\nb10\na2\na2\nB3\nA2")
    }

    func test_sort_i_ignores_case_and_keeps_equal_lines_in_order() {
        assertEx("a2\nB3\n|A2\na2", ":sort i<CR>", "|a2\nA2\na2\nB3")
    }

    func test_sort_n_orders_by_the_first_number_with_numberless_lines_first() {
        assertEx(unsorted, ":sort n<CR>", "|x\nc-1\na2\na2\nA2\nB3\nb10")
    }

    func test_sort_bang_reverses_the_whole_order_including_ties() {
        assertEx("|a2\nA2\nb\nx 1\na2\ny\nx 01\n-3\na-2\né\nZ", ":sort! n<CR>",
                 "|a2\nA2\na2\nx 01\nx 1\na-2\n-3\nZ\né\ny\nb")
    }

    func test_sort_u_keeps_the_first_of_identical_lines() {
        assertEx(unsorted, ":sort u<CR>", "|A2\nB3\na2\nb10\nc-1\nx")
        assertEx("|a2\nA2\nb\na2", ":sort iu<CR>", "|a2\nb")
    }

    func test_sort_with_a_pattern_sorts_on_what_follows_the_match_or_with_r_the_match() {
        assertEx(unsorted, ":sort /./<CR>", "|x\nc-1\nb10\na2\na2\nA2\nB3")
        assertEx(unsorted, ":sort /./ r<CR>", "|A2\nB3\na2\na2\nb10\nc-1\nx")
        assertEx(unsorted, ":sort r /\\d/<CR>", "|x\nb10\nc-1\na2\na2\nA2\nB3")
    }

    func test_sort_with_a_range_leaves_the_cursor_on_its_first_line() {
        assertEx(unsorted, ":2,5sort<CR>", "b10\n|B3\na2\na2\nx\nc-1\nA2")
    }

    // MARK: Retab

    private let tabbed = "|\tab\tc\n        x  \ty\n  \t z\na    b"

    func test_retab_with_expandtab_turns_every_tab_into_spaces() {
        assertEx(tabbed, ":retab<CR>", "|    ab  c\n        x   y\n     z\na    b")
    }

    func test_retab_with_noexpandtab_retabs_runs_holding_a_tab() {
        let tabs = session { $0.expandtab = false }
        assertEx(tabbed, ":retab<CR>", "|\tab\tc\n        x\ty\n\t z\na    b", session: tabs)
    }

    func test_retab_bang_with_noexpandtab_also_retabs_runs_of_spaces() {
        let tabs = session { $0.expandtab = false }
        assertEx(tabbed, ":retab!<CR>", "|\tab\tc\n\t\tx\ty\n\t z\na\t b", session: tabs)
        assertEx(tabbed, ":2,3retab!<CR>", "|\tab\tc\n\t\tx\ty\n\t z\na    b", session: tabs)
    }

    // MARK: The command line from Visual mode and with a count

    private let column = "|a1\na2\na3\na4\na5"

    func test_colon_in_visual_mode_opens_the_command_line_with_the_visual_range() {
        let run = runVim(column, "Vj:")
        XCTAssertEqual(run.effects.last, .openCommandLine(":", prefill: "'<,'>"))
        XCTAssertEqual(run.window.mode, .normal)
        XCTAssertEqual(run.window.lastVisual?.cursor, Mark(line: 1, column: 0))
    }

    func test_a_command_from_visual_mode_runs_on_the_selected_lines() {
        let run = assertEx(column, "Vj:s/a/b/<CR>", "b1\n|b2\na3\na4\na5")
        XCTAssertEqual(run.register(":"), charwise("'<,'>s/a/b/"))
    }

    func test_at_colon_in_visual_mode_repeats_the_command_on_the_new_selection() {
        assertEx(column, "Vj:s/a/b/<CR>jjVj@:", "b1\nb2\na3\nb4\n|b5")
    }

    func test_a_count_before_colon_becomes_a_range_of_that_many_lines() {
        let run = runVim(column, "3:")
        XCTAssertEqual(run.effects.last, .openCommandLine(":", prefill: ".,.+2"))
        let typed = assertEx(column, "2:s/a/c/<CR>", "c1\n|c2\na3\na4\na5")
        XCTAssertEqual(typed.register(":"), charwise(".,.+1s/a/c/"))
    }

    func test_a_command_line_becomes_the_colon_register() {
        XCTAssertEqual(runWithEx(column, ":s/a/b/<CR>").register(":"), charwise("s/a/b/"))
    }
}
