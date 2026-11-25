import XCTest
@testable import NotepadCore

/// Expected text, cursors and registers were taken from Vim 9.1 with keys sent through
/// `feedkeys(..., "xt")`, so that Vim records them as typed.
final class VimMacroTests: XCTestCase {
    private let lines = "|one two three four\nfive six seven"

    // MARK: Recording

    func test_q_records_the_typed_keys_into_the_register_without_the_closing_q() {
        let run = assertVim(lines, "qqdwq", "|two three four\nfive six seven")
        XCTAssertEqual(run.register("q"), charwise("dw"))
        XCTAssertNil(run.session.recording)
    }

    func test_recording_starts_on_the_register_name_and_shows_in_the_session() {
        let run = runVim(lines, "qqdw")
        XCTAssertEqual(run.session.recording,
                       Recording(register: "q", keys: try VimKey.parse("dw")))
    }

    func test_recording_leaves_the_unnamed_register_alone() {
        let run = runVim(lines, "yiwqqlq")
        XCTAssertEqual(run.register("\""), charwise("one"))
        XCTAssertEqual(run.register("q"), charwise("l"))
    }

    func test_a_q_that_is_an_argument_or_typed_text_does_not_stop_recording() {
        XCTAssertEqual(runVim(lines, "qqfoq").register("q"), charwise("fo"))
        XCTAssertEqual(runVim(lines, "qqiq<Esc>q").register("q"), charwise("iq<Esc>"))
        XCTAssertEqual(runVim(lines, "qq3xq").register("q"), charwise("3x"))
    }

    func test_an_uppercase_register_appends_to_the_recording() {
        let run = assertVim(lines, "qqxqqQxq@q", "|two three four\nfive six seven")
        XCTAssertEqual(run.register("q"), charwise("xx"))
    }

    func test_appending_to_a_linewise_register_extends_its_last_line() {
        let run = runVim("|one two\nx", "\"qyyqQlq")
        XCTAssertEqual(run.register("q"), linewise("one twol\n"))
    }

    func test_an_invalid_register_name_fails() {
        let run = runVim(lines, "q!")
        XCTAssertEqual(run.effects, [.failure])
        XCTAssertNil(run.session.recording)
    }

    func test_inserts_and_searches_are_recorded_in_key_notation() {
        XCTAssertEqual(runVim(lines, "qqifoo<BS>x<Esc>q").register("q"),
                       charwise("ifoo<BS>x<Esc>"))
        XCTAssertEqual(runVim(lines, "qq/two<CR>q").register("q"), charwise("/two<CR>"))
        XCTAssertEqual(runVim("|a<b", "qqi<lt><Esc>q").register("q"), charwise("i<lt><Esc>"))
    }

    func test_keys_replayed_by_a_macro_are_not_recorded() {
        let run = runVim(lines, "qwlqqq@wq")
        XCTAssertEqual(run.register("q"), charwise("@w"))
    }

    func test_text_typed_into_appkit_and_a_submitted_search_are_recorded() {
        var driver = VimDriver(lines)
        driver.press("qqi")
        driver.type("ab")
        driver.press("<Esc>/")
        driver.search("two")
        driver.press("q")
        XCTAssertEqual(driver.run.register("q"), charwise("iab<Esc>/two<CR>"))
    }

    // MARK: Playing

    func test_at_plays_the_register_and_a_count_plays_it_again() {
        assertVim(lines, "qqdwq@q", "|three four\nfive six seven")
        assertVim(lines, "qqdwq2@q", "|four\nfive six seven")
    }

    func test_at_at_plays_the_last_register_again() {
        assertVim(lines, "qqdwq@q@@", "|four\nfive six seven")
        let run = assertVim(lines, "@@", lines)
        XCTAssertEqual(run.effects, [.message("E748: No previously used register"), .failure])
    }

    func test_a_played_insert_reproduces_backspace() {
        assertVim(lines, "qqifoo<BS>x<Esc>q@q", "fofo|xxone two three four\nfive six seven")
    }

    func test_a_played_macro_stops_at_the_first_failure() {
        let run = assertVim(lines, "qq/two<CR>xq0@q", "|one wo three four\nfive six seven")
        XCTAssertTrue(run.effects.contains(.message("E486: Pattern not found: two")))
    }

    func test_playing_an_empty_register_fails() {
        XCTAssertEqual(runVim(lines, "@a").effects, [.failure])
    }

    func test_a_played_linewise_register_moves_down_after_each_line() {
        assertVim("|x\nab\ncd", "\"qyyj@q", "x\nb\n|cd")
    }

    func test_text_that_is_not_key_notation_plays_literally() {
        var start = VimSession()
        start.registers.storeMacro("ia<b<Esc>", in: "q")
        assertVim("|x", "@q", "a<|bx", session: start)
    }

    func test_at_colon_runs_the_last_command_line_again() {
        var start = VimSession()
        start.registers.setReadOnly(":", "s/o/0/")
        let run = runVim(lines, "2@:@@", session: start)
        XCTAssertEqual(run.effects.filter { $0 == .ex("s/o/0/") }.count, 3)
        XCTAssertEqual(run.effects.first, .replay(try VimKey.parse(":s/o/0/<CR>:s/o/0/<CR>")))
        let none = runVim(lines, "@:")
        XCTAssertEqual(none.effects, [.message("E30: No previous command line"), .failure])
    }

    func test_colon_opens_the_command_line_and_return_runs_it() {
        let run = runVim(lines, ":s/a/b/<CR>")
        XCTAssertEqual(run.effects, [.openCommandLine(":"), .ex("s/a/b/")])
        XCTAssertEqual(run.window.pendingKeys, [])
    }

    func test_a_huge_count_replays_no_more_keys_than_the_limit_allows() {
        let run = runVim(lines, "qqlq999999999@q<Esc>")
        let replayed = run.effects.compactMap { effect -> Int? in
            if case .replay(let keys) = effect { return keys.count }
            return nil
        }
        XCTAssertEqual(replayed, [100_001])
    }
}
