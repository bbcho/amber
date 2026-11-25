import XCTest
@testable import NotepadCore

/// Expected cursors, registers and messages were taken from Vim 9.1 (`vim -u NONE -N` with
/// `ts=4 sw=4 et so=0 hlsearch incsearch wrapscan`).
final class VimSearchTests: XCTestCase {
    private let text = "foo bar\nbaz foo\nFoo end"
    private var noWrap: VimSession { session { $0.wrapscan = false } }
    private var ignoreCase: VimSession { session { $0.ignorecase = true } }
    private var smartCase: VimSession {
        session {
            $0.ignorecase = true
            $0.smartcase = true
        }
    }

    private func start() -> String { "|" + text }

    // MARK: / ? n N

    func test_slash_opens_the_prompt_and_return_goes_to_the_next_match() {
        let opened = runVim(start(), "/")
        XCTAssertEqual(opened.effects, [.openCommandLine("/")])
        let run = assertVim(start(), "/foo<CR>", "foo bar\nbaz |foo\nFoo end")
        XCTAssertEqual(run.session.lastSearch, LastSearch(pattern: "foo", forward: true))
        XCTAssertEqual(run.register("/"), charwise("foo"))
    }

    func test_n_repeats_the_search_and_wraps_with_a_message() {
        let run = assertVim(start(), "/foo<CR>n", "|foo bar\nbaz foo\nFoo end")
        XCTAssertTrue(run.effects.contains(.message("search hit BOTTOM, continuing at TOP")))
        assertVim(start(), "/foo<CR>nn", "foo bar\nbaz |foo\nFoo end")
    }

    func test_capital_n_searches_the_other_way_and_wraps_to_the_bottom() {
        let run = assertVim(start(), "/foo<CR>N", "|foo bar\nbaz foo\nFoo end")
        XCTAssertFalse(run.effects.contains(.message("search hit TOP, continuing at BOTTOM")))
        let none = assertVim(start(), "N", start())
        XCTAssertEqual(none.effects, [.message("E35: No previous regular expression"),
                                         .failure])
        let back = assertVim(start(), "?foo<CR>", "foo bar\nbaz |foo\nFoo end")
        XCTAssertTrue(back.effects.contains(.message("search hit TOP, continuing at BOTTOM")))
        XCTAssertEqual(back.session.lastSearch, LastSearch(pattern: "foo", forward: false))
    }

    func test_a_count_finds_a_later_match() {
        assertVim(start(), "3/foo<CR>", "foo bar\nbaz |foo\nFoo end")
        assertVim(start(), "/foo<CR>2n", "foo bar\nbaz |foo\nFoo end")
    }

    func test_a_forward_search_skips_a_match_at_the_cursor_and_continues_after_it() {
        assertVim("|aaaa", "/aa<CR>", "aa|aa")
        assertVim("|foo bar", "/o<CR>", "f|oo bar")
    }

    func test_an_end_of_line_match_counts_as_the_last_character() {
        assertVim("|foo bar\nbaz foo", "/$<CR>", "foo ba|r\nbaz foo")
        assertVim("foo ba|r\nbaz foo", "/$<CR>", "foo bar\nbaz fo|o")
    }

    func test_without_wrapscan_a_search_stops_at_the_end_with_e384_or_e385() {
        let run = assertVim(start(), "/foo<CR>nn", "foo bar\nbaz |foo\nFoo end",
                            session: noWrap)
        XCTAssertEqual(Array(run.effects.suffix(2)),
                       [.message("E385: Search hit BOTTOM without match for: foo"), .failure])
        assertVim("foo bar\nbaz foo\nFoo en|d", "?foo<CR>", "foo bar\nbaz |foo\nFoo end",
                  session: noWrap)
        let up = runVim(start(), "?zzz<CR>", session: noWrap)
        XCTAssertEqual(Array(up.effects.suffix(2)),
                       [.message("E384: Search hit TOP without match for: zzz"), .failure])
    }

    func test_a_pattern_found_nowhere_fails_with_e486_and_is_still_remembered() {
        let run = assertVim(start(), "/zzz<CR>", start())
        XCTAssertEqual(Array(run.effects.suffix(2)),
                       [.message("E486: Pattern not found: zzz"), .failure])
        XCTAssertEqual(run.register("/"), charwise("zzz"))
    }

