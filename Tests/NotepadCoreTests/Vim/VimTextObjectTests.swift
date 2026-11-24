import XCTest
@testable import NotepadCore

/// Expected text, cursors and registers were taken from Vim 9.1 (`vim -u NONE -N` with
/// `ts=4 sw=4 et so=0`).
final class VimTextObjectTests: XCTestCase {
    // MARK: Words

    func test_iw_is_the_word_under_the_cursor() {
        let run = assertVim("foo b|ar baz", "diw", "foo | baz")
        XCTAssertEqual(run.register("-"), charwise("bar"))
    }

    func test_iw_on_blanks_is_the_run_of_blanks() {
        assertVim("foo  |  bar", "diw", "foo|bar")
    }

    func test_aw_takes_the_trailing_blanks() {
        assertVim("foo b|ar baz", "daw", "foo |baz")
        assertVim("foo b|ar  ", "daw", "foo| ")
    }

    func test_aw_without_trailing_blanks_takes_the_leading_ones() {
        let run = assertVim("foo b|ar", "daw", "fo|o")
        XCTAssertEqual(run.register("-"), charwise(" bar"))
        assertVim("foo  b|ar", "daw", "fo|o")
        assertVim("foo b|ar.  baz", "daw", "foo|.  baz")
    }

    func test_aw_never_takes_the_indent() {
        assertVim("  f|oo bar", "daw", "  |bar")
        assertVim("foo\n  |bar\nbaz", "daw", "foo\n | \nbaz")
        assertVim("foo\nb|ar", "daw", "foo\n|")
    }

    func test_aw_on_blanks_takes_the_following_word() {
        assertVim("foo  |  bar", "daw", "fo|o")
    }

    func test_a_count_on_iw_counts_words_and_blanks() {
        let run = assertVim("foo b|ar baz qux", "3diw", "foo | qux")
        XCTAssertEqual(run.register("-"), charwise("bar baz"))
        assertVim("foo |bar\nbaz", "2diw", "foo| ")
    }

    func test_a_count_on_aw_counts_words() {
        assertVim("foo b|ar baz qux", "2daw", "foo |qux")
        assertVim("foo |bar\nbaz", "2daw", "fo|o")
    }

    func test_iW_and_aW_use_blank_separated_words() {
        assertVim("foo b|ar.baz", "diW", "foo| ")
        assertVim("foo b|ar.baz qux", "daW", "foo |qux")
    }

    // MARK: Sentences

    func test_is_is_the_sentence_under_the_cursor() {
        assertVim("a b. C|d e. F g.", "dis", "a b. | F g.")
        let run = assertVim("Hello there.  How are |you?  Fine.", "dis",
                            "Hello there.  |  Fine.")
        XCTAssertEqual(run.register("-"), charwise("How are you?"))
    }

    func test_as_takes_the_trailing_blanks() {
        assertVim("a b. C|d e. F g.", "das", "a b. |F g.")
        assertVim("Hello there.  How are |you?  Fine.", "das", "Hello there.  |Fine.")
    }

    func test_as_at_the_end_takes_the_leading_blanks() {
        assertVim("Hello there.  How are |you?", "das", "Hello there|.")
        assertVim("Hello there.|  How are you?", "das", "Hello there|.")
    }

    func test_is_on_the_blanks_between_sentences_is_those_blanks() {
        assertVim("a b. Cd e.|  F g.", "dis", "a b. Cd e.|F g.")
    }

    func test_a_count_on_as_counts_sentences() {
        assertVim("Hello there.  |How are you?  Fine.", "2das", "Hello there|.")
    }

    func test_a_sentence_over_whole_lines_is_deleted_as_lines() {
        assertVim("a\nb|c\nd", "dis", "|")
    }

    // MARK: Paragraphs

    func test_ip_is_the_paragraph_lines() {
        let run = assertVim("a\n\nb|c\nd\n\ne", "dip", "a\n\n|\ne")
        XCTAssertEqual(run.register("1"), linewise("bc\nd\n"))
        assertVim("foo\nbar\n|baz", "dip", "|")
    }

    func test_ap_takes_the_following_blank_lines() {
        assertVim("a\n\nb|c\nd\n\ne", "dap", "a\n\n|e")
    }

    func test_ap_at_the_end_takes_the_preceding_blank_lines() {
        let run = assertVim("a\n\nb|c\nd", "dap", "|a")
        XCTAssertEqual(run.register("1"), linewise("\nbc\nd\n"))
    }

    func test_ip_and_ap_on_blank_lines() {
        assertVim("a\n|\n\nb", "dip", "a\n|b")
        assertVim("a\n|\n\nb", "dap", "|a")
    }

    func test_a_count_on_ip_and_ap() {
        assertVim("a\n\nb|c\nd\n\ne\n\nf", "2dap", "a\n\n|f")
        assertVim("a\n\nb|c\nd\n\ne\n\nf", "2dip", "a\n\n|e\n\nf")
    }

    // MARK: Quotes

    func test_i_quote_is_the_text_inside_the_quotes() {
        let run = assertVim("x \"a|b\" y", "di\"", "x \"|\" y")
        XCTAssertEqual(run.register("-"), charwise("ab"))
        assertVim("x 'a|b' y", "di'", "x '|' y")
    }

