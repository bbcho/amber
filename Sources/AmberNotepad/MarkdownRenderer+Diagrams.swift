import AppKit

extension NSAttributedString.Key {
    /// Marks a placeholder that still waits for its diagram, holding the Mermaid source.
    static let mermaidSource = NSAttributedString.Key("AmberMermaidSource")
}

/// A diagram image, scaled down to fit the line it sits on and never scaled up.
final class DiagramAttachment: NSTextAttachment {
    convenience init(image: NSImage) {
        self.init(data: nil, ofType: nil)
        self.image = image
    }

    override func attachmentBounds(
        for textContainer: NSTextContainer?, proposedLineFragment lineFrag: NSRect,
        glyphPosition position: NSPoint, characterIndex charIndex: Int
    ) -> NSRect {
        let natural = image?.size ?? .zero
        let scale = natural.width > 0
            ? min(1, max(lineFrag.width - position.x, 1) / natural.width) : 1
        return NSRect(x: 0, y: 0, width: natural.width * scale, height: natural.height * scale)
    }
}

extension MarkdownRenderer {
    static let renderingLabel = "rendering diagram…"

    /// What a Mermaid block shows for `outcome`, drawn with the code block's `attributes`: its
    /// code box, labeled while the diagram is pending or holding the error and the source, or
    /// the bare image once it exists.
    static func diagramText(
        source: String, outcome: MermaidOutcome?, attributes: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        switch outcome {
        case nil:
            var pending = attributes
            pending[.mermaidSource] = source
            return NSAttributedString(string: renderingLabel, attributes: pending)
        case .failure(let message)?:
            return NSAttributedString(string: "\(message)\n\(source)", attributes: attributes)
        case .image(let image)?:
            let text = NSMutableAttributedString(attachment: DiagramAttachment(image: image))
            text.addAttributes(
                imageAttributes(from: attributes), range: NSRange(location: 0, length: 1)
            )
            return text
        }
    }

    /// The code box's attributes without the box: its padding is removed from the indent, and
    /// quote bars stay.
    private static func imageAttributes(
        from attributes: [NSAttributedString.Key: Any]
    ) -> [NSAttributedString.Key: Any] {
        var image = attributes
        image[.mermaidSource] = nil
        guard let box = attributes[.markdownBlock] as? MarkdownDecoration else { return image }
        image[.markdownBlock] = box.quoteDepth > 0
            ? MarkdownDecoration(quoteDepth: box.quoteDepth, isCode: false,
                                 baseIndent: box.baseIndent)
            : nil
        if let style = (attributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy()
            as? NSMutableParagraphStyle {
            style.headIndent -= MarkdownDecoration.codePadding
            style.firstLineHeadIndent -= MarkdownDecoration.codePadding
            image[.paragraphStyle] = style
        }
        return image
    }
}
