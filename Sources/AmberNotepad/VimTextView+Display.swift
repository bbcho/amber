import AppKit

extension TerminalTextView {
    /// Where the cursor is on screen: the engine's cursor, or the caret outside Normal mode.
    var cursorLocation: Int {
        vimEnabled && !isInserting ? vim.cursor : selectedRange().location
    }

    /// The cursor moved: the band and the relative numbers follow it.
    func cursorDidMove() {
        if store.session.options.cursorline { needsDisplay = true }
        if !isBatching { displayDidChange?() }
    }

    private var markerAttributes: [NSAttributedString.Key: Any] {
        let alpha = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.9 : 0.5
        return [.font: Phosphor.font,
                .foregroundColor: Phosphor.amber.withAlphaComponent(alpha)]
    }

    /// A faint band across the screen row that holds the cursor, drawn under the text.
    func drawCursorLine() {
        guard store.session.options.cursorline else { return }
        let rect = lineRect(at: min(cursorLocation, currentBuffer().length))
        let high = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        Phosphor.amber.withAlphaComponent(high ? 0.18 : 0.09).setFill()
        NSRect(x: bounds.minX, y: rect.minY, width: bounds.width, height: rect.height).fill()
    }

    /// `>` for each tab, `-` for each trailing space and `$` at each line end, drawn over the
    /// text so the document never holds them.
    func drawListMarkers(in dirtyRect: NSRect) {
        guard store.session.options.list, let layout = layoutManager,
              let container = textContainer else { return }
        let origin = textContainerOrigin
        guard layout.numberOfGlyphs > 0 else {
            draw(marker: "$", at: NSPoint(x: origin.x, y: origin.y))
            return
        }
        let text = string as NSString
        let area = dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y)
        layout.enumerateLineFragments(
            forGlyphRange: layout.glyphRange(forBoundingRect: area, in: container)
        ) { rect, used, _, glyphs, _ in
            let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            var contentsEnd = 0
            text.getLineStart(nil, end: nil, contentsEnd: &contentsEnd,
                              for: NSRange(location: chars.location, length: 0))
            let spaces = Self.trailingSpaces(before: contentsEnd, in: text)
            for index in chars.location..<min(NSMaxRange(chars), contentsEnd) {
                let marker: String
                switch text.character(at: index) {
                case 0x09: marker = ">"
                case 0x20 where index >= spaces: marker = "-"
                default: continue
                }
                let box = layout.boundingRect(
                    forGlyphRange: layout.glyphRange(
                        forCharacterRange: NSRange(location: index, length: 1),
                        actualCharacterRange: nil),
                    in: container)
                let point = NSPoint(x: box.minX + origin.x, y: rect.minY + origin.y)
                self.draw(marker: marker, at: point)
            }
            if contentsEnd >= chars.location, contentsEnd <= NSMaxRange(chars) {
                let end = NSPoint(x: used.maxX + origin.x, y: rect.minY + origin.y)
                self.draw(marker: "$", at: end)
            }
        }
    }

    /// The start of the run of spaces that ends the line, or `end` if there is none.
    private static func trailingSpaces(before end: Int, in text: NSString) -> Int {
        var start = end
        while start > 0, text.character(at: start - 1) == 0x20 { start -= 1 }
        return start
    }

    private func draw(marker: String, at point: NSPoint) {
        (marker as NSString).draw(at: point, withAttributes: markerAttributes)
    }
}
