import AppKit

/// Read-only display of rendered Markdown, scrolled with Vim-style keys.
@MainActor
final class MarkdownPreviewView: NSTextView {
    var commandRequested: (() -> Void)?
    private var count = ""
    private var awaitingSecondG = false

    /// Built on an explicit TextKit 1 stack so block decorations can use the layout manager.
    convenience init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(
            size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        )
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        self.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = true
        drawsBackground = false
        textContainerInset = NSSize(width: 8, height: 8)
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        minSize = .zero
        maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude
        )
        selectedTextAttributes = [
            .backgroundColor: Phosphor.amber.withAlphaComponent(0.28),
            .foregroundColor: Phosphor.bar
        ]
        setAccessibilityLabel("Rendered Markdown")
    }

    override func draw(_ dirtyRect: NSRect) {
        drawBlockDecorations()
        super.draw(dirtyRect)
    }

    /// Quote bars and code boxes sit in the indent `MarkdownBlock.indent` leaves for them.
    private func drawBlockDecorations() {
        guard let storage = textStorage, let layout = layoutManager else { return }
        let origin = textContainerOrigin
        storage.enumerateAttribute(
            .markdownBlock, in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            guard let raw = value as? String, let block = MarkdownBlock(rawValue: raw) else {
                return
            }
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var area = NSRect.null
            layout.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in
                area = area.union(rect)
            }
            guard !area.isNull else { return }
            let style = storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
            let textStart = (style as? NSParagraphStyle)?.headIndent ?? block.indent
            let left = origin.x + textStart - block.indent
            switch block {
            case .quote:
                Phosphor.amber.withAlphaComponent(0.6).setFill()
                NSRect(x: left, y: area.minY + origin.y, width: 3, height: area.height).fill()
            case .code:
                Phosphor.amber.withAlphaComponent(0.08).setFill()
                NSRect(x: left, y: area.minY + origin.y, width: area.maxX + origin.x - left,
                       height: area.height).fill()
            }
        }
    }

    var lineStep: CGFloat {
        (layoutManager?.defaultLineHeight(for: MarkdownRenderer.bodyFont) ?? 16) + 3
    }

    override func keyDown(with event: NSEvent) {
        let key = event.charactersIgnoringModifiers ?? ""
        let flags = event.modifierFlags
        let isNavigationKey = event.specialKey != nil && !flags.contains(.control)
        if flags.contains(.command) || flags.contains(.option) || isNavigationKey {
            super.keyDown(with: event)
            return
        }
        if !flags.contains(.control), key.count == 1, let digit = key.first, digit.isNumber,
           digit != "0" || !count.isEmpty {
            if count.count < 4 { count += key }
            return
        }
        let repetitions = Int(count) ?? 1
        let explicitCount = Int(count)
        count = ""
        if awaitingSecondG {
            awaitingSecondG = false
            if key == "g" { scroll(toY: 0) }
            return
        }
        if flags.contains(.control) {
            let halfPage = max(Int(visibleRect.height / 2 / lineStep), 1)
            switch key {
            case "d": scroll(lines: explicitCount ?? halfPage)
            case "u": scroll(lines: -(explicitCount ?? halfPage))
            default: super.keyDown(with: event)
            }
            return
        }
        switch key {
        case "j": scroll(lines: repetitions)
        case "k": scroll(lines: -repetitions)
        case "g": awaitingSecondG = true
        case "G": scroll(toY: .greatestFiniteMagnitude)
        case ":": commandRequested?()
        default: break
        }
    }

    func scroll(lines: Int) {
        guard let clip = enclosingScrollView?.contentView else { return }
        scroll(toY: clip.bounds.origin.y + CGFloat(lines) * lineStep)
    }

    private func scroll(toY y: CGFloat) {
        guard let scrollView = enclosingScrollView else { return }
        let clip = scrollView.contentView
        let bottom = max(bounds.height - clip.bounds.height, 0)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: min(max(y, 0), bottom)))
        scrollView.reflectScrolledClipView(clip)
    }
}
