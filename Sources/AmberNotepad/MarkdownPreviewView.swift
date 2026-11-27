import AppKit
import NotepadCore

/// Read-only display of rendered Markdown, scrolled with Vim-style keys.
@MainActor
final class MarkdownPreviewView: NSTextView {
    var commandRequested: (() -> Void)?
    var diagrams = MermaidRenderer.shared
    private var vim = VimWindowState()
    private var session = VimSession()

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

    /// Scroll keys go through the engine, which parses counts, `gg`, `G`, Control-D/U and the
    /// rest. The engine sees the view as a window over one empty line per row of text, with
    /// its cursor on the top row, so every move is measured in the rows `j` scrolls by;
    /// whatever the engine does to the cursor or the top row becomes a scroll, and nothing else.
    override func keyDown(with event: NSEvent) {
        let isNavigationKey = event.specialKey != nil && !event.modifierFlags.contains(.control)
        guard !isNavigationKey else { return super.keyDown(with: event) }
        switch event.vimInput {
        case .shortcut, .optionChord:
            super.keyDown(with: event)
        case .unmapped:
            break
        case .key(let key):
            if key == VimKey(.character(":")) {
                vim = VimWindowState()
                commandRequested?()
            } else {
                scroll(with: key)
            }
        }
    }

    private func scroll(with key: VimKey) {
        let rows = max(Int(bounds.height / lineStep), 1)
        let page = max(Int(visibleRect.height / lineStep), 1)
        let buffer = VimBuffer(NSString(string: String(repeating: "\n", count: rows)))
        let top = min(Int(visibleRect.minY / lineStep), rows - 1)
        vim.cursor = buffer.lineRange(at: top).location
        let screen = ScreenGeometry(
            firstVisibleLine: top, lastVisibleLine: min(top + page - 1, rows - 1),
            linesPerPage: page, moveScreenLines: { offset, _ in offset }
        )
        let result = VimEngine.handle(key, window: vim, session: session, buffer: buffer,
                                      screen: screen, clipboard: { nil })
        guard result.edits.isEmpty, result.window.mode == .normal else {
            vim = VimWindowState()
            return
        }
        vim = result.window
        session = result.session
        let row = buffer.lineIndex(of: vim.cursor)
        var lines = row - top
        var requested = false
        for case .scroll(let request) in result.effects {
            requested = true
            switch request {
            case .top(let target): lines = target - top
            case .center(let target): lines = target - page / 2 - top
            case .bottom(let target): lines = target - (page - 1) - top
            }
        }
        if requested || lines == 0 {
            scroll(lines: lines)
        } else if row == 0 {
            scroll(toY: 0)
        } else if row == rows - 1 {
            scroll(toY: .greatestFiniteMagnitude)
        } else {
            scroll(lines: lines)
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
