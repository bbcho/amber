import XCTest
@testable import NotepadCore

final class VimBufferTests: XCTestCase {
    private func buffer(_ text: String) -> VimBuffer { VimBuffer(text as NSString) }

    func test_lf_lines_have_ranges_with_and_without_the_break() {
        let b = buffer("ab\ncde\nf")
        XCTAssertEqual(b.lineCount, 3)
        XCTAssertEqual(b.lineRange(at: 0), NSRange(location: 0, length: 3))
        XCTAssertEqual(b.contentRange(at: 0), NSRange(location: 0, length: 2))
        XCTAssertEqual(b.lineRange(at: 2), NSRange(location: 7, length: 1))
        XCTAssertEqual(b.contentRange(at: 2), NSRange(location: 7, length: 1))
    }

    func test_crlf_is_one_line_break() {
        let b = buffer("ab\r\ncd\r\n")
        XCTAssertEqual(b.lineCount, 2)
        XCTAssertEqual(b.lineRange(at: 0), NSRange(location: 0, length: 4))
        XCTAssertEqual(b.contentRange(at: 0), NSRange(location: 0, length: 2))
        XCTAssertEqual(b.lineRange(at: 1), NSRange(location: 4, length: 4))
        XCTAssertEqual(b.contentRange(at: 1), NSRange(location: 4, length: 2))
    }

    func test_cr_and_line_separator_also_end_lines() {
        let b = buffer("a\rb\u{2028}c")
        XCTAssertEqual(b.lineCount, 3)
        XCTAssertEqual(b.contentRange(at: 0), NSRange(location: 0, length: 1))
        XCTAssertEqual(b.lineRange(at: 1), NSRange(location: 2, length: 2))
        XCTAssertEqual(b.contentRange(at: 2), NSRange(location: 4, length: 1))
    }

    func test_empty_text_is_one_empty_line() {
        let b = buffer("")
        XCTAssertEqual(b.lineCount, 1)
        XCTAssertEqual(b.lineRange(at: 0), NSRange(location: 0, length: 0))
        XCTAssertEqual(b.contentRange(at: 0), NSRange(location: 0, length: 0))
    }

    func test_a_final_line_break_ends_the_last_line_without_adding_one() {
        let b = buffer("a\n")
        XCTAssertEqual(b.lineCount, 1)
        XCTAssertEqual(b.lineRange(at: 0), NSRange(location: 0, length: 2))
        XCTAssertEqual(b.contentRange(at: 0), NSRange(location: 0, length: 1))
        XCTAssertEqual(b.lineIndex(of: 2), 0)
        XCTAssertEqual(buffer("a\nb").lineCount, 2)
        XCTAssertEqual(buffer("a\n\n").lineCount, 2)
        XCTAssertEqual(buffer("a\r\n").lineCount, 1)
    }

    func test_line_index_of_an_offset_finds_its_line() {
        let b = buffer("ab\ncde\nf")
        XCTAssertEqual([0, 2, 3, 6, 7, 8].map(b.lineIndex(of:)), [0, 0, 1, 1, 2, 2])
        XCTAssertEqual(b.lineIndex(of: 99), 2)
        XCTAssertEqual(b.lineIndex(of: -5), 0)
    }

