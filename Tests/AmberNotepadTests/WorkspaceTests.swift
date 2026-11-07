import AppKit
import Foundation
import NotepadCore
import XCTest
@testable import AmberNotepad

final class WorkspaceTests: XCTestCase {
    func test_quit_refusal_keeps_each_independent_draft_intact() async throws {
        try await MainActor.run {
            let (app, directory) = try workspace()
            defer { cleanup(app, directory) }
            let first = try app.createWindow()
            let second = try app.createWindow()
            first.terminal.textView.insertText(
                "First draft", replacementRange: NSRange(location: 0, length: 0)
            )
            second.terminal.textView.insertText(
                "Second draft", replacementRange: NSRange(location: 0, length: 0)
            )
            app.execute(":q", in: first)
            XCTAssertEqual(app.editors.count, 2)
            XCTAssertEqual(first.terminal.textView.string, "First draft")
            XCTAssertEqual(second.terminal.textView.string, "Second draft")
            XCTAssertTrue(first.window.isVisible)
            XCTAssertTrue(first.terminal.status.stringValue.contains("E37:"))
        }
    }

    func test_write_quit_saves_and_closes_only_the_current_window() async throws {
        try await MainActor.run {
            let (app, directory) = try workspace()
            defer { cleanup(app, directory) }
            let first = try app.createWindow()
            let second = try app.createWindow()
            first.terminal.textView.insertText(
                "Save this", replacementRange: NSRange(location: 0, length: 0)
            )
            let destination = directory.appendingPathComponent("one note.md")
            app.execute(":wq " + destination.path, in: first)
            XCTAssertEqual(try String(contentsOf: destination), "Save this")
            XCTAssertEqual(app.editors.count, 1)
            XCTAssertTrue(app.editors[0] === second)
            XCTAssertFalse(first.window.isVisible)
            XCTAssertEqual(second.terminal.textView.string, "")
        }
    }

    func test_opening_a_symlink_or_hardlink_focuses_the_existing_owner() async throws {
        try await MainActor.run {
            let (app, directory) = try workspace()
            defer { cleanup(app, directory) }
            let destination = directory.appendingPathComponent("original.md")
            let symbolic = directory.appendingPathComponent("symbolic.md")
            let hard = directory.appendingPathComponent("hard.md")
            try Data("Original".utf8).write(to: destination)
            try FileManager.default.createSymbolicLink(
                at: symbolic, withDestinationURL: destination
            )
            try FileManager.default.linkItem(at: destination, to: hard)
            let first = try app.createWindow(fileURL: destination)
            let throughSymlink = try app.createWindow(fileURL: symbolic)
            let throughHardlink = try app.createWindow(fileURL: hard)
            XCTAssertTrue(first === throughSymlink)
            XCTAssertTrue(first === throughHardlink)
            XCTAssertEqual(app.editors.count, 1)
        }
    }

    func test_forced_write_and_edit_cannot_claim_another_windows_file() async throws {
        try await MainActor.run {
            let (app, directory) = try workspace()
            defer { cleanup(app, directory) }
            let destination = directory.appendingPathComponent("original.md")
            try Data("Keep original".utf8).write(to: destination)
            let owner = try app.createWindow(fileURL: destination)
            let second = try app.createWindow()
            second.terminal.textView.insertText(
                "Other draft", replacementRange: NSRange(location: 0, length: 0)
            )
            app.execute(":w! " + destination.path, in: second)
            XCTAssertNil(second.documentURL)
            XCTAssertEqual(try String(contentsOf: destination), "Keep original")
            XCTAssertTrue(second.terminal.status.stringValue.contains("E95:"))
            app.execute(":e! " + destination.path, in: second)
            XCTAssertEqual(second.terminal.textView.string, "Other draft")
            XCTAssertEqual(owner.terminal.textView.string, "Keep original")
            XCTAssertNil(second.documentURL)
            XCTAssertTrue(second.terminal.status.stringValue.contains("E95:"))
        }
    }

    func test_write_all_failure_keeps_every_window_open() async throws {
        try await MainActor.run {
            let (app, directory) = try workspace()
            defer { cleanup(app, directory) }
            let firstURL = directory.appendingPathComponent("first.md")
            let missingDirectory = directory.appendingPathComponent("removed")
            try FileManager.default.createDirectory(at: missingDirectory,
                                                    withIntermediateDirectories: true)
            let secondURL = missingDirectory.appendingPathComponent("second.md")
            try Data("One".utf8).write(to: firstURL)
            try Data("Two".utf8).write(to: secondURL)
            let first = try app.createWindow(fileURL: firstURL)
            let second = try app.createWindow(fileURL: secondURL)
            first.terminal.textView.insertText(
                "!", replacementRange: NSRange(location: 3, length: 0)
            )
            second.terminal.textView.insertText(
                "!", replacementRange: NSRange(location: 3, length: 0)
            )
            try FileManager.default.removeItem(at: missingDirectory)
            app.execute(":wqa!", in: first)
            XCTAssertEqual(app.editors.count, 2)
            XCTAssertTrue(first.window.isVisible)
            XCTAssertTrue(second.window.isVisible)
            XCTAssertEqual(try String(contentsOf: firstURL), "One!")
            XCTAssertEqual(second.terminal.textView.string, "Two!")
            XCTAssertTrue(second.hasUnsavedChanges)
        }
    }

