import XCTest
@testable import NotepadCore

/// Parsing ex command lines. Error wording was taken from Vim 9.1 (`v:exception`, without
/// the command Vim appends after some messages).
final class ExCommandTests: XCTestCase {
    private func parse(_ line: String) throws -> ExCommand { try ExCommand.parse(line) }

    private func assertError(_ line: String, _ message: String,
                             file: StaticString = #filePath, line number: UInt = #line) {
        XCTAssertThrowsError(try parse(line), line, file: file, line: number) { error in
            XCTAssertEqual(error.localizedDescription, message, line, file: file, line: number)
        }
    }

    func test_set_and_its_abbreviation_hand_their_arguments_to_the_options() throws {
        XCTAssertEqual(try parse("set ts=2 noic"), .set("ts=2 noic"))
        XCTAssertEqual(try parse(":se"), .set(""))
    }

    func test_a_range_alone_goes_to_its_line() throws {
        let range = ExRange(addresses: [ExAddress(.line(3))])
        XCTAssertEqual(try parse("3"), .text(range: range, command: .goTo))
    }

    func test_percent_is_the_first_through_the_last_line() throws {
        let range = ExRange(addresses: [ExAddress(.line(1)), ExAddress(.last)])
        XCTAssertEqual(try parse("%d"), .text(range: range,
                                              command: .delete(register: nil, count: nil)))
    }

    func test_addresses_keep_offsets_marks_searches_and_semicolons() throws {
        let range = ExRange(addresses: [
            ExAddress(.mark("a"), offset: 2, movesCursor: true),
            ExAddress(.search([ExSearch(pattern: "x", forward: true),
                               ExSearch(pattern: "y?", forward: false)]), offset: -1),
            ExAddress(.current, offset: 2),
        ])
        XCTAssertEqual(try parse("'a+2;/x/?y\\??-,++y"),
                       .text(range: range, command: .yank(register: nil, count: nil)))
    }

    func test_an_empty_address_before_a_comma_is_the_current_line() throws {
        let range = ExRange(addresses: [ExAddress(.current), ExAddress(.line(3))])
        XCTAssertEqual(try parse(",3d"), .text(range: range,
                                               command: .delete(register: nil, count: nil)))
    }

    func test_delete_and_yank_take_a_register_and_a_count() throws {
        XCTAssertEqual(try parse("d a 2"), .text(range: nil, command: .delete(register: "a",
                                                                             count: 2)))
        XCTAssertEqual(try parse("y3"), .text(range: nil, command: .yank(register: nil,
                                                                          count: 3)))
        XCTAssertEqual(try parse("delete x"), .text(range: nil, command: .delete(register: "x",
                                                                                count: nil)))
    }

    func test_substitute_reads_its_pattern_replacement_flags_and_count() throws {
        var flags = SubstituteFlags()
        flags.global = true
        flags.ignoreCase = true
        let expected = ExSubstitute(pattern: "a\\/b", replacement: "c\\/", flags: flags, count: 3)
        XCTAssertEqual(try parse("s/a\\/b/c\\//gi 3"),
                       .text(range: nil, command: .substitute(expected)))
    }

    func test_substitute_without_a_pattern_repeats_the_last_one() throws {
        var keep = SubstituteFlags()
        keep.keepFlags = true
        XCTAssertEqual(try parse("&&"), .text(range: nil, command: .substitute(
            ExSubstitute(pattern: nil, replacement: nil, flags: keep, count: nil))))
        XCTAssertEqual(try parse("s 2"), .text(range: nil, command: .substitute(
            ExSubstitute(pattern: nil, replacement: nil, flags: SubstituteFlags(), count: 2))))
    }

    func test_each_g_flag_toggles_global_replacement() throws {
        guard case .text(_, .substitute(let substitute)) = try parse("s/x/y/gg") else {
            return XCTFail("not a substitute")
        }
        XCTAssertFalse(substitute.flags.global)
    }

    func test_global_and_vglobal_keep_their_command_text() throws {
        XCTAssertEqual(try parse("g/a/s//b/"), .text(range: nil, command: .global(
            pattern: "a", matching: true, command: "s//b/")))
        XCTAssertEqual(try parse("g!#a#norm x"), .text(range: nil, command: .global(
            pattern: "a", matching: false, command: "norm x")))
        XCTAssertEqual(try parse("v/a"), .text(range: nil, command: .global(
            pattern: "a", matching: false, command: "")))
    }

    func test_sort_reads_its_options_and_pattern() throws {
        let sort = ExSort(reverse: true, ignoreCase: true, numeric: true, unique: true,
                          onMatch: true, pattern: "\\d")
        XCTAssertEqual(try parse("sor! i n u r /\\d/"), .text(range: nil, command: .sort(sort)))
    }

    func test_the_other_text_commands_parse_by_their_short_and_long_names() throws {
        let examples: [(String, ExTextCommand)] = [
            ("m0", .move(to: ExAddress(.line(0)))),
            ("move $", .move(to: ExAddress(.last))),
            ("t.", .copy(to: ExAddress(.current))),
            ("co 'a", .copy(to: ExAddress(.mark("a")))),
            ("j!", .join(spaces: false, count: nil)),
            ("join 3", .join(spaces: true, count: 3)),
            (">> 2", .shift(left: false, amount: 2, count: 2)),
            ("<", .shift(left: true, amount: 1, count: nil)),
            ("norm! ix", .normal(keys: "ix")),
            ("normal  dd", .normal(keys: "dd")),
            ("retab!", .retab(bang: true)),
            ("ret", .retab(bang: false)),
            ("noh", .noHighlight),
            ("nohlsearch", .noHighlight),
            ("u", .undo),
            ("red", .redo),
            ("pu! a", .put(register: "a", above: true)),
            ("put", .put(register: nil, above: false)),
        ]
        for (line, command) in examples {
            XCTAssertEqual(try parse(line), .text(range: nil, command: command), line)
        }
    }

    // MARK: Errors

    func test_an_unknown_command_reports_the_whole_line() {
        assertError("foo", "E492: Not an editor command: foo")
        assertError("1,2foo bar", "E492: Not an editor command: 1,2foo bar")
    }

    func test_trailing_text_after_a_command_is_rejected() {
        assertError("y 3 x", "E488: Trailing characters: x")
        assertError("s/x/y/ 2 3", "E488: Trailing characters: 3")
        assertError("noh x", "E488: Trailing characters: x")
    }

    func test_a_count_must_be_positive() {
        assertError("d 0", "E939: Positive count required")
        assertError("s/x/y/ 0", "E939: Positive count required")
    }

    func test_commands_that_take_no_range_or_bang_say_so() {
        assertError("2,3noh", "E481: No range allowed")
        assertError("1w", "E481: No range allowed")
        assertError("d!", "E477: No ! allowed")
    }

    func test_normal_needs_keys_and_global_needs_a_pattern() {
        assertError("%norm", "E471: Argument required")
        assertError("g", "E148: Regular expression missing from :global")
    }

    func test_sort_rejects_unknown_options_and_an_unclosed_pattern() {
        assertError("sort q", "E475: Invalid argument: q")
        assertError("sort n!", "E654: Missing delimiter after search pattern: ")
        assertError("sort /x", "E654: Missing delimiter after search pattern: x")
    }

    func test_retab_rejects_a_new_tabstop() {
        assertError("retab 8", "E488: Trailing characters: 8")
        assertError("retab x", "E475: Invalid argument: x")
    }

    func test_move_and_copy_need_a_target_address() {
        assertError("m", "E16: Invalid range")
        assertError("t 0!", "E488: Trailing characters: !")
    }
}
