import Foundation
import XCTest
@testable import NotepadCore

final class DocumentTests: XCTestCase {
    var directory: URL!
    var recovery: URL { directory.appendingPathComponent("draft.json") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func test_unicode_and_line_endings_round_trip_in_every_encoding() throws {
        for text in ["", "# Hello\r\nCafé 👩🏽‍💻\r\n", "中文\n\tالعربية\rfin"] {
            for encoding in [TextFile.Encoding.utf8, .utf8BOM, .utf16LE, .utf16BE] {
                let original = TextFile(text: text, encoding: encoding)
                let bytes = try original.encoded()
                let decoded = try TextFile.decode(bytes)
                XCTAssertEqual(decoded.text, text)
                XCTAssertEqual(decoded.encoding, encoding)
                XCTAssertEqual(try decoded.encoded(), bytes)
            }
        }
    }

    func test_invalid_input_is_rejected_instead_of_replaced() {
        XCTAssertThrowsError(try TextFile.decode(Data([0xFF, 0xFE, 0x00])))
        XCTAssertThrowsError(try TextFile.decode(Data([0x80, 0x81])))
        XCTAssertThrowsError(try TextFile.decode(Data([0x00, 0x00, 0x01])))
    }

    func test_untitled_autosave_recovers_text_without_creating_a_user_file() throws {
        let session = DocumentSession(recoveryURL: recovery)
        session.updateText("# A draft\nStill here 📝")
        try session.autosave()
        let restarted = DocumentSession(recoveryURL: recovery)
        try restarted.restore()
        XCTAssertEqual(restarted.file.text, "# A draft\nStill here 📝")
        XCTAssertNil(restarted.url)
        XCTAssertTrue(restarted.isDirty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path),
                       ["draft.json"])
    }

    func test_named_autosave_updates_the_chosen_file() throws {
        let destination = directory.appendingPathComponent("note.md")
        let session = DocumentSession(recoveryURL: recovery)
        session.updateText("First")
        try session.save(to: destination)
        session.updateText("Second\r\n")
        try session.autosave()
        XCTAssertEqual(try String(contentsOf: destination), "Second\r\n")
        XCTAssertFalse(session.isDirty)
        let restarted = DocumentSession(recoveryURL: recovery)
        try restarted.restore()
        XCTAssertEqual(restarted.url, destination)
        XCTAssertEqual(restarted.file.text, "Second\r\n")
    }

    func test_external_edit_blocks_autosave_and_preserves_recovery() throws {
        let destination = directory.appendingPathComponent("note.txt")
        try Data("Original".utf8).write(to: destination)
        let session = DocumentSession(recoveryURL: recovery)
        try session.open(destination)
        session.updateText("My edit")
        try Data("Other app".utf8).write(to: destination)
        XCTAssertThrowsError(try session.autosave())
        XCTAssertEqual(try String(contentsOf: destination), "Other app")
        let restarted = DocumentSession(recoveryURL: recovery)
        try restarted.restore()
        XCTAssertEqual(restarted.file.text, "My edit")
        XCTAssertThrowsError(try restarted.autosave())
        try restarted.save(to: destination, overwrite: true)
        XCTAssertEqual(try String(contentsOf: destination), "My edit")
    }

    func test_deleted_original_is_not_silently_recreated() throws {
        let destination = directory.appendingPathComponent("note.txt")
        try Data("Original".utf8).write(to: destination)
        let session = DocumentSession(recoveryURL: recovery)
        try session.open(destination)
        session.updateText("My edit")
        try FileManager.default.removeItem(at: destination)
        XCTAssertThrowsError(try session.autosave())
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func test_failed_save_as_does_not_change_document_identity() throws {
        let session = DocumentSession(recoveryURL: recovery)
        session.updateText("Keep me")
        let unavailable = directory.appendingPathComponent("missing/note.md")
        XCTAssertThrowsError(try session.save(to: unavailable))
        XCTAssertNil(session.url)
        XCTAssertTrue(session.isDirty)
        let restarted = DocumentSession(recoveryURL: recovery)
        try restarted.restore()
        XCTAssertEqual(restarted.file.text, "Keep me")
    }

    func test_failed_open_leaves_current_document_intact() throws {
        let session = DocumentSession(recoveryURL: recovery)
        session.updateText("Keep editing")
        XCTAssertThrowsError(try session.open(directory.appendingPathComponent("missing.md")))
        XCTAssertEqual(session.file.text, "Keep editing")
    }

    func test_save_as_does_not_alter_original_file() throws {
        let first = directory.appendingPathComponent("one.md")
        let second = directory.appendingPathComponent("two.txt")
        let session = DocumentSession(recoveryURL: recovery)
        session.updateText("First")
        try session.save(to: first)
        session.updateText("Second")
        try session.save(to: second)
        XCTAssertEqual(try String(contentsOf: first), "First")
        XCTAssertEqual(try String(contentsOf: second), "Second")
        XCTAssertEqual(session.url, second)
    }

    func test_reset_clears_recovery_without_deleting_user_file() throws {
        let destination = directory.appendingPathComponent("note.txt")
        let session = DocumentSession(recoveryURL: recovery)
        session.updateText("Keep file")
        try session.save(to: destination)
        try session.reset()
        let restarted = DocumentSession(recoveryURL: recovery)
        try restarted.restore()
        XCTAssertEqual(restarted.file.text, "")
        XCTAssertNil(restarted.url)
        XCTAssertEqual(try String(contentsOf: destination), "Keep file")
    }
}