    func test_an_invalid_pattern_fails_with_its_error() {
        let run = assertVim(start(), "/\\(<CR>", start())
        XCTAssertEqual(Array(run.effects.suffix(2)), [.message("E54: Unmatched \\("), .failure])
    }

    func test_escape_and_backspace_on_an_empty_prompt_cancel_the_search() {
        let escaped = assertVim(start(), "/fo<Esc>", start())
        XCTAssertEqual(escaped.effects, [.openCommandLine("/")])
        XCTAssertEqual(escaped.window.pendingKeys, [])
        let backspaced = runVim(start(), "/<BS>")
        XCTAssertEqual(backspaced.window.pendingKeys, [])
    }

    func test_backspace_in_the_prompt_deletes_the_last_character() {
        assertVim(start(), "/fo<BS>oo<CR>", "foo bar\nbaz |foo\nFoo end")
    }

    func test_an_empty_pattern_repeats_the_last_one_with_its_offset() {
        assertVim("|foo bar\nbaz foo", "/bar<CR>gg0//e<CR>", "foo ba|r\nbaz foo")
        assertVim("|foo bar\nbaz foo", "/bar/e<CR>gg0/<CR>", "foo ba|r\nbaz foo")
    }

    // MARK: Options

    func test_ignorecase_matches_either_case() {
        assertVim(start(), "/foo<CR>n", "foo bar\nbaz foo\n|Foo end", session: ignoreCase)
    }

    func test_smartcase_matches_case_when_the_pattern_has_a_capital() {
        assertVim(start(), "/Foo<CR>", "foo bar\nbaz foo\n|Foo end", session: smartCase)
        assertVim(start(), "/foo<CR>nn", start(), session: smartCase)
    }

    func test_hlsearch_highlights_the_pattern_after_each_search() {
        let run = runVim(start(), "/foo<CR>n")
        XCTAssertEqual(run.effects.filter { $0 == .highlightSearch("foo") }.count, 2)
        let off = runVim(start(), "/foo<CR>n", session: session { $0.hlsearch = false })
        XCTAssertFalse(off.effects.contains(.highlightSearch("foo")))
    }

    // MARK: * # g* g#

    func test_star_and_hash_search_for_the_whole_word_under_the_cursor() {
        let star = assertVim(start(), "*", "foo bar\nbaz |foo\nFoo end")
        XCTAssertEqual(star.register("/"), charwise("\\<foo\\>"))
        XCTAssertEqual(star.session.lastSearch?.forward, true)
        let hash = assertVim(start(), "#", "foo bar\nbaz |foo\nFoo end")
        XCTAssertEqual(hash.session.lastSearch?.forward, false)
        assertVim("fo|o bar foobar\nfoo", "#", "foo bar foobar\n|foo")
    }

    func test_g_star_and_g_hash_search_for_the_word_inside_others() {
        let run = assertVim("|foo bar foobar\nfoo", "g*", "foo bar |foobar\nfoo")
        XCTAssertEqual(run.register("/"), charwise("foo"))
        assertVim("a|.b a.b", "g*", "a.b a.|b")
        assertVim("|foo bar foobar\nfoo", "g#", "foo bar foobar\n|foo")
    }

    func test_star_takes_the_first_keyword_after_the_cursor_or_else_the_symbols() {
        assertVim("a |== b ==\nx", "*", "a == |b ==\nx")
        assertVim("a| b a\nx", "*", "a |b a\nx")
        let symbols = assertVim("x |== ==", "g*", "x == |==")
        XCTAssertEqual(symbols.register("/"), charwise("=="))
    }

    func test_star_escapes_magic_characters() {
        let run = assertVim("|a.* a.*", "g*", "a.* |a.*")
        XCTAssertEqual(run.register("/"), charwise("a"))
        let symbols = assertVim("a |.* x .*", "*", "a .* |x .*")
        XCTAssertEqual(symbols.register("/"), charwise("\\<x\\>"))
        let only = assertVim("|.* x\n.*", "#", ".* |x\n.*")
        XCTAssertEqual(only.register("/"), charwise("\\<x\\>"))
        let dots = assertVim("|.*\n.*", "*", ".*\n|.*")
        XCTAssertEqual(dots.register("/"), charwise("\\.\\*"))
    }