    func test_an_emoji_with_a_joiner_is_one_grapheme() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        let b = buffer("a" + family + "e\u{301}b")
        XCTAssertEqual(b.nextGrapheme(after: 0), 1)
        XCTAssertEqual(b.nextGrapheme(after: 1), 1 + family.utf16.count)
        let accent = 1 + family.utf16.count
        XCTAssertEqual(b.nextGrapheme(after: accent), accent + 2)
        XCTAssertEqual(b.previousGrapheme(before: accent), 1)
        XCTAssertEqual(b.previousGrapheme(before: accent + 2), accent)
        XCTAssertNil(b.previousGrapheme(before: 0))
        XCTAssertNil(b.nextGrapheme(after: b.length))
    }

    func test_crlf_is_one_grapheme() {
        let b = buffer("a\r\nb")
        XCTAssertEqual(b.nextGrapheme(after: 1), 3)
        XCTAssertEqual(b.previousGrapheme(before: 3), 1)
    }

    func test_first_non_blank_skips_spaces_and_tabs() {
        let b = buffer("  \tx\n\n   \nyy")
        XCTAssertEqual(b.firstNonBlank(line: 0), 3)
        XCTAssertEqual(b.firstNonBlank(line: 1), 5)
        XCTAssertEqual(b.firstNonBlank(line: 2), 9)
        XCTAssertEqual(b.firstNonBlank(line: 3), 10)
    }

    func test_a_tab_reaches_the_next_multiple_of_the_tabstop() {
        let b = buffer("a\tbc\n\u{1F600}x")
        XCTAssertEqual(b.displayColumn(of: 0, tabstop: 4), 0)
        XCTAssertEqual(b.displayColumn(of: 1, tabstop: 4), 1)
        XCTAssertEqual(b.displayColumn(of: 2, tabstop: 4), 4)
        XCTAssertEqual(b.displayColumn(of: 3, tabstop: 4), 5)
        XCTAssertEqual(b.displayColumn(of: 2, tabstop: 8), 8)
        XCTAssertEqual(b.displayColumn(of: 7, tabstop: 4), 1)
        XCTAssertEqual(b.displayColumn(of: 8, tabstop: 4), 2)
    }

    func test_offset_for_a_column_lands_on_the_grapheme_covering_it() {
        let b = buffer("a\tbc\n\u{1F600}x")
        XCTAssertEqual(b.offset(line: 0, displayColumn: 0, tabstop: 4), 0)
        XCTAssertEqual(b.offset(line: 0, displayColumn: 3, tabstop: 4), 1)
        XCTAssertEqual(b.offset(line: 0, displayColumn: 4, tabstop: 4), 2)
        XCTAssertEqual(b.offset(line: 0, displayColumn: 5, tabstop: 4), 3)
        XCTAssertEqual(b.offset(line: 0, displayColumn: 99, tabstop: 4), 4)
        XCTAssertEqual(b.offset(line: 1, displayColumn: 1, tabstop: 4), 7)
    }

    func test_word_classes_on_foo_dash_bar_baz() {
        let b = buffer("foo-bar baz")
        let classes = (0..<b.length).map { b.wordClass(at: $0, bigWord: false) }
        XCTAssertEqual(classes, [.word, .word, .word, .punctuation, .word, .word, .word,
                                 .blank, .word, .word, .word])
        let big = (0..<b.length).map { b.wordClass(at: $0, bigWord: true) }
        XCTAssertEqual(big, [.word, .word, .word, .word, .word, .word, .word,
                             .blank, .word, .word, .word])
    }

    func test_underscore_and_accented_letters_are_word_characters() {
        let b = buffer("_é\u{301}")
        XCTAssertEqual(b.wordClass(at: 0, bigWord: false), .word)
        XCTAssertEqual(b.wordClass(at: 1, bigWord: false), .word)
    }

    func test_line_breaks_and_the_end_of_text_are_blank() {
        let b = buffer("a\n")
        XCTAssertEqual(b.wordClass(at: 1, bigWord: false), .blank)
        XCTAssertEqual(b.wordClass(at: 2, bigWord: false), .blank)
    }

    func test_emoji_are_their_own_word_class_as_in_vim() {
        let b = buffer("a😀.👨\u{200D}👩")
        XCTAssertEqual(b.wordClass(at: 1, bigWord: false), .emoji)
        XCTAssertEqual(b.wordClass(at: 3, bigWord: false), .punctuation)
        XCTAssertEqual(b.wordClass(at: 4, bigWord: false), .emoji)
        XCTAssertEqual(b.wordClass(at: 1, bigWord: true), .word)
    }
}