    func test_write_all_saves_both_documents_before_closing_all_windows() async throws {
        try await MainActor.run {
            let (app, directory) = try workspace()
            defer { cleanup(app, directory) }
            let firstURL = directory.appendingPathComponent("first.md")
            let secondURL = directory.appendingPathComponent("second.md")
            try Data("One".utf8).write(to: firstURL)
            try Data("Two".utf8).write(to: secondURL)
            let first = try app.createWindow(fileURL: firstURL)
            let second = try app.createWindow(fileURL: secondURL)
            first.terminal.textView.insertText(
                "!", replacementRange: NSRange(location: 3, length: 0)
            )
            second.terminal.textView.insertText(
                "!", replacementRange: NSRange(location: 3, length: 0)
            )
            app.execute(":wqa", in: first)
            XCTAssertEqual(try String(contentsOf: firstURL), "One!")
            XCTAssertEqual(try String(contentsOf: secondURL), "Two!")
            XCTAssertTrue(app.editors.isEmpty)
            XCTAssertFalse(first.window.isVisible)
            XCTAssertFalse(second.window.isVisible)
        }
    }

    func test_application_quit_restores_all_drafts_and_legacy_recovery() async throws {
        try await MainActor.run {
            let (app, directory) = try workspace()
            defer { cleanup(app, directory) }
            let legacy = directory.appendingPathComponent("Recovery.json")
            let prior = DocumentSession(recoveryURL: legacy)
            prior.updateText("Legacy draft")
            try prior.autosave()
            try app.restoreWindows()
            let second = try app.createWindow()
            second.terminal.textView.insertText(
                "New draft", replacementRange: NSRange(location: 0, length: 0)
            )
            XCTAssertEqual(app.editors.count, 2)
            for editor in app.editors { XCTAssertTrue(editor.prepareForApplicationQuit()) }
            for editor in app.editors { editor.window.close() }
            let restarted = AppDelegate(recoveryURL: legacy)
            defer { for editor in restarted.editors { editor.window.close() } }
            try restarted.restoreWindows()
            let texts = restarted.editors.map { $0.terminal.textView.string }.sorted()
            XCTAssertEqual(texts, ["Legacy draft", "New draft"])
            XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
        }
    }

    func test_quit_refuses_a_named_buffer_with_pending_edits() async throws {
        try await MainActor.run {
            let (app, directory) = try workspace()
            defer { cleanup(app, directory) }
            let destination = directory.appendingPathComponent("named.md")
            try Data("Original".utf8).write(to: destination)
            let editor = try app.createWindow(fileURL: destination)
            editor.terminal.textView.insertText(
                "!", replacementRange: NSRange(location: 8, length: 0)
            )
            app.execute(":q", in: editor)
            XCTAssertTrue(editor.window.isVisible)
            XCTAssertTrue(editor.hasUnsavedChanges)
            XCTAssertEqual(editor.terminal.textView.string, "Original!")
            XCTAssertEqual(try String(contentsOf: destination), "Original")
            XCTAssertTrue(editor.terminal.status.stringValue.contains("E37:"))
        }
    }

    func test_duplicate_recovered_files_preserve_both_edits_with_one_file_owner() async throws {
        try await MainActor.run {
            let (app, directory) = try workspace()
            defer { cleanup(app, directory) }
            let destination = directory.appendingPathComponent("named.md")
            try Data("Original".utf8).write(to: destination)
            let legacy = DocumentSession(
                recoveryURL: directory.appendingPathComponent("Recovery.json")
            )
            let other = DocumentSession(
                recoveryURL: directory.appendingPathComponent("Drafts/other.json")
            )
            try legacy.open(destination)
            try other.open(destination)
            legacy.updateText("Legacy edit")
            other.updateText("Other edit")
            try Data("External edit".utf8).write(to: destination)
            XCTAssertThrowsError(try legacy.autosave())
            XCTAssertThrowsError(try other.autosave())
            try app.restoreWindows()
            XCTAssertEqual(app.editors.map { $0.terminal.textView.string }.sorted(),
                           ["Legacy edit", "Other edit"])
            XCTAssertEqual(app.editors.compactMap { $0.documentURL }.count, 1)
            XCTAssertEqual(try String(contentsOf: destination), "External edit")
        }
    }

    @MainActor private func workspace() throws -> (AppDelegate, URL) {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let app = AppDelegate(recoveryURL: directory.appendingPathComponent("Recovery.json"))
        return (app, directory)
    }

    @MainActor private func cleanup(_ app: AppDelegate, _ directory: URL) {
        for editor in app.editors { editor.window.close() }
        try? FileManager.default.removeItem(at: directory)
    }
}
