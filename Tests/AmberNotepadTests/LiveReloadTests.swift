import AppKit
import Foundation
import NotepadCore
import XCTest
@testable import AmberNotepad

final class LiveReloadTests: XCTestCase {
    func test_outside_change_reloads_keeping_cursor_line_and_column() async throws {
        try await MainActor.run {
            let (app, directory, file) = try workspace("one\ntwo\nthree")
            defer { cleanup(app, directory) }
            let editor = try app.createWindow(fileURL: file)
            editor.terminal.textView.setSelectedRange(NSRange(location: 6, length: 0))

            try "ONE\nTWO\nTHREE\nFOUR".write(to: file, atomically: true, encoding: .utf8)
            editor.checkDisk()

            XCTAssertEqual(editor.terminal.textView.string, "ONE\nTWO\nTHREE\nFOUR")
            let selection = editor.terminal.textView.selectedRange()
            XCTAssertEqual(selection, NSRange(location: 6, length: 0))
            XCTAssertFalse(editor.hasUnsavedChanges)
            XCTAssertEqual(editor.terminal.textView.undoManager?.canUndo, true)
            XCTAssertTrue(editor.terminal.status.stringValue.contains("Reloaded"))
        }
    }

    func test_outside_change_never_replaces_unsaved_edits() async throws {
        try await MainActor.run {
            let (app, directory, file) = try workspace("original")
            defer { cleanup(app, directory) }
            let editor = try app.createWindow(fileURL: file)
            editor.terminal.textView.insertText(
                "mine ", replacementRange: NSRange(location: 0, length: 0)
            )

            try "from an agent".write(to: file, atomically: true, encoding: .utf8)
            editor.checkDisk()

            XCTAssertEqual(editor.terminal.textView.string, "mine original")
            XCTAssertTrue(editor.terminal.status.stringValue.contains("changed outside"))
            XCTAssertEqual(try String(contentsOf: file), "from an agent")
        }
    }

    func test_reload_re_renders_the_preview_and_returns_safely() async throws {
        try await MainActor.run {
            let (app, directory, file) = try workspace("# A much longer old heading")
            defer { cleanup(app, directory) }
            let editor = try app.createWindow(fileURL: file)
            let end = (editor.terminal.textView.string as NSString).length
            editor.terminal.textView.setSelectedRange(NSRange(location: end, length: 0))
            editor.toggleMarkdown()

            try "# New".write(to: file, atomically: true, encoding: .utf8)
            editor.checkDisk()
            XCTAssertEqual(editor.terminal.preview.string, "New")

            editor.toggleMarkdown()
            XCTAssertEqual(editor.terminal.textView.string, "# New")
            let selection = editor.terminal.textView.selectedRange()
            XCTAssertEqual(selection, NSRange(location: 5, length: 0))
        }
    }

    func test_checktime_checks_every_window_now() async throws {
        try await MainActor.run {
            let (app, directory, file) = try workspace("before")
            defer { cleanup(app, directory) }
            let editor = try app.createWindow(fileURL: file)
            try "after".write(to: file, atomically: true, encoding: .utf8)
            app.execute(":checktime", in: try app.createWindow())
            XCTAssertEqual(editor.terminal.textView.string, "after")
        }
    }

    func test_background_changes_appear_within_a_second() async throws {
        try await MainActor.run {
            let (app, directory, file) = try workspace("before")
            defer { cleanup(app, directory) }
            let editor = try app.createWindow(fileURL: file)
            try "after".write(to: file, atomically: true, encoding: .utf8)
            let deadline = Date().addingTimeInterval(1.5)
            while editor.terminal.textView.string != "after", Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            XCTAssertEqual(editor.terminal.textView.string, "after")
        }
    }

    func test_undoing_a_reload_never_writes_over_the_outside_change() async throws {
        try await MainActor.run {
            let (app, directory, file) = try workspace("mine")
            defer { cleanup(app, directory) }
            let editor = try app.createWindow(fileURL: file)
            let undo = try XCTUnwrap(editor.terminal.textView.undoManager)
            try "from an agent".write(to: file, atomically: true, encoding: .utf8)
            editor.checkDisk()

            undo.undo()
            wait(seconds: 0.9)
            XCTAssertEqual(editor.terminal.textView.string, "mine")
            XCTAssertEqual(try String(contentsOf: file), "from an agent")
            XCTAssertTrue(editor.hasUnsavedChanges)
            XCTAssertTrue(editor.terminal.status.stringValue.contains("⌘S"))

            undo.redo()
            wait(seconds: 0.9)
            XCTAssertEqual(editor.terminal.textView.string, "from an agent")
            XCTAssertFalse(editor.hasUnsavedChanges)

            undo.undo()
            app.execute(":w", in: editor)
            XCTAssertEqual(try String(contentsOf: file), "mine")
        }
    }

    func test_opening_another_file_ends_the_undo_hold() async throws {
        try await MainActor.run {
            let (app, directory, file) = try workspace("mine")
            defer { cleanup(app, directory) }
            let other = directory.appendingPathComponent("other.md").resolvingSymlinksInPath()
            try "other".write(to: other, atomically: true, encoding: .utf8)
            let editor = try app.createWindow(fileURL: file)
            try "from an agent".write(to: file, atomically: true, encoding: .utf8)
            editor.checkDisk()
            editor.terminal.textView.undoManager?.undo()
            app.execute(":e! " + other.path, in: editor)
            editor.terminal.textView.insertText(
                "typed ", replacementRange: NSRange(location: 0, length: 0)
            )
            wait(seconds: 0.9)
            XCTAssertEqual(try String(contentsOf: other), "typed other")
        }
    }

