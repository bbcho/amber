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
        usesFindBar = true
        isIncrementalSearchingEnabled = true
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

    // The window's undo manager holds the hidden source's edits. Handling undo and redo here
    // stops Command-Z in the rendered view from changing, and autosaving, the source.
    @objc func undo(_ sender: Any?) {}
    @objc func redo(_ sender: Any?) {}

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) || item.action == #selector(redo(_:)) {
            return false
        }
        return super.validateUserInterfaceItem(item)
    }

    override func draw(_ dirtyRect: NSRect) {
        drawBlockDecorations(in: dirtyRect)
        super.draw(dirtyRect)
    }

    /// Quote bars and code boxes sit in the indent `MarkdownDecoration` leaves for them.
    private func drawBlockDecorations(in dirtyRect: NSRect) {
        guard let storage = textStorage, let layout = layoutManager,
              let container = textContainer else { return }
        let origin = textContainerOrigin
        let dirtyGlyphs = layout.glyphRange(
            forBoundingRect: dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y), in: container
        )
        let dirtyCharacters = layout.characterRange(
            forGlyphRange: dirtyGlyphs, actualGlyphRange: nil
        )
        storage.enumerateAttribute(.markdownBlock, in: dirtyCharacters) { value, range, _ in
            guard let decoration = value as? MarkdownDecoration else { return }
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var used = NSRect.null
            var right: CGFloat = 0
            layout.enumerateLineFragments(forGlyphRange: glyphs) { rect, usedRect, _, _, _ in
                used = used.union(usedRect)
                right = max(right, rect.maxX)
            }
            guard !used.isNull else { return }
            let left = origin.x + decoration.baseIndent
            let top = used.minY + origin.y
            Phosphor.amber.withAlphaComponent(0.6).setFill()
            for level in 0..<decoration.quoteDepth {
                let x = left + CGFloat(level) * MarkdownDecoration.quoteStep
                NSRect(x: x, y: top, width: 3, height: used.height).fill()
            }
            if decoration.isCode {
                let boxLeft = left + CGFloat(decoration.quoteDepth) * MarkdownDecoration.quoteStep
                Phosphor.amber.withAlphaComponent(0.08).setFill()
                NSRect(x: boxLeft, y: top, width: origin.x + right - boxLeft,
                       height: used.height).fill()
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
