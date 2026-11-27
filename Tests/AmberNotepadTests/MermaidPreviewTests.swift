import AppKit
import XCTest
@testable import AmberNotepad

final class MermaidPreviewTests: XCTestCase {
    private let diagram = "```mermaid\ngraph TD\n  A[Start] --> B[End]\n```"

    func test_a_mermaid_block_first_shows_the_code_box_labeled_rendering() async {
        await MainActor.run {
            let rendered = MarkdownRenderer.render(
                "a\n\n\(diagram)\n\nafter", diagrams: MermaidRenderer()
            )
            XCTAssertEqual(rendered.string, "a\nrendering diagram…\nafter")
            let at = (rendered.string as NSString).range(of: "rendering")
            let box = rendered.attribute(.markdownBlock, at: at.location, effectiveRange: nil)
            XCTAssertEqual((box as? MarkdownDecoration)?.isCode, true)
        }
    }

    func test_the_box_is_replaced_in_place_by_an_image_when_rendering_finishes() async {
        let (terminal, window, renderer) = await MainActor.run { editor() }
        await MainActor.run {
            terminal.showMarkdown(
                MarkdownRenderer.render("a\n\n\(diagram)\n\nafter", diagrams: renderer)
            )
        }
        let done = await waitUntil { terminal.preview.string.contains("\u{FFFC}") }
        await MainActor.run {
            defer { window.contentView = nil }
            XCTAssertTrue(done, terminal.preview.string)
            XCTAssertEqual(terminal.preview.string, "a\n\u{FFFC}\nafter")
            let attachment = terminal.preview.textStorage?
                .attribute(.attachment, at: 2, effectiveRange: nil) as? NSTextAttachment
            XCTAssertNotNil(attachment?.image)
            let box = terminal.preview.textStorage?
                .attribute(.markdownBlock, at: 2, effectiveRange: nil)
            XCTAssertNil(box)
        }
    }

    func test_a_rejected_diagram_shows_mermaids_message_and_its_source_in_a_box() async {
        let (terminal, window, renderer) = await MainActor.run { editor() }
        let source = "graph TD\n  A --> --> B"
        await MainActor.run {
            terminal.showMarkdown(MarkdownRenderer.render(
                "```mermaid\n\(source)\n```\n\nafter", diagrams: renderer
            ))
        }
        let done = await waitUntil { terminal.preview.string.contains("Parse error") }
        await MainActor.run {
            defer { window.contentView = nil }
            XCTAssertTrue(done, terminal.preview.string)
            XCTAssertTrue(terminal.preview.string.hasSuffix("\(source)\nafter"))
            let box = terminal.preview.textStorage?
                .attribute(.markdownBlock, at: 0, effectiveRange: nil) as? MarkdownDecoration
            XCTAssertEqual(box?.isCode, true)
        }
    }

    func test_a_mermaid_block_opening_a_list_item_keeps_the_list_marker() async {
        await MainActor.run {
            let rendered = MarkdownRenderer.render(
                "- ```mermaid\n  graph TD\n  A-->B\n  ```\n- next", diagrams: MermaidRenderer()
            )
            XCTAssertEqual(rendered.string, "• rendering diagram…\n• next")
        }
    }

    func test_other_code_blocks_render_exactly_as_before() async {
        await MainActor.run {
            let rendered = MarkdownRenderer.render(
                "```swift\nlet x = 1\n```", diagrams: MermaidRenderer()
            )
            XCTAssertEqual(rendered.string, "let x = 1")
            XCTAssertNil(rendered.attribute(.mermaidSource, at: 0, effectiveRange: nil))
            XCTAssertEqual(
                (rendered.attribute(.markdownBlock, at: 0, effectiveRange: nil)
                    as? MarkdownDecoration)?.isCode, true
            )
        }
    }

    func test_live_reload_shows_a_cached_diagram_at_once_without_drawing_again() async {
        let (terminal, window, renderer) = await MainActor.run { editor() }
        let text = "\(diagram)\n\nafter"
        await MainActor.run {
            terminal.showMarkdown(MarkdownRenderer.render(text, diagrams: renderer))
        }
        _ = await waitUntil { terminal.preview.string.contains("\u{FFFC}") }
        await MainActor.run {
            defer { window.contentView = nil }
            terminal.updateMarkdown(MarkdownRenderer.render(text + " more", diagrams: renderer))
            XCTAssertEqual(terminal.preview.string, "\u{FFFC}\nafter more")
            XCTAssertEqual(renderer.drawCount, 1)
        }
    }

    func test_rendering_a_diagram_leaves_the_source_and_the_read_only_preview_alone() async {
        let (terminal, window, renderer) = await MainActor.run { editor() }
        let source = "a\n\n\(diagram)"
        await MainActor.run {
            terminal.textView.string = source
            terminal.showMarkdown(MarkdownRenderer.render(source, diagrams: renderer))
        }
        _ = await waitUntil { terminal.preview.string.contains("\u{FFFC}") }
        await MainActor.run {
            defer { window.contentView = nil }
            XCTAssertEqual(terminal.textView.string, source)
            XCTAssertFalse(terminal.preview.isEditable)
        }
    }

    func test_scroll_position_holds_when_a_diagram_above_the_view_finishes() async {
        let (terminal, window, renderer) = await MainActor.run { editor() }
        let filler = (1...80).map { "Paragraph \($0)" }.joined(separator: "\n\n")
        let clip = await MainActor.run { terminal.preview.enclosingScrollView!.contentView }
        await MainActor.run {
            let preview = terminal.preview
            terminal.showMarkdown(
                MarkdownRenderer.render("\(diagram)\n\n\(filler)", diagrams: renderer)
            )
            preview.sizeToFit()
            clip.scroll(to: NSPoint(x: 0, y: rect(of: "Paragraph 40", in: preview).minY - 100))
            preview.enclosingScrollView!.reflectScrolledClipView(clip)
        }
        // The last reading taken before the image arrives is the position to hold.
        var held: CGFloat = 0
        _ = await waitUntil {
            let preview = terminal.preview
            guard !preview.string.contains("\u{FFFC}") else { return true }
            held = self.rect(of: "Paragraph 40", in: preview).minY - clip.bounds.origin.y
            return false
        }
        await MainActor.run {
            defer { window.contentView = nil }
            let after = rect(of: "Paragraph 40", in: terminal.preview).minY - clip.bounds.origin.y
            XCTAssertEqual(held, 100, accuracy: 20)
            XCTAssertEqual(after, held, accuracy: 0.5)
        }
    }

    @MainActor private func rect(of needle: String, in view: NSTextView) -> NSRect {
        let layout = view.layoutManager!
        layout.ensureLayout(for: view.textContainer!)
        let range = (view.string as NSString).range(of: needle)
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        return layout.boundingRect(forGlyphRange: glyphs, in: view.textContainer!)
    }

    @MainActor private func editor() -> (TerminalView, NSWindow, MermaidRenderer) {
        _ = NSApplication.shared
        let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 1000, height: 720))
        let window = NSWindow(
            contentRect: terminal.frame, styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = terminal
        terminal.layoutSubtreeIfNeeded()
        let renderer = MermaidRenderer()
        terminal.preview.diagrams = renderer
        return (terminal, window, renderer)
    }

    private func waitUntil(
        timeout: TimeInterval = 8, _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await MainActor.run(body: condition) { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await MainActor.run(body: condition)
    }
}
