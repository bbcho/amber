import XCTest
@testable import NotepadCore

final class VimOptionsTests: XCTestCase {
    func test_defaults_are_ambers() {
        let o = VimOptions()
        XCTAssertEqual([o.tabstop, o.shiftwidth, o.softtabstop, o.textwidth, o.scrolloff,
                        o.timeoutlen], [4, 4, 0, 0, 0, 1000])
        XCTAssertEqual([o.expandtab, o.hlsearch, o.incsearch, o.wrapscan, o.autoread, o.wrap,
                        o.showcmd], Array(repeating: true, count: 7))
        XCTAssertEqual([o.autoindent, o.ignorecase, o.smartcase, o.number, o.relativenumber,
                        o.list, o.cursorline], Array(repeating: false, count: 7))
        XCTAssertEqual(o.nrformats, "bin,hex")
        XCTAssertEqual(o.clipboard, "")
        XCTAssertEqual(o.changedSummary, "")
    }

    func test_number_options_accept_equals_and_colon_and_short_names() throws {
        var o = VimOptions()
        XCTAssertNil(try o.set("ts=2"))
        XCTAssertEqual(o.tabstop, 2)
        try o.set("shiftwidth:3 so=5")
        XCTAssertEqual([o.shiftwidth, o.scrolloff], [3, 5])
    }

    func test_number_options_support_add_subtract_and_multiply() throws {
        var o = VimOptions()
        try o.set("ts+=2")
        XCTAssertEqual(o.tabstop, 6)
        try o.set("ts-=4")
        XCTAssertEqual(o.tabstop, 2)
        try o.set("ts^=3")
        XCTAssertEqual(o.tabstop, 6)
    }

    func test_boolean_options_set_clear_invert_and_reset() throws {
        var o = VimOptions()
        try o.set("ic")
        XCTAssertTrue(o.ignorecase)
        try o.set("noic")
        XCTAssertFalse(o.ignorecase)
        try o.set("ic!")
        XCTAssertTrue(o.ignorecase)
        try o.set("invic")
        XCTAssertFalse(o.ignorecase)
        try o.set("list noet")
        XCTAssertTrue(o.list)
        XCTAssertFalse(o.expandtab)
        try o.set("list& et&")
        XCTAssertFalse(o.list)
        XCTAssertTrue(o.expandtab)
    }

    func test_number_options_reset_to_the_default() throws {
        var o = VimOptions()
        try o.set("ts=8")
        try o.set("ts&")
        XCTAssertEqual(o.tabstop, 4)
    }

    func test_queries_return_vims_text_and_change_nothing() throws {
        var o = VimOptions()
        XCTAssertEqual(try o.set("ts?"), "  tabstop=4")
        XCTAssertEqual(try o.set("ts"), "  tabstop=4")
        XCTAssertEqual(try o.set("ic?"), "noignorecase")
        XCTAssertEqual(try o.set("et?"), "  expandtab")
        XCTAssertEqual(try o.set("cb?"), "  clipboard=")
        XCTAssertEqual(try o.set("ts? ic?"), "  tabstop=4\nnoignorecase")
        XCTAssertEqual(o, VimOptions())
    }

    func test_clipboard_accepts_the_two_vim_values_and_edits_the_list() throws {
        var o = VimOptions()
        try o.set("clipboard=unnamed")
        XCTAssertEqual(o.clipboard, "unnamed")
        try o.set("cb+=unnamedplus")
        XCTAssertEqual(o.clipboard, "unnamed,unnamedplus")
        try o.set("cb+=unnamed")
        XCTAssertEqual(o.clipboard, "unnamed,unnamedplus")
        try o.set("cb-=unnamed")
        XCTAssertEqual(o.clipboard, "unnamedplus")
        try o.set("cb^=unnamed")
        XCTAssertEqual(o.clipboard, "unnamed,unnamedplus")
        try o.set("cb=")
        XCTAssertEqual(o.clipboard, "")
        try o.set("cb=unnamed cb&")
        XCTAssertEqual(o.clipboard, "")
    }

