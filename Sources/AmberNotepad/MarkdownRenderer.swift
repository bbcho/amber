import AppKit

/// Turns Markdown source into amber-styled, read-only display text.
@MainActor
enum MarkdownRenderer {
    private static let bodyFont = NSFont.systemFont(ofSize: 13)
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
        private var textBlocks: [Int: NSTextBlock] = [:]

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
            if let style = styled[.paragraphStyle] as? NSMutableParagraphStyle {
                style.textBlocks = textBlock(for: blocks).map { [$0] } ?? []
            }
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

        private mutating func textBlock(
            for blocks: [PresentationIntent.IntentType]
        ) -> NSTextBlock? {
            for component in blocks {
                let block: NSTextBlock
                switch component.kind {
                case .codeBlock:
                    block = textBlocks[component.identity] ?? NSTextBlock()
                    block.backgroundColor = Phosphor.amber.withAlphaComponent(0.08)
                    block.setWidth(6, type: .absoluteValueType, for: .padding)
                case .blockQuote:
                    block = textBlocks[component.identity] ?? NSTextBlock()
                    block.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
                    block.setBorderColor(Phosphor.amber.withAlphaComponent(0.6), for: .minX)
                    block.setWidth(8, type: .absoluteValueType, for: .padding, edge: .minX)
                default:
                    continue
                }
                textBlocks[component.identity] = block
                return block
            }
            return nil
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
        attributes[.paragraphStyle] = paragraph
        return attributes
    }
}
