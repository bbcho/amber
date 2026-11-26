import XCTest
@testable import NotepadCore

/// Timed tests of the engine on a one-megabyte document, one key at a time as the adapter
/// feeds them. They measure wall-clock time, so they are integration tests (H-T5). The
/// target is the design's: a single key under 16 ms.
final class VimSpeedTests: XCTestCase {
    private let keyBudget = 0.016

    /// 20,000 sentences of about 52 characters, one per line, every other one holding `foo`.
    private let megabyte = (0..<20_000).map { index in
        index % 2 == 0 ? "some text with foo and more words to pad the line \(index)."
            : "a plain line without the word, just padding it out \(index)."
    }.joined(separator: "\n")

    /// The slowest single key, over `repeats` runs, of each key sequence in `keys`, typed into
    /// a driver whose text is `text` and whose cursor starts at `cursor`.
    private func slowest(_ keys: [String], in text: String, cursor: Int = 0,
                         repeats: Int = 3) -> [(keys: String, seconds: Double)] {
        keys.map { notation in
            var worst = 0.0
            for _ in 0..<repeats {
                var driver = VimDriver("|" + text)
                driver.window.cursor = cursor
                for key in try! VimKey.parse(notation) {
                    let start = Date()
                    driver.feed([key], replayed: false)
                    worst = max(worst, Date().timeIntervalSince(start))
                }
            }
            return (notation, worst)
        }
    }

    private func report(_ results: [(keys: String, seconds: Double)]) {
        for (keys, seconds) in results {
            FileHandle.standardError.write(
                Data("SPEED \(keys.debugDescription): \(Int(seconds * 1000)) ms\n".utf8))
        }
    }

    func test_single_keys_on_a_one_megabyte_document_take_under_16_ms() {
        let middle = (megabyte as NSString).length / 2
        let keys = ["j", "k", "w", "b", "e", "$", "0", "^", "x", "dd", "p", "yy", "~", "J", "o",
                    "G", "gg", "}", "{", ")", "(", "%", "<C-d>", "<C-u>", "dw", "ciwx<Esc>",
                    "ix<Esc>", "A!<Esc>", "ma", "'a", "*", "n", "r!", ">>", "gUU", "<C-a>",
                    "v", "V", "H", "M", "L", "zz"]

        let results = slowest(keys, in: megabyte, cursor: middle)

        report(results)
        XCTAssertGreaterThan((megabyte as NSString).length, 1_000_000)
        XCTAssertEqual(results.filter { $0.seconds >= keyBudget }.map(\.keys), [])
    }

    func test_j_and_k_on_a_one_megabyte_single_line_take_under_16_ms() {
        let line = String(repeating: "word ", count: 200_000)

        let results = slowest(["j", "k", "w", "$", "0", "l", "h", "x"], in: line,
                              cursor: 500_000)

        report(results)
        XCTAssertEqual(results.filter { $0.seconds >= keyBudget }.map(\.keys), [])
    }

    func test_j_from_a_one_megabyte_line_to_a_second_line_takes_under_16_ms() {
        let text = String(repeating: "word ", count: 200_000) + "\nsecond"

        let results = slowest(["j"], in: text, cursor: 500_000)

        report(results)
        XCTAssertEqual(results.filter { $0.seconds >= keyBudget }.map(\.keys), [])
    }

    func test_the_dot_command_after_a_change_on_a_one_megabyte_document_is_under_16_ms() {
        var driver = VimDriver("|" + megabyte)
        driver.press("dw")
        let start = Date()
        driver.press(".")
        let seconds = Date().timeIntervalSince(start)

        report([(".", seconds)])
        XCTAssertLessThan(seconds, keyBudget)
    }

    func test_recording_typed_text_in_insert_mode_on_a_one_megabyte_document_is_under_16_ms() {
        var driver = VimDriver("|" + megabyte)
        driver.press("i")
        var worst = 0.0
        for character in "typing into a large note" {
            let start = Date()
            driver.type(String(character))
            worst = max(worst, Date().timeIntervalSince(start))
        }

        report([("insert typed character", worst)])
        XCTAssertLessThan(worst, keyBudget)
    }

    func test_a_substitute_through_the_driver_over_one_megabyte_takes_under_250_ms() {
        var driver = VimDriver("|" + megabyte)
        driver.runsExCommands = true
        let start = Date()
        driver.press(":%s/foo/bar/g<CR>")
        let seconds = Date().timeIntervalSince(start)

        report([(":%s/foo/bar/g", seconds)])
        XCTAssertEqual((driver.text as String).components(separatedBy: "bar").count - 1, 10_000)
        XCTAssertLessThan(seconds, 0.25)
    }

    func test_following_ten_thousand_marked_lines_through_an_edit_each_takes_under_one_second() {
        let lines = Array(stride(from: 0, to: 20_000, by: 2))
        let text = NSMutableString(string: megabyte)
        var marks = ExLineMarks(lines: lines, in: VimBuffer(text))
        var visited = 0
        let start = Date()
        while let offset = marks.next() {
            let range = NSRange(location: offset, length: 0)
            let edit = TextEdit(range: range, replacement: "x")
            marks.update(after: edit, in: text)
            text.replaceCharacters(in: range, with: "x")
            visited += 1
        }
        let seconds = Date().timeIntervalSince(start)

        report([("ExLineMarks 10,000 edits", seconds)])
        XCTAssertEqual(visited, 10_000)
        XCTAssertLessThan(seconds, 1)
    }
}