    func test_a_quote_takes_the_quotes_and_trailing_blanks() {
        assertVim("x \"a|b\" y", "da\"", "x |y")
        assertVim("x `a|b` y", "da`", "x |y")
        assertVim("x |'a' y", "da'", "x |y")
        assertVim("\"|a\" x", "da\"", "|x")
    }

    func test_a_quote_without_trailing_blanks_takes_the_leading_ones() {
        let run = assertVim("x  \"|a\"", "da\"", "|x")
        XCTAssertEqual(run.register("-"), charwise("  \"a\""))
    }

    func test_i_quote_before_the_first_quote_finds_the_next_string() {
        assertVim("|x \"ab\" y", "di\"", "x \"|\" y")
    }

    func test_i_quote_skips_quotes_escaped_with_a_backslash() {
        let run = assertVim("x \"a\\\"|b\" y", "di\"", "x \"|\" y")
        XCTAssertEqual(run.register("-"), charwise("a\\\"b"))
        assertVim("x \"a\\\"b\" |\"c\"", "di\"", "x \"a\\\"b\" \"|\"")
    }

    func test_i_quote_on_a_quote_works_out_which_string_it_belongs_to() {
        assertVim("x \"a\" y |\"b\"", "di\"", "x \"a\" y \"|\"")
        assertVim("x \"a\" |\"b\"", "di\"", "x \"a\" \"|\"")
    }

    func test_i_quote_between_two_strings_takes_the_text_between_them() {
        assertVim("x \"a\" |y \"b\"", "di\"", "x \"a\"|\"b\"")
    }

    func test_a_count_of_two_on_i_quote_takes_the_quotes() {
        assertVim("x \"a|b\" y", "2di\"", "x | y")
    }

    func test_i_quote_on_empty_quotes_deletes_nothing() {
        let run = assertVim("x \"|\"", "di\"", "x \"|\"")
        XCTAssertNil(run.register("\""))
    }

    func test_a_quote_after_the_last_string_fails() {
        let run = assertVim("x \"ab\"| y", "da\"", "x \"ab\"| y")
        XCTAssertEqual(run.effects, [.failure])
    }

    // MARK: Blocks

    func test_i_paren_is_the_text_inside_the_innermost_parentheses() {
        let run = assertVim("f(a, (b|), c)", "di(", "f(a, (|), c)")
        XCTAssertEqual(run.register("-"), charwise("b"))
        assertVim("f(a|)", "di)", "f(|)")
        assertVim("f(a, (b), |c)", "dib", "f(|)")
    }

    func test_a_paren_takes_the_parentheses() {
        assertVim("f(a, (b|), c)", "da(", "f(a, |, c)")
        assertVim("f(a, (b), |c)", "dab", "|f")
    }

    func test_a_count_on_i_paren_selects_an_outer_block() {
        assertVim("f(a, (b|), c)", "2di(", "f(|)")
    }

    func test_i_paren_on_or_before_the_opening_parenthesis() {
        assertVim("|f(a)", "di(", "f(|)")
        assertVim("x (a) |y (b)", "di(", "x (a) y (|)")
    }

    func test_i_paren_on_an_empty_block_deletes_nothing() {
        assertVim("f(|)", "di(", "f(|)")
        assertVim("( |)", "di(", "(|)")
    }

    func test_i_paren_without_a_block_fails() {
        let run = assertVim("a|bc", "di(", "a|bc")
        XCTAssertEqual(run.effects, [.failure])
    }

    func test_i_paren_ignores_escaped_parentheses() {
        let run = assertVim("f(a \\( |b)", "di(", "f(|)")
        XCTAssertEqual(run.register("-"), charwise("a \\( b"))
    }

    func test_brackets_angles_and_braces() {
        assertVim("x [a |b] y", "di[", "x [|] y")
        assertVim("x [a |b] y", "da]", "x | y")
        assertVim("x <a |b> y", "di<lt>", "x <|> y")
        assertVim("x <a |b> y", "da>", "x | y")
        assertVim("x {a |b} y", "daB", "x | y")
        assertVim("{a|}", "ci{X<Esc>", "{|X}")
    }

    func test_i_brace_over_whole_lines_is_linewise() {
        let run = assertVim("if {\n    a|b\n    cd\n}", "di{", "if {\n|}")
        XCTAssertEqual(run.register("1"), linewise("    ab\n    cd\n"))
        assertVim("if {\n    a|b\n    cd\n}", "diB", "if {\n|}")
        assertVim("if {\n    a|b\n    cd\n}", "ciBX<Esc>", "if {\n|X\n}")
    }

    func test_a_brace_over_lines_is_characterwise() {
        let run = assertVim("if {\n    a|b\n    cd\n}", "da{", "if| ")
        XCTAssertEqual(run.register("1"), charwise("{\n    ab\n    cd\n}"))
    }

    func test_i_paren_across_lines_stays_characterwise_when_text_follows_the_opening() {
        assertVim("(a\n|b\n)", "di(", "|(\n)")
        assertVim("(\n|b\n)", "di(", "(\n|)")
        assertVim("(a\n  |b\n  )", "di(", "|(\n  )")
    }
}
