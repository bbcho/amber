import AppKit
import XCTest
@testable import AmberNotepad

final class MarkdownPreviewTests: XCTestCase {
    func test_round_trip_leaves_source_text_undo_and_position_unchanged() async {
        await MainActor.run {
            let (terminal, window) = editorWindow()
            defer { window.contentView = nil }
            let editor = terminal.textView
            editor.allowsUndo = true
            editor.string = (1...300).map { "Line \($0)" }.joined(separator: "\n")
            editor.insertText("!", replacementRange: NSRange(location: 0, length: 0))
            let source = editor.string
            editor.setMode(.insert)
            editor.setSelectedRange(NSRange(location: 500, length: 0))
            let clip = editor.enclosingScrollView!.contentView
            clip.scroll(to: NSPoint(x: 0, y: 1200))
            let origin = clip.bounds.origin
            let couldUndo = editor.undoManager?.canUndo

            terminal.showMarkdown(MarkdownRenderer.render(source))
            terminal.showSource()

            XCTAssertEqual(editor.string, source)
            XCTAssertEqual(editor.selectedRange(), NSRange(location: 500, length: 0))
            XCTAssertEqual(clip.bounds.origin, origin)
            XCTAssertEqual(editor.undoManager?.canUndo, couldUndo)
            XCTAssertTrue(window.firstResponder === editor)
            XCTAssertEqual(editor.mode, .normal)
            XCTAssertFalse(terminal.isShowingMarkdown)
        }
    }

    func test_showing_markdown_hides_editor_and_focuses_preview() async {
        await MainActor.run {
            let (terminal, window) = editorWindow()
            defer { window.contentView = nil }
            terminal.showMarkdown(MarkdownRenderer.render("# Hi"))
            XCTAssertTrue(terminal.isShowingMarkdown)
            XCTAssertEqual(terminal.textView.enclosingScrollView?.isHidden, true)
            XCTAssertEqual(terminal.preview.enclosingScrollView?.isHidden, false)
            XCTAssertTrue(window.firstResponder === terminal.preview)
            XCTAssertEqual(terminal.preview.string, "Hi")
        }
    }

    func test_preview_is_read_only_and_selectable() async {
        await MainActor.run {
            let (terminal, window) = editorWindow()
            defer { window.contentView = nil }
            XCTAssertFalse(terminal.preview.isEditable)
            XCTAssertTrue(terminal.preview.isSelectable)
        }
    }

    func test_vim_keys_scroll_the_preview() async {
        await MainActor.run {
            let (terminal, window) = editorWindow()
            defer { window.contentView = nil }
            let source = (1...300).map { "Paragraph \($0)" }.joined(separator: "\n\n")
            terminal.showMarkdown(MarkdownRenderer.render(source))
            let preview = terminal.preview
            let step = preview.lineStep
            func top() -> CGFloat { preview.visibleRect.minY }

            preview.keyDown(with: key("j"))
            XCTAssertEqual(top(), step)
            preview.keyDown(with: key("3"))
            preview.keyDown(with: key("j"))
            XCTAssertEqual(top(), step * 4)
            preview.keyDown(with: key("k"))
            XCTAssertEqual(top(), step * 3)
            preview.keyDown(with: key("G"))
            XCTAssertEqual(preview.visibleRect.maxY, preview.bounds.maxY)
            preview.keyDown(with: key("g"))
            preview.keyDown(with: key("g"))
            XCTAssertEqual(top(), 0)
            let half = (preview.visibleRect.height / 2 / step).rounded(.down) * step
            preview.keyDown(with: key("d", control: true))
            XCTAssertEqual(top(), half)
            preview.keyDown(with: key("u", control: true))
            XCTAssertEqual(top(), 0)
        }
    }

    func test_colon_in_preview_opens_command_line_and_returns_focus() async {
        await MainActor.run {
            let (terminal, window) = editorWindow()
            defer { window.contentView = nil }
            terminal.textView.setMode(.insert)
            terminal.showMarkdown(MarkdownRenderer.render("# Hi"))

            terminal.preview.keyDown(with: key(":"))
            XCTAssertFalse(terminal.commandLine.isHidden)
            guard let fieldEditor = terminal.commandLine.currentEditor() as? NSTextView else {
                XCTFail("Command entry must have a native field editor")
                return
            }
            fieldEditor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))