    func test_star_on_an_empty_line_fails_with_e348() {
        let run = assertVim("|\nx", "*", "|\nx")
        XCTAssertEqual(run.effects, [.message("E348: No string under cursor"), .failure])
    }

    func test_star_ignores_smartcase_and_so_does_n_after_it() {
        assertVim("foo bar\nbaz foo\n|Foo end", "*", start(), session: smartCase)
        assertVim("foo bar\nbaz foo\n|Foo end", "*n", "foo bar\nbaz |foo\nFoo end",
                  session: smartCase)
    }

    // MARK: Jumps, operators and Visual mode

    func test_a_search_is_a_jump() {
        assertVim("x\n|foo bar\nbaz foo", "/baz<CR>''", "x\n|foo bar\nbaz foo")
    }

    func test_an_operator_takes_a_search_motion_and_dot_repeats_it() {
        let run = assertVim("foo |bar\nbaz foo", "d/baz<CR>", "foo| \nbaz foo")
        XCTAssertEqual(run.register("1"), charwise("bar"))
        assertVim("|a b a b c", "d/b<CR>.", "|b c")
        assertVim("|foo bar foo", "dn", "|foo bar foo")
    }

    func test_an_operator_takes_n_and_star() {
        assertVim("|a b a b", "/b<CR>0dn", "|b a b")
        assertVim("|ab x ab", "d*", "|ab")
    }

    func test_visual_mode_extends_the_selection_to_the_match() {
        assertVim(start(), "v/bar<CR>", "[foo |b]ar\nbaz foo\nFoo end")
        assertVim("|foo bar\nbaz foo", "v/bar<CR>d", "|ar\nbaz foo")
    }

    // MARK: Offsets

    func test_an_e_offset_lands_on_the_end_of_the_match() {
        assertVim("|foo bar\nbaz foo", "/foo/e<CR>", "fo|o bar\nbaz foo")
        assertVim("|foo bar\nbaz foo", "/foo/e<CR>n", "foo bar\nbaz fo|o")
        assertVim("|foo bar\nbaz foo", "/foo/e-1<CR>", "f|oo bar\nbaz foo")
        assertVim("|foo bar\nbaz foo", "/foo/e-1<CR>n", "foo bar\nbaz f|oo")
    }

    func test_an_e_offset_makes_an_operator_inclusive() {
        assertVim("|xfoo bar\nbaz foo", "d/foo/e<CR>", "| bar\nbaz foo")
    }

    func test_start_and_line_offsets() {
        assertVim("|foo bar\nbaz foo", "/foo/s+1<CR>", "f|oo bar\nbaz foo")
        assertVim("|foo bar\nbaz foo", "/foo/b-1<CR>n", "|foo bar\nbaz foo")
        assertVim("|foo bar\n  baz foo", "/bar/+1<CR>", "foo bar\n|  baz foo")
    }

    // MARK: Submitting the prompt from the footer

    func test_a_submitted_search_runs_with_the_pending_count_and_operator() {
        var driver = VimDriver(start())
        driver.press("/")
        driver.search("foo")
        XCTAssertEqual(driver.run.rendered, "foo bar\nbaz |foo\nFoo end")
        XCTAssertEqual(driver.window.pendingKeys, [])
        var counted = VimDriver(start())
        counted.press("3/")
        counted.search("foo")
        XCTAssertEqual(counted.run.rendered, "foo bar\nbaz |foo\nFoo end")
        var deleting = VimDriver("foo |bar\nbaz foo")
        deleting.press("d/")
        deleting.search("baz")
        XCTAssertEqual(deleting.run.text, "foo \nbaz foo")
        XCTAssertEqual(deleting.session.lastChange?.keys, try VimKey.parse("d/baz<CR>"))
    }

    func test_a_submitted_backward_search_and_its_offset() {
        var driver = VimDriver("|foo bar\nbaz foo")
        driver.press("?")
        driver.search("foo?e", forward: false)
        XCTAssertEqual(driver.run.rendered, "foo bar\nbaz fo|o")
        XCTAssertEqual(driver.session.lastSearch,
                       LastSearch(pattern: "foo", forward: false,
                                  offset: SearchOffset(anchor: .end, amount: 0)))
    }
}
