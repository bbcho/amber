import XCTest
@testable import NotepadCore

final class VimKeyTests: XCTestCase {
    func test_plain_characters_parse_to_character_keys() throws {
        XCTAssertEqual(try VimKey.parse("dd"), [VimKey(.character("d")), VimKey(.character("d"))])
    }

    func test_named_keys_parse_regardless_of_case() throws {
        XCTAssertEqual(
            try VimKey.parse("<Esc><cr><BS><Tab><up><Down><Left><Right>"),
            [.escape, .enter, .backspace, .tab, .up, .down, .left, .right].map { VimKey($0) }
        )
        XCTAssertEqual(
            try VimKey.parse("<Home><End><PageUp><PageDown><Del>"),
            [.home, .end, .pageUp, .pageDown, .delete].map { VimKey($0) }
        )
    }

    func test_control_keys_parse_with_the_control_flag() throws {
        XCTAssertEqual(try VimKey.parse("<C-r>a"),
                       [VimKey(.character("r"), control: true), VimKey(.character("a"))])
        XCTAssertEqual(try VimKey.parse("<C-X>"), [VimKey(.character("x"), control: true)])
    }

    func test_lt_is_a_literal_less_than_sign() throws {
        XCTAssertEqual(try VimKey.parse("<lt>Esc>"),
                       [VimKey(.character("<")), VimKey(.character("E")), VimKey(.character("s")),
                        VimKey(.character("c")), VimKey(.character(">"))])
    }

    func test_unknown_notation_throws() {
        XCTAssertThrowsError(try VimKey.parse("<Bogus>")) {
            XCTAssertEqual($0 as? VimError, VimError("E474: Invalid key notation: <Bogus>"))
        }
        XCTAssertThrowsError(try VimKey.parse("a<b"))
    }

    func test_notation_round_trips() throws {
        let sample = "ihi<lt><Esc><C-r>a<CR><BS><Tab><Up><Down><Left><Right><Home><End>"
            + "<PageUp><PageDown><Del><C-Esc>:w<CR>"
        XCTAssertEqual(try VimKey.parse(sample).map(\.notation).joined(), sample)
    }

    func test_a_control_character_key_writes_as_C_dash_letter() {
        XCTAssertEqual(VimKey(.character("d"), control: true).notation, "<C-d>")
    }

    func test_space_is_a_space_character() throws {
        XCTAssertEqual(try VimKey.parse("<Space>"), [VimKey(.character(" "))])
    }
}
