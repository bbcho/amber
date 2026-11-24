import XCTest
@testable import NotepadCore

final class VimPatternTests: XCTestCase {
    private func icu(_ pattern: String, previous: String? = nil) throws -> String {
        try VimPattern.regex(pattern, ignoreCase: false, smartCase: false,
                             previousSubstitute: previous).pattern
    }

    private func matches(_ pattern: String, in text: String, ignoreCase: Bool = false,
                         smartCase: Bool = false) throws -> [String] {
        let regex = try VimPattern.regex(pattern, ignoreCase: ignoreCase, smartCase: smartCase)
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }

    private func failure(_ pattern: String) -> String? {
        do { _ = try icu(pattern); return nil } catch { return (error as? VimError)?.message }
    }

    func test_word_boundaries_become_b() throws {
        XCTAssertEqual(try icu("\\<foo\\>"), "\\bfoo\\b")
    }

    func test_magic_groups_alternation_and_multis_translate() throws {
        XCTAssertEqual(try icu("\\(a\\|b\\)\\+"), "(a|b)+")
        XCTAssertEqual(try icu("a\\?b\\=c*"), "a?b?c*")
        XCTAssertEqual(try icu("a\\{2,3}b\\{2}c\\{,4}d\\{2,}e\\{}"), "a{2,3}b{2}c{0,4}d{2,}e*")
        XCTAssertEqual(try icu("a\\{-1,2}b\\{-}"), "a{1,2}?b*?")
        XCTAssertEqual(try icu("a\\{2\\}"), "a{2}")
    }

    func test_very_magic_needs_no_backslashes() throws {
        XCTAssertEqual(try icu("\\v(a|b)+"), "(a|b)+")
        XCTAssertEqual(try icu("\\v<foo>x=y{2,3}"), "\\bfoo\\bx?y{2,3}")
    }

    func test_very_nomagic_makes_dot_star_and_brackets_literal() throws {
        XCTAssertEqual(try icu("\\Va.b*[c]"), "a\\.b\\*\\[c]")
        XCTAssertEqual(try icu("\\V\\.\\*"), ".*")
        XCTAssertEqual(try matches("\\Va.b", in: "a.b axb"), ["a.b"])
    }

    func test_plain_parentheses_and_other_icu_specials_are_escaped() throws {
        XCTAssertEqual(try icu("a(b)"), "a\\(b\\)")
        XCTAssertEqual(try icu("a|b+c?{1}"), "a\\|b\\+c\\?\\{1\\}")
        XCTAssertEqual(try icu("\\v\\(\\)"), "\\(\\)")
    }

    func test_escaped_punctuation_is_literal() throws {
        XCTAssertEqual(try icu("a\\/b\\.c\\\\d"), "a\\/b\\.c\\\\d")
    }

    func test_character_classes_translate_and_exclude_line_breaks() throws {
        XCTAssertEqual(try icu("\\d\\+"), "[0-9]+")
        XCTAssertEqual(try matches("\\s", in: "a \tb\nc"), [" ", "\t"])
        XCTAssertEqual(try matches("\\S\\+", in: "ab  cd\nef"), ["ab", "cd", "ef"])
        XCTAssertEqual(try matches("\\w\\+", in: "foo_1-bar"), ["foo_1", "bar"])
        XCTAssertEqual(try matches("\\W", in: "a-b\nc"), ["-"])
        XCTAssertEqual(try matches("\\a\\l\\u\\x", in: "xaBf"), ["xaBf"])
        XCTAssertEqual(try matches("\\D", in: "1a2\n"), ["a"])
    }

    func test_caret_and_dollar_anchor_lines_only_at_the_ends() throws {
        XCTAssertEqual(try icu("^a$"), "^a$")
        XCTAssertEqual(try icu("a^b$c"), "a\\^b\\$c")
        XCTAssertEqual(try icu("\\(^a\\|b$\\)"), "(^a|b$)")
        XCTAssertEqual(try matches("^b", in: "a\nb\nb"), ["b", "b"])
        XCTAssertEqual(try matches("a$", in: "a\nb\na"), ["a", "a"])
    }

    func test_dollar_before_trailing_flags_is_still_an_anchor() throws {
        XCTAssertEqual(try icu("foo$\\c"), "foo$")
        XCTAssertEqual(try icu("\\(foo$\\C\\)"), "(foo$)")
        XCTAssertEqual(try matches("foo$\\c", in: "foo\nFOO\nfoox"), ["foo", "FOO"])
        XCTAssertEqual(try icu("a$\\cb"), "a\\$b")
    }

    func test_a_leading_star_is_literal() throws {
        XCTAssertEqual(try icu("*a"), "\\*a")
        XCTAssertEqual(try icu("^*a"), "^\\*a")
    }

    func test_collections_translate() throws {
        XCTAssertEqual(try matches("[a-c]\\+", in: "abcd"), ["abc"])
        XCTAssertEqual(try matches("[^a-c]", in: "ad\n"), ["d"])
        XCTAssertEqual(try matches("[]x]", in: "]x"), ["]", "x"])
        XCTAssertEqual(try matches("[[:digit:]]\\+", in: "a12b"), ["12"])
        XCTAssertEqual(try matches("[a\\]\\-]", in: "a]-b"), ["a", "]", "-"])
        XCTAssertEqual(try matches("[.*]", in: "a.*"), [".", "*"])
        XCTAssertEqual(try matches("a[b", in: "a[b"), ["a[b"])
    }

