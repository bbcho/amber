import XCTest
@testable import NotepadCore

final class VimRegistersTests: XCTestCase {
    private func chars(_ text: String) -> RegisterValue {
        RegisterValue(text: text, kind: .characterwise)
    }
    private func lines(_ text: String) -> RegisterValue {
        RegisterValue(text: text, kind: .linewise)
    }
    private func read(_ r: VimRegisters, _ name: Character) -> RegisterValue? {
        r.value(name, clipboard: { nil })
    }

    func test_a_yank_fills_unnamed_and_zero() {
        var r = VimRegisters()
        r.yank(chars("foo"), into: nil)
        XCTAssertEqual(read(r, "\""), chars("foo"))
        XCTAssertEqual(read(r, "0"), chars("foo"))
    }

    func test_a_yank_leaves_numbered_registers_alone() {
        var r = VimRegisters()
        r.delete(lines("a\n"), into: nil, small: false)
        r.yank(chars("foo"), into: nil)
        XCTAssertEqual(read(r, "1"), lines("a\n"))
        XCTAssertNil(read(r, "2"))
    }

    func test_two_deletes_shift_one_to_two() {
        var r = VimRegisters()
        r.delete(lines("a\n"), into: nil, small: false)
        r.delete(lines("b\n"), into: nil, small: false)
        XCTAssertEqual(read(r, "1"), lines("b\n"))
        XCTAssertEqual(read(r, "2"), lines("a\n"))
        XCTAssertEqual(read(r, "\""), lines("b\n"))
    }

    func test_the_ninth_shift_drops_the_oldest_delete() {
        var r = VimRegisters()
        for letter in "abcdefghij" { r.delete(lines("\(letter)\n"), into: nil, small: false) }
        XCTAssertEqual(read(r, "1"), lines("j\n"))
        XCTAssertEqual(read(r, "9"), lines("b\n"))
    }

    func test_a_small_delete_goes_to_minus_and_not_to_one() {
        var r = VimRegisters()
        r.delete(lines("a\n"), into: nil, small: false)
        r.delete(chars("x"), into: nil, small: true)
        XCTAssertEqual(read(r, "-"), chars("x"))
        XCTAssertEqual(read(r, "1"), lines("a\n"))
        XCTAssertNil(read(r, "2"))
        XCTAssertEqual(read(r, "\""), chars("x"))
    }

    func test_a_named_delete_fills_the_name_and_also_register_one() {
        var r = VimRegisters()
        r.delete(chars("word"), into: "b", small: true)
        XCTAssertEqual(read(r, "b"), chars("word"))
        XCTAssertEqual(read(r, "1"), chars("word"))
        XCTAssertNil(read(r, "-"))
        XCTAssertEqual(read(r, "\""), chars("word"))
    }

    func test_an_uppercase_name_appends_and_reads_back_through_the_lowercase_name() {
        var r = VimRegisters()
        r.yank(chars("foo"), into: "a")
        r.yank(chars("bar"), into: "A")
        XCTAssertEqual(read(r, "a"), chars("foobar"))
        XCTAssertEqual(read(r, "A"), chars("foobar"))
        XCTAssertEqual(read(r, "\""), chars("foobar"))
        XCTAssertNil(read(r, "0"))
    }

    func test_appending_a_line_to_characters_makes_the_register_linewise() {
        var r = VimRegisters()
        r.yank(chars("foo"), into: "a")
        r.yank(lines("bar\n"), into: "A")
        XCTAssertEqual(read(r, "a"), lines("foo\nbar\n"))
        r.yank(chars("baz"), into: "A")
        XCTAssertEqual(read(r, "a"), lines("foo\nbar\nbaz\n"))
    }

    func test_appending_to_an_empty_register_stores_the_value() {
        var r = VimRegisters()
        r.yank(lines("x\n"), into: "A")
        XCTAssertEqual(read(r, "a"), lines("x\n"))
    }

    func test_the_black_hole_keeps_everything_unchanged() {
        var r = VimRegisters()
        r.yank(chars("keep"), into: nil)
        r.delete(lines("old\n"), into: nil, small: false)
        let before = r
        r.yank(chars("gone"), into: "_")
        r.delete(lines("gone\n"), into: "_", small: false)
        r.delete(chars("g"), into: "_", small: true)
        XCTAssertEqual(r, before)
        XCTAssertNil(read(r, "_"))
    }

    func test_the_clipboard_registers_read_through_the_injected_function() {
        let r = VimRegisters()
        XCTAssertEqual(r.value("+", clipboard: { "text" }), chars("text"))
        XCTAssertEqual(r.value("*", clipboard: { "line\n" }), lines("line\n"))
        XCTAssertNil(r.value("+", clipboard: { nil }))
        XCTAssertNil(r.value("+", clipboard: { "" }))
        XCTAssertNil(r.value("a", clipboard: { "text" }))
    }

    func test_writing_to_the_clipboard_register_returns_the_text_to_copy() {
        var r = VimRegisters()
        XCTAssertEqual(r.yank(chars("copy"), into: "+"), "copy")
        XCTAssertEqual(read(r, "\""), chars("copy"))
        XCTAssertNil(read(r, "0"))
        XCTAssertNil(r.yank(chars("plain"), into: nil))
    }

    func test_read_only_registers_hold_what_the_engine_sets() {
        var r = VimRegisters()
        r.setReadOnly(".", "typed")
        r.setReadOnly(":", "s/a/b/")
        r.setReadOnly("/", "pat")
        XCTAssertEqual([read(r, "."), read(r, ":"), read(r, "/")],
                       [chars("typed"), chars("s/a/b/"), chars("pat")])
    }

    func test_only_real_targets_are_writable() {
        for name in "azAZ09-_+*" { XCTAssertTrue(VimRegisters.isWritable(name), "\(name)") }
        for name in ".:/%#=é" { XCTAssertFalse(VimRegisters.isWritable(name), "\(name)") }
        var r = VimRegisters()
        r.yank(chars("x"), into: ".")
        XCTAssertNil(read(r, "."))
    }
}
