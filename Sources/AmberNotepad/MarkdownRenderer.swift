import AppKit

/// What the rendered view draws behind one quote or code block: a bar for each quote level,
/// then a box for code. Each block gets its own instance, so neighbouring blocks stay apart.
final class MarkdownDecoration: NSObject {
    static let quoteStep: CGFloat = 11
    static let codePadding: CGFloat = 6

    let quoteDepth: Int
    let isCode: Bool
    /// Indent of the lists around the block, where its first bar starts.
    let baseIndent: CGFloat

    init(quoteDepth: Int, isCode: Bool, baseIndent: CGFloat) {
        self.quoteDepth = quoteDepth
        self.isCode = isCode
        self.baseIndent = baseIndent
    }

    /// Where the decorated text starts, past the bars and the code box padding.
    var contentIndent: CGFloat {
        CGFloat(quoteDepth) * Self.quoteStep + (isCode ? Self.codePadding : 0)
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
    private static let columnGap: CGFloat = 24
    private static let rule = String(repeating: "─", count: 40)

    static func render(_ source: String) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let parsed = try? AttributedString(markdown: source, options: options) else {
            return NSAttributedString(
                string: source, attributes: attributes(for: [], run: nil, decoration: nil)
            )
        }
        var renderer = Renderer()
        for run in parsed.runs {
            renderer.append(String(parsed[run.range].characters), run: run)
        }
        return renderer.finish()
    }

    /// Foundation reports each run's enclosing blocks innermost first, but inserts no line
    /// breaks between blocks, no list markers, and nothing for empty table cells, so those
    /// are rebuilt here.
    @MainActor private struct Renderer {
        private struct Table {
            var range: NSRange
            var cellWidths: [Int: [Int: CGFloat]] = [:]
        }

        private let output = NSMutableAttributedString()
        private var previousBlocks: [PresentationIntent.IntentType] = []
        private var markedItems = Set<Int>()
        private var decorations: [Int: MarkdownDecoration] = [:]
        private var tables: [Int: Table] = [:]

