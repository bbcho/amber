import Foundation
import XCTest
@testable import NotepadCore

final class DiskChangeTests: XCTestCase {
    var directory: URL!
    var note: URL { directory.appendingPathComponent("note.md") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("first".utf8).write(to: note)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func session() throws -> DocumentSession {
        let session = DocumentSession(recoveryURL: directory.appendingPathComponent("draft.json"))
        try session.open(note)
        return session
    }

    func test_an_untouched_file_is_unchanged() throws {
        XCTAssertEqual(try session().checkDisk(), .unchanged)
    }

    func test_an_outside_change_reloads_a_clean_document() throws {
        let session = try session()
        try Data("changed by an agent".utf8).write(to: note, options: .atomic)
        XCTAssertEqual(try session.checkDisk(), .reloaded)
        XCTAssertEqual(session.file.text, "changed by an agent")
        XCTAssertFalse(session.isDirty)
        XCTAssertEqual(try session.checkDisk(), .unchanged)
    }

    func test_an_outside_change_never_replaces_unsaved_edits() throws {
        let session = try session()
        session.updateText("my unsaved edit")
        try Data("changed by an agent".utf8).write(to: note, options: .atomic)
        XCTAssertEqual(try session.checkDisk(), .conflict)
        XCTAssertEqual(session.file.text, "my unsaved edit")
        XCTAssertEqual(try String(contentsOf: note), "changed by an agent")
    }

    func test_amber_saving_its_own_file_is_not_an_outside_change() throws {
        let session = try session()
        session.updateText("saved by Amber")
        try session.autosave()
        XCTAssertEqual(try session.checkDisk(), .unchanged)
        XCTAssertEqual(session.file.text, "saved by Amber")
    }

    func test_a_deleted_file_keeps_the_text_and_reports_missing() throws {
        let session = try session()
        try FileManager.default.removeItem(at: note)
        XCTAssertEqual(try session.checkDisk(), .missing)
        XCTAssertEqual(session.file.text, "first")
    }

    func test_an_untitled_document_has_no_file_to_check() throws {
        let session = DocumentSession(recoveryURL: directory.appendingPathComponent("draft.json"))
        session.updateText("draft")
        XCTAssertEqual(try session.checkDisk(), .unchanged)
    }

    func test_a_reload_updates_recovery() throws {
        let session = try session()
        try Data("changed".utf8).write(to: note, options: .atomic)
        _ = try session.checkDisk()
        let restored = DocumentSession(recoveryURL: directory.appendingPathComponent("draft.json"))
        try restored.restore()
        XCTAssertEqual(restored.file.text, "changed")
    }
}
