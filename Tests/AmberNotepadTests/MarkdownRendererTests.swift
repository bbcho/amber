import AppKit
import XCTest
@testable import AmberNotepad

final class MarkdownRendererTests: XCTestCase {
    func test_blocks_are_separated_by_line_breaks() async {
        await MainActor.run {
            let rendered = render("# Title\n\nBody text")
            XCTAssertEqual(rendered.string, "Title\nBody text")
        }
    }

    func test_headings_are_larger_than_body_text() async {
        await MainActor.run {
            let rendered = render("# Title\n\n## Sub\n\nBody")
            let title = font(rendered, at: "Title").pointSize
            let sub = font(rendered, at: "Sub").pointSize
            XCTAssertGreaterThan(title, sub)
            XCTAssertGreaterThan(sub, font(rendered, at: "Body").pointSize)
        }
    }

    func test_list_items_get_markers_and_nested_items_indent_further() async {
        await MainActor.run {
            let rendered = render("- one\n  - two\n\n1. three")
            XCTAssertTrue(rendered.string.contains("• one"), rendered.string)
            XCTAssertTrue(rendered.string.contains("◦ two"), rendered.string)
            XCTAssertTrue(rendered.string.contains("1. three"), rendered.string)
            XCTAssertGreaterThan(paragraph(rendered, at: "two").headIndent,
                                 paragraph(rendered, at: "one").headIndent)
        }
    }

    func test_code_blocks_are_monospaced_in_a_box() async {
        await MainActor.run {
            let rendered = render("```\nlet x = 1\n```\n\nafter")
            XCTAssertEqual(rendered.string, "let x = 1\nafter")
            XCTAssertTrue(font(rendered, at: "let x").fontDescriptor.symbolicTraits
                .contains(.monoSpace))
            XCTAssertEqual(attribute(.markdownBlock, rendered, at: "let x") as? String, "code")
            XCTAssertNil(attribute(.markdownBlock, rendered, at: "after"))
        }
    }

    func test_block_quotes_get_a_left_bar() async {
        await MainActor.run {
            let rendered = render("> quoted")
            XCTAssertEqual(attribute(.markdownBlock, rendered, at: "quoted") as? String, "quote")
            XCTAssertEqual(paragraph(rendered, at: "quoted").headIndent, 11)
        }
    }

    func test_thematic_break_draws_a_rule() async {
        await MainActor.run {
            let rendered = render("a\n\n---\n\nb")
            XCTAssertEqual(rendered.string, "a\n" + String(repeating: "─", count: 40) + "\nb")
        }
    }

    func test_table_cells_are_tab_separated_rows() async {
        await MainActor.run {
            let rendered = render("| a | b |\n|---|---|\n| 1 | 2 |")
            XCTAssertEqual(rendered.string, "a\tb\n1\t2")
            XCTAssertTrue(font(rendered, at: "a").fontDescriptor.symbolicTraits.contains(.bold))
            XCTAssertFalse(font(rendered, at: "1").fontDescriptor.symbolicTraits.contains(.bold))
        }
    }

    func test_inline_styles() async {
        await MainActor.run {
            let rendered = render("*em* **strong** ~~gone~~ `code`")
            XCTAssertTrue(font(rendered, at: "em").fontDescriptor.symbolicTraits.contains(.italic))
            XCTAssertTrue(font(rendered, at: "strong").fontDescriptor.symbolicTraits
                .contains(.bold))
            XCTAssertNotNil(attribute(.strikethroughStyle, rendered, at: "gone"))
            XCTAssertTrue(font(rendered, at: "code").fontDescriptor.symbolicTraits
                .contains(.monoSpace))
        }
    }

    func test_links_are_styled_not_clickable() async {
        await MainActor.run {
            let rendered = render("[site](https://example.com)")
            XCTAssertEqual(rendered.string, "site")
            XCTAssertNotNil(attribute(.underlineStyle, rendered, at: "site"))
            XCTAssertNil(attribute(.link, rendered, at: "site"))
        }
    }

    func test_malformed_and_empty_input_still_render() async {
        await MainActor.run {
            XCTAssertEqual(render("**unclosed").string, "**unclosed")
            XCTAssertEqual(render("").string, "")
        }
    }

    func test_deep_nesting_caps_indent() async {
        await MainActor.run {
            let source = (0..<40)
                .map { String(repeating: "  ", count: $0) + "- level\($0)" }
                .joined(separator: "\n")
            let rendered = render(source)
            XCTAssertTrue(rendered.string.contains("level39"))
            var maximum: CGFloat = 0
            rendered.enumerateAttribute(
                .paragraphStyle, in: NSRange(location: 0, length: rendered.length)
            ) { value, _, _ in
                maximum = max(maximum, (value as? NSParagraphStyle)?.headIndent ?? 0)
            }
            XCTAssertLessThanOrEqual(maximum, 240)
        }
    }

    // MARK: - Helpers

    @MainActor private func render(_ source: String) -> NSAttributedString {
        let rendered = MarkdownRenderer.render(source)
        assertAmberOnly(rendered, source)
        return rendered
    }

    @MainActor private func assertAmberOnly(_ text: NSAttributedString, _ source: String) {
        text.enumerateAttribute(
            .foregroundColor, in: NSRange(location: 0, length: text.length)
        ) { value, range, _ in
            let color = value as? NSColor
            XCTAssertTrue(color == Phosphor.amber || color == Phosphor.bar,
                          "non-amber color at \(range) for \(source.debugDescription)")
        }
    }

    private func location(_ text: NSAttributedString, of needle: String) -> Int {
        let range = (text.string as NSString).range(of: needle)
        XCTAssertNotEqual(range.location, NSNotFound, "missing \(needle)")
        return range.location == NSNotFound ? 0 : range.location
    }

    private func attribute(
        _ key: NSAttributedString.Key, _ text: NSAttributedString, at needle: String
    ) -> Any? {
        text.attribute(key, at: location(text, of: needle), effectiveRange: nil)
    }

    private func font(_ text: NSAttributedString, at needle: String) -> NSFont {
        attribute(.font, text, at: needle) as? NSFont ?? NSFont.systemFont(ofSize: 1)
    }

    private func paragraph(_ text: NSAttributedString, at needle: String) -> NSParagraphStyle {
        attribute(.paragraphStyle, text, at: needle) as? NSParagraphStyle ?? .default
    }
}
