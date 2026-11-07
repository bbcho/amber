import AppKit
import XCTest
@testable import AmberNotepad

final class CommandBarTests: XCTestCase {
    func test_colon_in_normal_mode_opens_command_entry_without_changing_document() async {
        await MainActor.run {
            let (terminal, window) = editorWindow()
            defer { window.contentView = nil }
            terminal.textView.string = "hello world"
            terminal.textView.setSelectedRange(NSRange(location: 3, length: 0))

            terminal.textView.keyDown(with: key(":"))

            XCTAssertFalse(terminal.commandLine.isHidden)
            XCTAssertTrue(terminal.status.isHidden)
            XCTAssertEqual(terminal.commandLine.stringValue, ":")
            XCTAssertTrue(window.firstResponder === terminal.commandLine.currentEditor())
            XCTAssertEqual(terminal.textView.string, "hello world")
            XCTAssertEqual(terminal.textView.selectedRange(), NSRange(location: 3, length: 0))
        }
    }

    func test_colon_in_insert_mode_is_document_text() async {
        await MainActor.run {
            let (terminal, window) = editorWindow()
            defer { window.contentView = nil }
            terminal.textView.string = "hello"
            terminal.textView.setSelectedRange(NSRange(location: 5, length: 0))
            terminal.textView.setMode(.insert)

            terminal.textView.keyDown(with: key(":"))

            XCTAssertEqual(terminal.textView.string, "hello:")
            XCTAssertEqual(terminal.textView.mode, .insert)
            XCTAssertTrue(terminal.commandLine.isHidden)
            XCTAssertFalse(terminal.status.isHidden)
        }
    }

    func test_colon_in_visual_mode_preserves_selection_without_command_entry() async {
        await MainActor.run {
            let view = TerminalTextView(frame: .zero)
            view.string = "hello"
            view.setSelectedRange(NSRange(location: 0, length: 0))
            view.keyDown(with: key("v"))
            var requests = 0
            view.commandRequested = { requests += 1 }

            view.keyDown(with: key(":"))

            XCTAssertEqual(requests, 0)
            XCTAssertEqual(view.string, "hello")
            XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: 1))
            XCTAssertEqual(view.mode, .visual)
        }
    }

    func test_escape_cancels_command_entry_and_restores_document_focus() async {
        await MainActor.run {
            let (terminal, window) = editorWindow()
            defer { window.contentView = nil }
            terminal.textView.string = "hello world"
            terminal.textView.setSelectedRange(NSRange(location: 3, length: 0))
            var commands: [String] = []
            terminal.commandSubmitted = { commands.append($0) }
            terminal.beginCommand()
            guard let fieldEditor = terminal.commandLine.currentEditor() as? NSTextView else {
                XCTFail("Command entry must have a native field editor")
                return
            }
            fieldEditor.string = ":wq"

            fieldEditor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))

            XCTAssertEqual(commands, [])
            XCTAssertTrue(terminal.commandLine.isHidden)
            XCTAssertFalse(terminal.status.isHidden)
            XCTAssertTrue(window.firstResponder === terminal.textView)
            XCTAssertEqual(terminal.textView.string, "hello world")
            XCTAssertEqual(terminal.textView.selectedRange(), NSRange(location: 3, length: 0))
            XCTAssertEqual(terminal.textView.mode, .normal)
        }
    }

    func test_enter_submits_once_after_restoring_document_focus() async {
        await MainActor.run {
            let (terminal, window) = editorWindow()
            defer { window.contentView = nil }
            terminal.textView.string = "hello world"
            terminal.textView.setSelectedRange(NSRange(location: 3, length: 0))
            var commands: [String] = []
            terminal.commandSubmitted = { command in
                XCTAssertTrue(terminal.commandLine.isHidden)
                XCTAssertFalse(terminal.status.isHidden)
                XCTAssertTrue(window.firstResponder === terminal.textView)
                commands.append(command)
            }
            terminal.beginCommand()
            guard let fieldEditor = terminal.commandLine.currentEditor() as? NSTextView else {
                XCTFail("Command entry must have a native field editor")
                return
            }
            fieldEditor.string = ":wq"

            fieldEditor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            fieldEditor.doCommand(by: #selector(NSResponder.insertNewline(_:)))

            XCTAssertEqual(commands, [":wq"])
            XCTAssertEqual(terminal.textView.string, "hello world")
            XCTAssertEqual(terminal.textView.selectedRange(), NSRange(location: 3, length: 0))
            XCTAssertEqual(terminal.textView.mode, .normal)
        }
    }

    func test_enter_on_empty_command_cancels_without_submitting() async {
        await MainActor.run {
            let (terminal, window) = editorWindow()
            defer { window.contentView = nil }
            var commands: [String] = []
            terminal.commandSubmitted = { commands.append($0) }
            terminal.beginCommand()
            guard let fieldEditor = terminal.commandLine.currentEditor() as? NSTextView else {
                XCTFail("Command entry must have a native field editor")
                return
            }

            fieldEditor.doCommand(by: #selector(NSResponder.insertNewline(_:)))

            XCTAssertEqual(commands, [])
            XCTAssertTrue(terminal.commandLine.isHidden)
            XCTAssertTrue(window.firstResponder === terminal.textView)
        }
    }

    @MainActor private func editorWindow() -> (TerminalView, NSWindow) {
        _ = NSApplication.shared
        let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        let window = NSWindow(
            contentRect: terminal.frame, styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = terminal
        terminal.layoutSubtreeIfNeeded()
        window.makeFirstResponder(terminal.textView)
        return (terminal, window)
    }

    @MainActor private func key(_ character: String) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: character,
            charactersIgnoringModifiers: character, isARepeat: false, keyCode: 0
        )!
    }
}
