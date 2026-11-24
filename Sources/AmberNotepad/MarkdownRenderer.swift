import AppKit

/// Block decorations the rendered view draws behind the text, under `.markdownBlock`.
enum MarkdownBlock: String {
    case quote, code

    /// How far the block's text is indented past its surroundings.
    var indent: CGFloat {
        switch self {
        case .quote: return 11
        case .code: return 6
        }
    }
}

extension NSAttributedString.Key {
    static let markdownBlock = NSAttributedString.Key("AmberMarkdownBlock")
}

/// Turns Markdown source into amber-styled, read-only display text.
@MainActor
enum MarkdownRenderer {
    static let bodyFont = NSFont.systemFont(ofSize: 13)
    private static let headingSizes: [CGFloat] = [24, 20, 17, 15, 13, 13]
    private static let indentStep: CGFloat = 20
    private static let maximumIndent: CGFloat = 240
    private static let rule = String(repeating: "─", count: 40)

    static func render(_ source: String) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let parsed = try? AttributedString(markdown: source, options: options) else {
            return NSAttributedString(string: source, attributes: attributes(for: [], run: nil))
        }
        var renderer = Renderer()
        for run in parsed.runs {
            renderer.append(String(parsed[run.range].characters), run: run)
        }
        return renderer.output
    }

    /// Foundation reports each run's enclosing blocks innermost first, but inserts no line
    /// breaks between blocks and no list markers, so both are rebuilt here.
    @MainActor private struct Renderer {
        let output = NSMutableAttributedString()
        private var previousBlocks: [PresentationIntent.IntentType] = []
        private var markedItems = Set<Int>()

        mutating func append(_ runText: String, run: AttributedString.Runs.Run) {
            let blocks = run.presentationIntent?.components ?? []
            let isNewBlock = blocks.first?.identity != previousBlocks.first?.identity
                || output.length == 0
            if isNewBlock, output.length > 0 {
                let sameRow = row(of: blocks) != nil && row(of: blocks) == row(of: previousBlocks)
                let breakAttributes = output.attributes(at: output.length - 1, effectiveRange: nil)
                output.append(NSAttributedString(
                    string: sameRow ? "\t" : "\n", attributes: breakAttributes
                ))
            }
            var text = runText
            switch blocks.first?.kind {
            case .thematicBreak: text = MarkdownRenderer.rule
            case .codeBlock: if text.hasSuffix("\n") { text.removeLast() }
            default: break
            }
            if isNewBlock { text = marker(for: blocks) + text }
            var styled = MarkdownRenderer.attributes(for: blocks, run: run)
            if run.link != nil { styled[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            output.append(NSAttributedString(string: text, attributes: styled))
            previousBlocks = blocks
        }

        private func row(of blocks: [PresentationIntent.IntentType]) -> Int? {
            blocks.first { component in
                switch component.kind {
                case .tableHeaderRow, .tableRow: return true
                default: return false
                }
            }?.identity
        }

        private mutating func marker(for blocks: [PresentationIntent.IntentType]) -> String {
            guard let itemIndex = blocks.firstIndex(where: {
                if case .listItem = $0.kind { return true } else { return false }
            }), markedItems.insert(blocks[itemIndex].identity).inserted,
                  case let .listItem(ordinal) = blocks[itemIndex].kind else { return "" }
            let list = blocks.indices.contains(itemIndex + 1) ? blocks[itemIndex + 1].kind : nil
            if case .orderedList = list { return "\(ordinal). " }
            return MarkdownRenderer.listDepth(blocks) % 2 == 1 ? "• " : "◦ "
        }
    }

    private static func listDepth(_ blocks: [PresentationIntent.IntentType]) -> Int {
        blocks.filter { component in
            switch component.kind {
            case .orderedList, .unorderedList: return true
            default: return false
            }
        }.count
    }

    private static func attributes(
        for blocks: [PresentationIntent.IntentType], run: AttributedString.Runs.Run?
    ) -> [NSAttributedString.Key: Any] {
        var font = bodyFont
        var decoration: MarkdownBlock?
        var color = Phosphor.amber
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 6
        for component in blocks {
            switch component.kind {
            case let .header(level):
                font = .boldSystemFont(ofSize: headingSizes[min(max(level, 1), 6) - 1])
                color = Phosphor.bar
            case .codeBlock:
                font = Phosphor.font
                decoration = .code
            case .blockQuote:
                decoration = decoration ?? .quote
            case .tableHeaderRow:
                font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            case let .table(columns):
                paragraph.tabStops = columns.indices.map {
                    NSTextTab(textAlignment: .left, location: CGFloat($0 + 1) * 160)
                }
            default:
                break
            }
        }
        let indent = min(CGFloat(listDepth(blocks)) * indentStep, maximumIndent)
            + (decoration?.indent ?? 0)
        paragraph.headIndent = indent
        paragraph.firstLineHeadIndent = indent
        var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]
        if let inline = run?.inlinePresentationIntent {
            if inline.contains(.code) { font = Phosphor.font }
            if inline.contains(.emphasized) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            if inline.contains(.stronglyEmphasized) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }
            if inline.contains(.strikethrough) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
        }
        attributes[.font] = font
        attributes[.markdownBlock] = decoration?.rawValue
        attributes[.paragraphStyle] = paragraph
        return attributes
    }
}