        mutating func append(_ runText: String, run: AttributedString.Runs.Run) {
            let blocks = run.presentationIntent?.components ?? []
            let isNewBlock = blocks.first?.identity != previousBlocks.first?.identity
                || output.length == 0
            let decoration = decoration(for: blocks)
            var styled = MarkdownRenderer.attributes(for: blocks, run: run, decoration: decoration)
            if run.link != nil { styled[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if isNewBlock { appendSeparator(before: blocks, attributes: styled) }
            var text = runText
            switch blocks.first?.kind {
            case .thematicBreak: text = MarkdownRenderer.rule
            case .codeBlock: if text.hasSuffix("\n") { text.removeLast() }
            default: break
            }
            if isNewBlock { text = marker(for: blocks) + text }
            let piece = NSAttributedString(string: text, attributes: styled)
            output.append(piece)
            recordTableCell(blocks, width: piece.size().width)
            previousBlocks = blocks
        }

        /// Applies each table's column tab stops, sized to fit its widest cells.
        func finish() -> NSAttributedString {
            for table in tables.values {
                var columns: [Int: CGFloat] = [:]
                for row in table.cellWidths.values {
                    for (column, width) in row {
                        columns[column] = max(columns[column] ?? 0, width)
                    }
                }
                var location: CGFloat = 0
                let stops = (0..<(columns.keys.max() ?? 0)).map { column -> NSTextTab in
                    location += ceil(columns[column] ?? 0) + MarkdownRenderer.columnGap
                    return NSTextTab(textAlignment: .left, location: location)
                }
                output.enumerateAttribute(.paragraphStyle, in: table.range) { value, range, _ in
                    guard let style = (value as? NSParagraphStyle)?.mutableCopy()
                        as? NSMutableParagraphStyle else { return }
                    style.tabStops = stops
                    output.addAttribute(.paragraphStyle, value: style, range: range)
                }
            }
            return output
        }

        private func appendSeparator(
            before blocks: [PresentationIntent.IntentType],
            attributes: [NSAttributedString.Key: Any]
        ) {
            let column = cell(of: blocks)?.column ?? 0
            let previousColumn = cell(of: previousBlocks)?.column ?? 0
            if output.length > 0 {
                let previous = output.attributes(at: output.length - 1, effectiveRange: nil)
                if let row = cell(of: blocks)?.row, row == cell(of: previousBlocks)?.row {
                    let tabs = String(repeating: "\t", count: max(column - previousColumn, 1))
                    output.append(NSAttributedString(string: tabs, attributes: previous))
                    return
                }
                output.append(NSAttributedString(string: "\n", attributes: previous))
            }
            if column > 0 {
                let tabs = String(repeating: "\t", count: column)
                output.append(NSAttributedString(string: tabs, attributes: attributes))
            }
        }

        private func cell(of blocks: [PresentationIntent.IntentType]) -> (row: Int, column: Int)? {
            guard case let .tableCell(column)? = blocks.first?.kind,
                  let row = blocks.first(where: { component in
                      switch component.kind {
                      case .tableHeaderRow, .tableRow: return true
                      default: return false
                      }
                  }) else { return nil }
            return (row.identity, column)
        }

        private mutating func recordTableCell(
            _ blocks: [PresentationIntent.IntentType], width: CGFloat
        ) {
            guard let cell = cell(of: blocks),
                  let table = blocks.first(where: {
                      if case .table = $0.kind { return true } else { return false }
                  }) else { return }
            var entry = tables[table.identity]
                ?? Table(range: NSRange(location: output.length, length: 0))
            let lineStart = (output.string as NSString)
                .lineRange(for: NSRange(location: output.length - 1, length: 0)).location
            let start = min(entry.range.location, lineStart)
            entry.range = NSRange(location: start, length: output.length - start)
            entry.cellWidths[cell.row, default: [:]][cell.column, default: 0] += width
            tables[table.identity] = entry
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

        private mutating func decoration(
            for blocks: [PresentationIntent.IntentType]
        ) -> MarkdownDecoration? {
            let decorated = blocks.indices.filter { index in
                switch blocks[index].kind {
                case .codeBlock, .blockQuote: return true
                default: return false
                }
            }
            guard let innermost = decorated.first, let outermost = decorated.last else {
                return nil
            }
            if let existing = decorations[blocks[innermost].identity] { return existing }
            let quoteDepth = decorated.filter { index in
                if case .blockQuote = blocks[index].kind { return true } else { return false }
            }.count
            let isCode: Bool
            if case .codeBlock = blocks[innermost].kind { isCode = true } else { isCode = false }
            let outside = Array(blocks[(outermost + 1)...])
            let made = MarkdownDecoration(
                quoteDepth: quoteDepth, isCode: isCode,
                baseIndent: min(CGFloat(MarkdownRenderer.listDepth(outside))
                    * MarkdownRenderer.indentStep, MarkdownRenderer.maximumIndent)
            )
            decorations[blocks[innermost].identity] = made
            return made
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
        for blocks: [PresentationIntent.IntentType], run: AttributedString.Runs.Run?,
        decoration: MarkdownDecoration?
    ) -> [NSAttributedString.Key: Any] {
        var font = bodyFont
        var isHeading = false
        var color = Phosphor.amber
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 6
        for component in blocks {
            switch component.kind {
            case let .header(level):
                font = .boldSystemFont(ofSize: headingSizes[min(max(level, 1), 6) - 1])
                isHeading = true
                color = Phosphor.bar
            case .codeBlock:
                font = Phosphor.font
            case .tableHeaderRow:
                font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            default:
                break
            }
        }
        let indent = min(
            CGFloat(listDepth(blocks)) * indentStep + (decoration?.contentIndent ?? 0),
            maximumIndent
        )
        paragraph.headIndent = indent
        paragraph.firstLineHeadIndent = indent
        var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]
        if let inline = run?.inlinePresentationIntent {
            if inline.contains(.code) {
                font = isHeading
                    ? .monospacedSystemFont(ofSize: font.pointSize, weight: .bold)
                    : Phosphor.font
            }
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
        attributes[.markdownBlock] = decoration
        attributes[.paragraphStyle] = paragraph
        return attributes
    }
}
