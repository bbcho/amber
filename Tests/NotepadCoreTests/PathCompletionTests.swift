import Foundation
import XCTest
@testable import NotepadCore

final class PathCompletionTests: XCTestCase {
    var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let manager = FileManager.default
        try manager.createDirectory(
            at: directory.appendingPathComponent("notes"), withIntermediateDirectories: true
        )
        for name in ["alpha.md", "alps.md", "beta.md", "Capital.md", ".hidden.md",
                     "notes/inner.md", "notes/.secret.md"] {
            try Data().write(to: directory.appendingPathComponent(name))
        }
        try manager.createSymbolicLink(
            at: directory.appendingPathComponent("linked"),
            withDestinationURL: directory.appendingPathComponent("notes")
        )
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func complete(_ input: String, recent: [URL] = []) -> [String] {
        PathCompletion.candidates(for: input, relativeTo: directory, recent: recent)
    }

    func test_matching_files_are_offered_in_order() {
        XCTAssertEqual(complete(":e al"), [":e alpha.md", ":e alps.md"])
        XCTAssertEqual(complete("w! be"), ["w! beta.md"])
    }

    func test_folders_end_with_a_slash_and_can_be_entered() {
        XCTAssertEqual(complete(":e no"), [":e notes/"])
        XCTAssertEqual(complete(":e notes/"), [":e notes/inner.md"])
    }

    func test_hidden_files_appear_only_for_a_dot_prefix() {
        XCTAssertEqual(complete(":e notes/"), [":e notes/inner.md"])
        XCTAssertEqual(complete(":e notes/.s"), [":e notes/.secret.md"])
        XCTAssertEqual(complete(":e .h"), [":e .hidden.md"])
    }

    func test_matching_ignores_case_like_the_mac_file_system() {
        XCTAssertEqual(complete(":e cap"), [":e Capital.md"])
    }

    func test_a_symlinked_folder_ends_with_a_slash() {
        XCTAssertEqual(complete(":e lin"), [":e linked/"])
    }

    func test_every_path_command_completes_and_others_do_not() {
        for command in ["e", "edit", "e!", "w", "write", "wq", "wquit", "wq!"] {
            XCTAssertEqual(complete(":\(command) bet"), [":\(command) beta.md"], command)
        }
        XCTAssertEqual(complete(":q bet"), [])
        XCTAssertEqual(complete(":new bet"), [])
    }

    func test_an_absolute_path_keeps_its_folder() {
        let input = ":e " + directory.path + "/al"
        XCTAssertEqual(complete(input), [input + "pha.md", input + "ps.md"])
    }

    func test_a_tilde_is_kept() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let first = (try? FileManager.default.contentsOfDirectory(atPath: home.path))?
            .filter { !$0.hasPrefix(".") }.sorted().first
        guard let first else { throw XCTSkip("Home folder has no visible entries") }
        let prefix = String(first.prefix(1))
        let completed = complete(":e ~/" + prefix)
        XCTAssertFalse(completed.isEmpty)
        XCTAssertTrue(completed.allSatisfy { $0.hasPrefix(":e ~/") })
    }

    func test_an_empty_path_offers_recent_files() {
        let recent = [URL(fileURLWithPath: "/notes/a.md"), URL(fileURLWithPath: "/notes/b.md")]
        XCTAssertEqual(complete(":e ", recent: recent), [":e /notes/a.md", ":e /notes/b.md"])
        XCTAssertEqual(complete(":e", recent: recent), [":e /notes/a.md", ":e /notes/b.md"])
    }
}