            XCTAssertTrue(terminal.commandLine.isHidden)
            XCTAssertTrue(window.firstResponder === terminal.preview)
            XCTAssertEqual(terminal.textView.mode, .insert)
        }
    }

    func test_preview_reflows_on_resize() async {
        await MainActor.run {
            let (terminal, window) = editorWindow()
            defer { window.contentView = nil }
            terminal.showMarkdown(MarkdownRenderer.render("A long paragraph of text"))
            terminal.frame.size.width = 600
            terminal.layout()
            XCTAssertLessThanOrEqual(terminal.preview.textContainer?.size.width ?? .infinity, 600)
            XCTAssertGreaterThan(terminal.preview.textContainer?.size.width ?? 0, 0)
        }
    }

    func test_quote_and_code_boxes_survive_following_text_in_layout() async {
        await MainActor.run {
            let (terminal, window) = editorWindow()
            defer { window.contentView = nil }
            terminal.showMarkdown(MarkdownRenderer.render(
                "a\n\n> quoted\n\n```\ncoded\n```\n\nafter"
            ))
            // Bar 3 + padding 8 for quotes; padding 6 for code boxes.
            XCTAssertEqual(layoutX(of: "quoted", in: terminal.preview), 11)
            XCTAssertEqual(layoutX(of: "coded", in: terminal.preview), 6)
            XCTAssertEqual(layoutX(of: "after", in: terminal.preview), 0)
        }
    }

    func test_quote_bar_and_code_box_are_drawn() async {
        await MainActor.run {
            let (terminal, window) = editorWindow()
            defer { window.contentView = nil }
            let preview = terminal.preview
            terminal.showMarkdown(MarkdownRenderer.render("> quoted\n\n```\ncoded\n```\n\nafter"))
            let image = preview.bitmapImageRepForCachingDisplay(in: preview.bounds)!
            preview.cacheDisplay(in: preview.bounds, to: image)
            @MainActor func pixel(leftOf needle: String, by offset: CGFloat) -> NSColor? {
                let x = layoutX(of: needle, in: preview) + preview.textContainerOrigin.x - offset
                let range = (preview.string as NSString).range(of: needle)
                let glyphs = preview.layoutManager!.glyphRange(
                    forCharacterRange: range, actualCharacterRange: nil
                )
                let y = preview.layoutManager!.boundingRect(
                    forGlyphRange: glyphs, in: preview.textContainer!
                ).midY + preview.textContainerOrigin.y
                let scale = CGFloat(image.pixelsWide) / preview.bounds.width
                return image.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB)
            }
            // The bar sits 9.5 points left of quote text; the box fills code's padding.
            XCTAssertGreaterThan(pixel(leftOf: "quoted", by: 9.5)?.alphaComponent ?? 0, 0.4)
            XCTAssertGreaterThan(pixel(leftOf: "coded", by: 3)?.alphaComponent ?? 0, 0.05)
            XCTAssertEqual(pixel(leftOf: "after", by: 3)?.alphaComponent ?? 1, 0, accuracy: 0.01)
        }
    }

    @MainActor private func layoutX(of needle: String, in view: NSTextView) -> CGFloat {
        let range = (view.string as NSString).range(of: needle)
        let layout = view.layoutManager!
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        return layout.boundingRect(forGlyphRange: glyphs, in: view.textContainer!).minX
    }

    @MainActor private func editorWindow() -> (TerminalView, NSWindow) {
        _ = NSApplication.shared
        let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 1000, height: 720))
        let window = NSWindow(
            contentRect: terminal.frame, styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = terminal
        terminal.layoutSubtreeIfNeeded()
        window.makeFirstResponder(terminal.textView)
        return (terminal, window)
    }

    @MainActor private func key(_ character: String, control: Bool = false) -> NSEvent {
        let typed = control
            ? String(UnicodeScalar(UInt8(character.unicodeScalars.first!.value & 0x1f)))
            : character
        return NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: control ? [.control] : [],
            timestamp: 0, windowNumber: 0, context: nil, characters: typed,
            charactersIgnoringModifiers: character, isARepeat: false, keyCode: 0
        )!
    }
}