    func test_an_unknown_option_is_E518() {
        var o = VimOptions()
        XCTAssertThrowsError(try o.set("foo")) {
            XCTAssertEqual($0 as? VimError, VimError("E518: Unknown option: foo"))
        }
        XCTAssertThrowsError(try o.set("nofoo=1")) {
            XCTAssertEqual($0 as? VimError, VimError("E518: Unknown option: nofoo"))
        }
    }

    func test_a_non_number_after_equals_is_E521() {
        var o = VimOptions()
        XCTAssertThrowsError(try o.set("ts=x")) {
            XCTAssertEqual($0 as? VimError, VimError("E521: Number required after =: ts=x"))
        }
        XCTAssertThrowsError(try o.set("ts+=x")) {
            XCTAssertEqual($0 as? VimError, VimError("E521: Number required after =: ts+=x"))
        }
        XCTAssertEqual(o.tabstop, 4)
    }

    func test_invalid_forms_are_E474() {
        var o = VimOptions()
        for argument in ["nots", "invts", "ic=1", "cb=bogus", "nf=bogus", "nocb"] {
            XCTAssertThrowsError(try o.set(argument), argument) {
                XCTAssertEqual($0 as? VimError, VimError("E474: Invalid argument: \(argument)"))
            }
        }
        XCTAssertEqual(o, VimOptions())
    }

    func test_out_of_range_numbers_are_E487() {
        var o = VimOptions()
        XCTAssertThrowsError(try o.set("ts=0")) {
            XCTAssertEqual($0 as? VimError, VimError("E487: Argument must be positive: ts=0"))
        }
        XCTAssertThrowsError(try o.set("sw=-1"))
        XCTAssertNoThrow(try o.set("sw=0"))
    }

    func test_toggling_a_number_option_is_E488() {
        var o = VimOptions()
        XCTAssertThrowsError(try o.set("ts!")) {
            XCTAssertEqual($0 as? VimError, VimError("E488: Trailing characters: ts!"))
        }
    }

    func test_arguments_before_an_error_stay_applied() {
        var o = VimOptions()
        XCTAssertThrowsError(try o.set("ic ts=x list"))
        XCTAssertTrue(o.ignorecase)
        XCTAssertFalse(o.list)
    }

    func test_a_bare_set_lists_only_changed_options() throws {
        var o = VimOptions()
        try o.set("ts=2 noet ic list")
        XCTAssertEqual(o.changedSummary, "tabstop=2 noexpandtab ignorecase list")
    }

    func test_rc_applies_set_lines_and_skips_comments_and_blanks() {
        let result = VimOptions.load(rc: "\" my settings\n\nset ts=2\n:set noet ic\n  set so=3  \n")
        XCTAssertEqual(result.errors, [])
        XCTAssertEqual([result.options.tabstop, result.options.scrolloff], [2, 3])
        XCTAssertFalse(result.options.expandtab)
        XCTAssertTrue(result.options.ignorecase)
    }

    func test_rc_reports_a_bad_middle_line_and_still_applies_the_others() {
        let result = VimOptions.load(rc: "set ts=2\nset nosuch\nset ic\n")
        XCTAssertEqual(result.errors, ["line 2: E518: Unknown option: nosuch"])
        XCTAssertEqual(result.options.tabstop, 2)
        XCTAssertTrue(result.options.ignorecase)
    }

    func test_rc_skips_a_line_whose_later_argument_fails_entirely() {
        let result = VimOptions.load(rc: "set ic ts=x\r\nmap a b\r\nset list")
        XCTAssertEqual(result.errors, ["line 1: E521: Number required after =: ts=x",
                                       "line 2: E492: Not an editor command: map a b"])
        XCTAssertFalse(result.options.ignorecase)
        XCTAssertTrue(result.options.list)
    }
}