    func test_tilde_is_the_previous_substitute_string() throws {
        XCTAssertEqual(try icu("a~b", previous: "x.y"), "a(?:x\\.y)b")
        XCTAssertEqual(try icu("\\Va~b", previous: "x"), "a~b")
        XCTAssertEqual(try icu("\\Va\\~b", previous: "x"), "a(?:x)b")
        XCTAssertThrowsError(try icu("a~")) {
            XCTAssertEqual($0 as? VimError,
                           VimError("E33: No previous substitute regular expression"))
        }
    }

    func test_backslash_c_ignores_case_and_backslash_C_matches_it() throws {
        XCTAssertEqual(try matches("foo\\c", in: "FOO foo"), ["FOO", "foo"])
        XCTAssertEqual(try matches("\\Cfoo", in: "FOO foo", ignoreCase: true), ["foo"])
        XCTAssertEqual(try matches("Foo\\c", in: "foo", smartCase: true), ["foo"])
    }

    func test_smart_case_applies_only_with_ignore_case_and_an_uppercase_letter() throws {
        XCTAssertEqual(try matches("Foo", in: "foo Foo", ignoreCase: true, smartCase: true),
                       ["Foo"])
        XCTAssertEqual(try matches("foo", in: "foo Foo", ignoreCase: true, smartCase: true),
                       ["foo", "Foo"])
        XCTAssertEqual(try matches("foo", in: "foo Foo", ignoreCase: false, smartCase: true),
                       ["foo"])
        XCTAssertEqual(try matches("Foo", in: "foo Foo", ignoreCase: true, smartCase: false),
                       ["foo", "Foo"])
        XCTAssertEqual(try matches("\\S", in: "ab", ignoreCase: true, smartCase: true),
                       ["a", "b"])
    }

    func test_unsupported_syntax_throws_instead_of_guessing() {
        for pattern in ["\\n", "\\t", "\\1", "\\%(a\\)", "a\\@=", "\\zs", "a\\&b", "\\_s", "\\M"] {
            XCTAssertNotNil(failure(pattern), pattern)
        }
        XCTAssertEqual(failure("\\n"),
                       "E383: Invalid search string: \\n is not supported in \\n")
    }

    func test_malformed_patterns_throw_vims_errors() {
        XCTAssertEqual(failure("\\(a"), "E54: Unmatched \\(")
        XCTAssertEqual(failure("a\\)"), "E55: Unmatched \\)")
        XCTAssertEqual(failure("\\+a"), "E64: \\+ follows nothing")
        XCTAssertEqual(failure("a*\\+"), "E871: Can't have a multi follow a multi")
        XCTAssertEqual(failure("a\\{x}"), "E554: Syntax error in \\{...}")
        XCTAssertEqual(failure("a\\{2"), "E554: Syntax error in \\{...}")
        XCTAssertEqual(failure("a\\"),
                       "E383: Invalid search string: a trailing backslash is not supported in a\\")
    }

    // MARK: Replacements

    func test_ampersand_and_numbered_groups_become_template_references() throws {
        XCTAssertEqual(try VimPattern.template("<&>", previous: nil), "<$0>")
        XCTAssertEqual(try VimPattern.template("\\2-\\1-\\0", previous: nil), "$2-$1-$0")
        XCTAssertEqual(try VimPattern.template("\\&", previous: nil), "&")
    }

    func test_a_digit_after_a_group_reference_cannot_extend_it() throws {
        let regex = try NSRegularExpression(pattern: "(a)")
        let template = try VimPattern.template("\\10", previous: nil)
        XCTAssertEqual(template, "$1\\0")
        XCTAssertEqual(regex.stringByReplacingMatches(
            in: "a", range: NSRange(location: 0, length: 1), withTemplate: template), "a0")
    }

    func test_dollar_and_backslash_in_a_replacement_are_literal() throws {
        let template = try VimPattern.template("$1 \\\\ \\/", previous: nil)
        XCTAssertEqual(template, "\\$\\1 \\\\ /")
        let regex = try NSRegularExpression(pattern: "(a)")
        XCTAssertEqual(regex.stringByReplacingMatches(
            in: "a", range: NSRange(location: 0, length: 1), withTemplate: template), "$1 \\ /")
    }

    func test_backslash_r_is_a_line_break_and_backslash_n_is_nul() throws {
        XCTAssertEqual(try VimPattern.template("a\\rb\\nc", previous: nil), "a\nb\u{0}c")
    }

    func test_case_conversions_become_markers() throws {
        XCTAssertEqual(
            try VimPattern.template("\\u\\1\\U\\2\\e\\l\\3\\L\\4\\E", previous: nil),
            "\u{E000}$1\u{E001}$2\u{E004}\u{E002}$3\u{E003}$4\u{E004}"
        )
    }

    func test_tilde_in_a_replacement_inserts_the_previous_string_before_parsing() throws {
        XCTAssertEqual(try VimPattern.template("~!", previous: "[&]"), "[$0]!")
        XCTAssertEqual(try VimPattern.template("\\~", previous: "zzz"), "~")
        XCTAssertEqual(try VimPattern.expandPrevious("a~\\~b", previous: "X"), "aX\\~b")
        XCTAssertThrowsError(try VimPattern.template("~", previous: nil)) {
            XCTAssertEqual($0 as? VimError,
                           VimError("E33: No previous substitute regular expression"))
        }
    }

    func test_unsupported_replacement_escapes_throw() {
        XCTAssertThrowsError(try VimPattern.template("\\t", previous: nil))
        XCTAssertThrowsError(try VimPattern.template("a\\", previous: nil))
    }
}