    func test_a_reload_stays_clean_after_the_autosave_delay() async throws {
        try await MainActor.run {
            let (app, directory, file) = try workspace("before")
            defer { cleanup(app, directory) }
            let editor = try app.createWindow(fileURL: file)
            try "after".write(to: file, atomically: true, encoding: .utf8)
            editor.checkDisk()
            wait(seconds: 0.9)
            XCTAssertFalse(editor.hasUnsavedChanges)
            XCTAssertEqual(try String(contentsOf: file), "after")
            XCTAssertTrue(editor.terminal.status.stringValue.contains("Reloaded"))
        }
    }

    func test_a_reload_leaves_visual_mode() async throws {
        try await MainActor.run {
            let (app, directory, file) = try workspace("one two three")
            defer { cleanup(app, directory) }
            let editor = try app.createWindow(fileURL: file)
            editor.terminal.textView.keyDown(with: key("v"))
            XCTAssertEqual(editor.terminal.textView.mode, .visual)
            try "short".write(to: file, atomically: true, encoding: .utf8)
            editor.checkDisk()
            XCTAssertEqual(editor.terminal.textView.mode, .normal)
            XCTAssertEqual(editor.terminal.textView.selectedRange().length, 0)
        }
    }

    func test_a_cursor_on_the_last_line_follows_appended_text() async throws {
        try await MainActor.run {
            let lines = (1...300).map { "line \($0)" }
            let (app, directory, file) = try workspace(lines.joined(separator: "\n"))
            defer { cleanup(app, directory) }
            let editor = try app.createWindow(fileURL: file)
            let view = editor.terminal.textView
            view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
            view.scrollRangeToVisible(view.selectedRange())

            let grown = lines + (301...350).map { "line \($0)" }
            try grown.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
            editor.checkDisk()

            let lastLine = (view.string as NSString).range(of: "line 350")
            XCTAssertEqual(view.selectedRange().location, NSMaxRange(lastLine))
            XCTAssertEqual(view.visibleRect.maxY, view.bounds.maxY)
        }
    }

    func test_follow_works_when_the_file_ends_with_a_line_break() async throws {
        try await MainActor.run {
            let lines = (1...300).map { "line \($0)\n" }
            let (app, directory, file) = try workspace(lines.joined())
            defer { cleanup(app, directory) }
            let editor = try app.createWindow(fileURL: file)
            let view = editor.terminal.textView
            let lastText = (view.string as NSString).range(of: "line 300")
            view.setSelectedRange(NSRange(location: lastText.location, length: 0))
            view.scrollRangeToVisible(view.selectedRange())

            let grown = lines + (301...350).map { "line \($0)\n" }
            try grown.joined().write(to: file, atomically: true, encoding: .utf8)
            editor.checkDisk()

            let newLast = (view.string as NSString).range(of: "line 350")
            XCTAssertEqual(view.selectedRange().location, newLast.location)
            XCTAssertEqual(view.visibleRect.maxY, view.bounds.maxY)
        }
    }

    func test_a_cursor_on_the_last_line_does_not_follow_while_scrolled_away() async throws {
        try await MainActor.run {
            let lines = (1...300).map { "line \($0)" }
            let (app, directory, file) = try workspace(lines.joined(separator: "\n"))
            defer { cleanup(app, directory) }
            let editor = try app.createWindow(fileURL: file)
            let view = editor.terminal.textView
            let end = (view.string as NSString).length
            view.setSelectedRange(NSRange(location: end, length: 0))
            view.scrollRangeToVisible(NSRange(location: 0, length: 0))
            let top = view.visibleRect.minY

            let grown = lines + ["line 301"]
            try grown.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
            editor.checkDisk()

            XCTAssertEqual(view.visibleRect.minY, top)
            XCTAssertLessThan(top, 100)
            let line300 = (view.string as NSString).range(of: "line 300\n")
            XCTAssertEqual(view.selectedRange().location, line300.location + 8)
        }
    }

    func test_a_rendered_view_at_the_bottom_stays_at_the_bottom() async throws {
        try await MainActor.run {
            let paragraphs = (1...80).map { "Paragraph \($0)" }
            let (app, directory, file) = try workspace(paragraphs.joined(separator: "\n\n"))
            defer { cleanup(app, directory) }
            let editor = try app.createWindow(fileURL: file)
            editor.toggleMarkdown()
            let preview = editor.terminal.preview
            preview.keyDown(with: key("G"))
            XCTAssertEqual(preview.visibleRect.maxY, preview.bounds.maxY)

            let grown = paragraphs + (81...120).map { "Paragraph \($0)" }
            try grown.joined(separator: "\n\n").write(to: file, atomically: true, encoding: .utf8)
            editor.checkDisk()

            XCTAssertTrue(preview.string.hasSuffix("Paragraph 120"))
            preview.layoutManager?.ensureLayout(for: preview.textContainer!)
            preview.sizeToFit()
            XCTAssertEqual(preview.visibleRect.maxY, preview.bounds.maxY)
        }
    }

    @MainActor private func wait(seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    @MainActor private func key(_ character: String) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                         windowNumber: 0, context: nil, characters: character,
                         charactersIgnoringModifiers: character, isARepeat: false, keyCode: 0)!
    }

    @MainActor private func workspace(_ text: String) throws -> (AppDelegate, URL, URL) {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("note.md")
        try text.write(to: file, atomically: true, encoding: .utf8)
        let app = AppDelegate(recoveryURL: directory.appendingPathComponent("Recovery.json"))
        return (app, directory, file.resolvingSymlinksInPath())
    }

    @MainActor private func cleanup(_ app: AppDelegate, _ directory: URL) {
        for editor in app.editors { editor.window.close() }
        try? FileManager.default.removeItem(at: directory)
    }
}
