import AppKit
import NotepadCore

/// The view's side of scrolling: the geometry the engine reads, scroll requests, and keeping
/// the cursor on screen with the smallest scroll.
extension TerminalTextView {
    var linePitch: CGFloat {
        max((layoutManager?.defaultLineHeight(for: Phosphor.font) ?? 14)
            + (defaultParagraphStyle?.lineSpacing ?? 0), 1)
    }

    private var screenRows: Int {
        let rows = visibleRect.height / linePitch
        return rows.isFinite ? Int(min(max(rows, 1), 100_000)) : 1
    }

    func screenGeometry(_ buffer: VimBuffer) -> ScreenGeometry {
        let (first, last) = visibleLines(buffer)
        return ScreenGeometry(
            firstVisibleLine: first, lastVisibleLine: last,
            linesPerPage: screenRows,
            moveScreenLines: { [weak self] offset, delta in
                self?.moveScreenLines(offset, by: delta) ?? offset
            }
        )
    }

    /// The first and last logical lines that show completely.
    private func visibleLines(_ buffer: VimBuffer) -> (Int, Int) {
        let all = (0, buffer.lineCount - 1)
        guard let layout = layoutManager, let container = textContainer, buffer.length > 0,
              visibleRect.height > 0 else { return all }
        let origin = textContainerOrigin
        let area = visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = layout.glyphRange(forBoundingRect: area, in: container)
        var first: Int?
        var last: Int?
        layout.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, range, _ in
            guard rect.minY >= area.minY - 0.5, rect.maxY <= area.maxY + 0.5 else { return }
            let line = buffer.lineIndex(of: layout.characterIndexForGlyph(at: range.location))
            first = first ?? line
            last = line
        }
        return (first ?? all.0, last ?? all.1)
    }

    private func moveScreenLines(_ offset: Int, by delta: Int) -> Int {
        guard let layout = layoutManager, let container = textContainer,
              layout.numberOfGlyphs > 0 else { return offset }
        layout.ensureLayout(for: container)
        var glyph = layout.glyphIndexForCharacter(at: min(offset, layout.numberOfGlyphs - 1))
        var range = NSRange()
        var rect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &range)
        let x = rect.minX + layout.location(forGlyphAt: glyph).x
        for _ in 0..<abs(delta) {
            let next = delta > 0 ? NSMaxRange(range) : range.location - 1
            guard next >= 0, next < layout.numberOfGlyphs else { break }
            rect = layout.lineFragmentRect(forGlyphAt: next, effectiveRange: &range)
        }
        glyph = layout.glyphIndex(for: NSPoint(x: x, y: rect.midY), in: container)
        return layout.characterIndexForGlyph(at: glyph)
    }

    // MARK: Scrolling

    func scroll(_ request: ScrollRequest) {
        guard let clip = enclosingScrollView?.contentView else { return }
        let buffer = currentBuffer()
        let line: Int
        switch request {
        case .top(let target), .center(let target), .bottom(let target): line = target
        }
        let rect = lineRect(at: buffer.lineRange(at: min(line, buffer.lineCount - 1)).location)
        let height = clip.bounds.height
        let top: CGFloat
        switch request {
        case .top: top = rect.minY
        case .center: top = rect.midY - height / 2
        case .bottom: top = rect.maxY - height
        }
        scrollClip(toY: top)
    }

    private func scrollClip(toY y: CGFloat) {
        guard let scrollView = enclosingScrollView else { return }
        let clip = scrollView.contentView
        let bottom = max(frame.height - clip.bounds.height, 0)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: min(max(y, 0), bottom)))
        scrollView.reflectScrolledClipView(clip)
    }

    /// The smallest scroll that shows the cursor's line, `scrolloff` lines from the edges.
    /// AppKit recenters a cursor that leaves the screen; Vim scrolls only as far as needed.
    func revealCursor() {
        guard !isInserting, let clip = enclosingScrollView?.contentView else { return }
        let origin = clip.bounds.origin
        clip.scroll(to: origin)
        let margin = textContainerInset.height
            + CGFloat(store.session.options.scrolloff) * linePitch
        var target = lineRect(at: vim.cursor)
        if !store.session.options.wrap { target = narrowedToCursor(target) }
        scrollToVisible(target.insetBy(dx: 0, dy: -margin))
    }

    /// Without wrapping a line is as wide as the text, so only the cursor's own cell must show.
    private func narrowedToCursor(_ row: NSRect) -> NSRect {
        let length = currentBuffer().length
        guard let layoutManager, let textContainer, length > 0 else { return row }
        let glyph = layoutManager.glyphIndexForCharacter(at: min(vim.cursor, length - 1))
        let box = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        let width = max(box.width, Phosphor.cellWidth)
        return NSRect(x: box.minX + textContainerOrigin.x, y: row.minY, width: width,
                      height: row.height)
    }

    func lineRect(at offset: Int) -> NSRect {
        guard let layoutManager, let textContainer else { return .zero }
        let laidOut = min(offset + 1, currentBuffer().length)
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: laidOut))
        let glyph = layoutManager.glyphIndexForCharacter(at: offset)
        let glyphCount = layoutManager.numberOfGlyphs
        let rect: NSRect
        if glyph < glyphCount {
            rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        } else if glyphCount == 0 || !layoutManager.extraLineFragmentRect.isEmpty {
            rect = layoutManager.extraLineFragmentRect
        } else {
            rect = layoutManager.lineFragmentRect(forGlyphAt: glyphCount - 1, effectiveRange: nil)
        }
        return rect.offsetBy(dx: 0, dy: textContainerOrigin.y)
    }

    /// Scrolling moves the view only. Before the next command, the cursor comes back to the
    /// nearest line the view shows under `scrolloff`.
    func bringCursorIntoView() {
        guard !isInserting, !vim.mode.isVisual, vim.pendingKeys.isEmpty,
              enclosingScrollView != nil,
              visibleRect.height > 0 else { return }
        let buffer = currentBuffer()
        let screen = screenGeometry(buffer)
        let allowed = screen.cursorLines(lineCount: buffer.lineCount,
                                         scrolloff: store.session.options.scrolloff)
        let line = buffer.lineIndex(of: vim.cursor)
        guard !allowed.contains(line) else { return }
        let target = min(max(line, allowed.lowerBound), allowed.upperBound)
        let tabstop = store.session.options.tabstop
        let column = vim.desiredColumn ?? buffer.displayColumn(of: vim.cursor, tabstop: tabstop)
        let offset = buffer.offset(line: target, displayColumn: min(column, Int(Int32.max)),
                                   tabstop: tabstop)
        vim.cursor = buffer.restingOffset(offset)
        showSelection([NSRange(location: vim.cursor, length: 0)])
    }
}

extension TerminalTextView {
    /// The cursor's line and column for the header, counted from 1, using the engine's line
    /// index so a keystroke never splits the text. After a final line break, the empty line
    /// that follows counts as a line, as the editor shows it.
    func cursorPosition() -> (line: Int, column: Int) {
        let buffer = currentBuffer()
        let offset = min(selectedRange().location, buffer.length)
        let last = buffer.lineCount - 1
        let endsWithBreak = buffer.lineRange(at: last).length > buffer.contentRange(at: last).length
        if offset == buffer.length && endsWithBreak { return (buffer.lineCount + 1, 1) }
        let line = buffer.lineIndex(of: offset)
        let start = buffer.lineRange(at: line).location
        let before = buffer.text.substring(with: NSRange(location: start, length: offset - start))
        return (line + 1, before.count + 1)
    }
}
