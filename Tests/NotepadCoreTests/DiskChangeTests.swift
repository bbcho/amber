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

    func test_waiting_for_quiet_reloads_only_once_a_change_holds_still() throws {
        let session = try session()
        try Data("half".utf8).write(to: note, options: .atomic)
        XCTAssertEqual(try session.checkDisk(waitForQuiet: true), .unchanged)
        try Data("half written".utf8).write(to: note, options: .atomic)
        XCTAssertEqual(try session.checkDisk(waitForQuiet: true), .unchanged)
        XCTAssertEqual(session.file.text, "first")
        XCTAssertEqual(try session.checkDisk(waitForQuiet: true), .reloaded)
        XCTAssertEqual(session.file.text, "half written")
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
        let recovery = try Data(contentsOf: directory.appendingPathComponent("draft.json"))
        let snapshot = try JSONSerialization.jsonObject(with: recovery) as? [String: Any]
        let file = snapshot?["file"] as? [String: Any]
        XCTAssertEqual(file?["text"] as? String, "changed")
    }

    func test_an_unreadable_change_is_reported_once_not_on_every_check() throws {
        let session = try session()
        try Data([0xFF, 0xFE, 0x00, 0xD8]).write(to: note, options: .atomic)
        XCTAssertThrowsError(try session.checkDisk())
        XCTAssertEqual(try session.checkDisk(), .unchanged)
        XCTAssertEqual(session.file.text, "first")
    }

    func test_a_replacement_with_the_same_size_and_date_is_still_detected() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: note.path)
        let session = try session()
        try Data("FIRST".utf8).write(to: note, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: note.path)
        XCTAssertEqual(try session.checkDisk(), .reloaded)
        XCTAssertEqual(session.file.text, "FIRST")
    }
}
