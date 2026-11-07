import Foundation
import XCTest
@testable import NotepadCore

final class VimCommandTests: XCTestCase {
    func test_write_aliases_preserve_the_quit_intent() throws {
        let examples: [(String, VimCommand)] = [
            ("w", .write(path: nil, force: false, quit: false)),
            ("write", .write(path: nil, force: false, quit: false)),
            ("wq", .write(path: nil, force: false, quit: true)),
            ("wquit", .write(path: nil, force: false, quit: true))
        ]
        for (input, expected) in examples {
            XCTAssertEqual(try VimCommand.parse(input), expected, input)
        }
    }

    func test_all_document_aliases_preserve_the_quit_intent() throws {
        let examples: [(String, VimCommand)] = [
            ("wa", .writeAll(force: false, quit: false)),
            ("wall", .writeAll(force: false, quit: false)),
            ("wqa", .writeAll(force: false, quit: true)),
            ("wqall", .writeAll(force: false, quit: true)),
            ("q", .quit(all: false, force: false)),
            ("quit", .quit(all: false, force: false)),
            ("qa", .quit(all: true, force: false)),
            ("qall", .quit(all: true, force: false))
        ]
        for (input, expected) in examples {
            XCTAssertEqual(try VimCommand.parse(input), expected, input)
        }
    }

    func test_exit_edit_and_new_aliases_select_the_expected_action() throws {
        let examples: [(String, VimCommand)] = [
            ("x", .exit), ("exit", .exit),
            ("e", .edit(path: nil, force: false)),
            ("edit", .edit(path: nil, force: false)),
            ("new", .newWindow)
        ]
        for (input, expected) in examples {
            XCTAssertEqual(try VimCommand.parse(input), expected, input)
        }
    }

    func test_bang_sets_force_for_each_supported_command_alias() throws {
        let examples: [(String, VimCommand)] = [
            ("w!", .write(path: nil, force: true, quit: false)),
            ("write!", .write(path: nil, force: true, quit: false)),
            ("wq!", .write(path: nil, force: true, quit: true)),
            ("wquit!", .write(path: nil, force: true, quit: true)),
            ("wa!", .writeAll(force: true, quit: false)),
            ("wall!", .writeAll(force: true, quit: false)),
            ("wqa!", .writeAll(force: true, quit: true)),
            ("wqall!", .writeAll(force: true, quit: true)),
            ("q!", .quit(all: false, force: true)),
            ("quit!", .quit(all: false, force: true)),
            ("qa!", .quit(all: true, force: true)),
            ("qall!", .quit(all: true, force: true)),
            ("e!", .edit(path: nil, force: true)),
            ("edit!", .edit(path: nil, force: true))
        ]
        for (input, expected) in examples {
            XCTAssertEqual(try VimCommand.parse(input), expected, input)
        }
    }

    func test_optional_colon_and_outer_whitespace_are_ignored() throws {
        for input in ["w", ":w", " \t:w \n", " : w \t", "\tw\n"] {
            XCTAssertEqual(
                try VimCommand.parse(input),
                .write(path: nil, force: false, quit: false),
                input
            )
        }
    }

    func test_file_commands_preserve_path_spaces_and_literal_shell_syntax() throws {
        let examples: [(String, VimCommand)] = [
            (" :write!  ~/My  Notes/é.txt \n",
             .write(path: "~/My  Notes/é.txt", force: true, quit: false)),
            ("wquit\t../new note.md", .write(path: "../new note.md", force: false, quit: true)),
            ("e! $HOME/$(touch file) *.txt", .edit(
                path: "$HOME/$(touch file) *.txt", force: true
            )),
            ("edit 'quoted name.txt'", .edit(path: "'quoted name.txt'", force: false)),
            ("w !filename.txt", .write(path: "!filename.txt", force: false, quit: false))
        ]
        for (input, expected) in examples {
            XCTAssertEqual(try VimCommand.parse(input), expected, input)
        }
    }

    func test_commands_without_paths_reject_trailing_arguments() {
        for command in ["wa", "wall!", "wqa", "wqall!", "q", "quit!", "qa", "qall!",
                        "x", "exit", "new"] {
            XCTAssertThrowsError(try VimCommand.parse(":" + command + " extra file")) { error in
                XCTAssertEqual(error.localizedDescription, "E488: Trailing characters: extra file")
            }
        }
    }

    func test_unknown_commands_and_unsupported_bangs_are_rejected() {
        for command in ["wri", "open", "W", "x!", "exit!", "new!", "w!!", ":w", "!"] {
            XCTAssertThrowsError(try VimCommand.parse(":" + command)) { error in
                let expected = "E492: Not an editor command: " + command
                XCTAssertEqual(error.localizedDescription, expected)
            }
        }
    }

    func test_empty_input_reports_an_empty_command() {
        for input in ["", " \t\n", ":", " : \t"] {
            XCTAssertThrowsError(try VimCommand.parse(input)) { error in
                XCTAssertEqual(error.localizedDescription, "Empty command")
            }
        }
    }
}
