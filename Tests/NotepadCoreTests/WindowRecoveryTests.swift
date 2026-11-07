import Foundation
import XCTest
@testable import NotepadCore

final class WindowRecoveryTests: XCTestCase {
    func test_two_windows_recover_independent_drafts() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstURL = directory.appendingPathComponent("first.json")
        let secondURL = directory.appendingPathComponent("second.json")
        let first = DocumentSession(recoveryURL: firstURL)
        let second = DocumentSession(recoveryURL: secondURL)
        first.updateText("First window")
        second.updateText("Second window")
        try first.autosave()
        try second.autosave()
        let recoveredFirst = DocumentSession(recoveryURL: firstURL)
        let recoveredSecond = DocumentSession(recoveryURL: secondURL)
        try recoveredFirst.restore()
        try recoveredSecond.restore()
        XCTAssertEqual(recoveredFirst.file.text, "First window")
        XCTAssertEqual(recoveredSecond.file.text, "Second window")
    }

    func test_closing_one_window_removes_only_its_recovery() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstURL = directory.appendingPathComponent("first.json")
        let secondURL = directory.appendingPathComponent("second.json")
        let destination = directory.appendingPathComponent("note.md")
        let first = DocumentSession(recoveryURL: firstURL)
        let second = DocumentSession(recoveryURL: secondURL)
        first.updateText("Saved text")
        second.updateText("Other draft")
        try first.save(to: destination)
        try second.autosave()
        let otherBytes = try Data(contentsOf: secondURL)
        try first.removeRecovery()
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertEqual(try Data(contentsOf: secondURL), otherBytes)
        XCTAssertEqual(try String(contentsOf: destination), "Saved text")
    }

    func test_recovered_duplicate_becomes_untitled_without_losing_text() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recovery = directory.appendingPathComponent("recovery.json")
        let destination = directory.appendingPathComponent("note.md")
        let session = DocumentSession(recoveryURL: recovery)
        session.updateText("Original")
        try session.save(to: destination)
        session.updateText("Recovered edit")
        try session.detachFromFile()
        let restored = DocumentSession(recoveryURL: recovery)
        try restored.restore()
        XCTAssertNil(restored.url)
        XCTAssertEqual(restored.file.text, "Recovered edit")
        XCTAssertTrue(restored.isDirty)
        XCTAssertEqual(try String(contentsOf: destination), "Original")
    }
}
