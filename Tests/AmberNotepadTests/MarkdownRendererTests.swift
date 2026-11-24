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
            XCTAssertEqual(decoration(rendered, at: "let x")?.isCode, true)
            XCTAssertEqual(decoration(rendered, at: "let x")?.quoteDepth, 0)
            XCTAssertNil(decoration(rendered, at: "after"))
        }
    }

    func test_block_quotes_get_a_left_bar() async {
        await MainActor.run {
            let rendered = render("> quoted")
            XCTAssertEqual(decoration(rendered, at: "quoted")?.quoteDepth, 1)
            XCTAssertEqual(decoration(rendered, at: "quoted")?.isCode, false)
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
            XCTAssertEqual(maximum, 240)
        }
    }

    func test_nested_quotes_and_code_inside_quotes_keep_every_bar() async {
        await MainActor.run {
            let nested = render("> outer\n>\n> > inner")
            XCTAssertEqual(decoration(nested, at: "inner")?.quoteDepth, 2)
            XCTAssertEqual(paragraph(nested, at: "inner").headIndent, 22)
            let code = render("> ```\n> coded\n> ```")
            XCTAssertEqual(decoration(code, at: "coded")?.isCode, true)
            XCTAssertEqual(decoration(code, at: "coded")?.quoteDepth, 1)
            XCTAssertEqual(paragraph(code, at: "coded").headIndent, 17)
        }
    }

    func test_each_block_gets_its_own_decoration() async {
        await MainActor.run {
            let rendered = render("```\nfirst\n```\n\n```\nsecond\n```")
            let first = decoration(rendered, at: "first")
            XCTAssertNotNil(first)
            XCTAssertFalse(first === decoration(rendered, at: "second"))
        }
    }

    func test_quote_bar_stays_at_the_quote_edge_around_lists() async {
        await MainActor.run {
            let quoted = render("> - item\n>\n> para")
            XCTAssertTrue(decoration(quoted, at: "item") === decoration(quoted, at: "para"))
            XCTAssertEqual(decoration(quoted, at: "item")?.baseIndent, 0)
            let listed = render("- item\n\n  > inside")
            XCTAssertEqual(decoration(listed, at: "inside")?.baseIndent, 20)
        }
    }

    func test_inline_code_in_a_heading_keeps_the_heading_size() async {
        await MainActor.run {
            let rendered = render("# Use `code` here")
            let code = font(rendered, at: "code")
            XCTAssertEqual(code.pointSize, font(rendered, at: "Use").pointSize)
            XCTAssertTrue(code.fontDescriptor.symbolicTraits.contains(.monoSpace))
        }
    }

    func test_table_columns_fit_their_widest_cell() async {
        await MainActor.run {
            let long = "a cell much wider than one hundred and sixty points of text"
            let rendered = render("| a | b |\n|---|---|\n| \(long) | x |")
            let width = NSAttributedString(
                string: long, attributes: [.font: MarkdownRenderer.bodyFont]
            ).size().width
            let stops = paragraph(rendered, at: "x").tabStops
            XCTAssertEqual(stops.first?.location, ceil(width) + 24)
            XCTAssertEqual(paragraph(rendered, at: "b").tabStops.first?.location,
                           stops.first?.location)
        }
    }

    func test_empty_table_cells_keep_columns_aligned() async {
        await MainActor.run {
            let rendered = render("| a | b | c |\n|---|---|---|\n|  | 2 | 3 |\n| 1 |  | 3 |")
            XCTAssertEqual(rendered.string, "a\tb\tc\n\t2\t3\n1\t\t3")
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

    private func decoration(
        _ text: NSAttributedString, at needle: String
    ) -> MarkdownDecoration? {
        attribute(.markdownBlock, text, at: needle) as? MarkdownDecoration
    }

    private func font(_ text: NSAttributedString, at needle: String) -> NSFont {
        attribute(.font, text, at: needle) as? NSFont ?? NSFont.systemFont(ofSize: 1)
    }

    private func paragraph(_ text: NSAttributedString, at needle: String) -> NSParagraphStyle {
        attribute(.paragraphStyle, text, at: needle) as? NSParagraphStyle ?? .default
    }
}
