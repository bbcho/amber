import AppKit
import NotepadCore

/// The line numbers beside the editor, for `number` and `relativenumber`. It draws the
/// numbers of the logical lines the text view shows; a wrapped line is numbered once.
@MainActor
final class LineNumberGutter: NSView {
    struct Row: Equatable {
        var text: String
        var y: CGFloat
        var isCursorLine: Bool
    }

    private static let padding: CGFloat = 8
    private static let minimumDigits = 3

    weak var textView: TerminalTextView?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Wide enough for the largest line number, with room before the text.
    var preferredWidth: CGFloat {
        let lines = textView?.currentBuffer().lineCount ?? 1
        let digits = max(Self.minimumDigits, String(lines).count)
        return ceil(Phosphor.cellWidth * CGFloat(digits)) + Self.padding * 2
    }

    static func label(line: Int, cursorLine: Int, options: VimOptions) -> String {
        switch (options.number, options.relativenumber) {
        case (false, false): return ""
        case (true, false): return String(line + 1)
        case (false, true): return String(abs(line - cursorLine))
        case (true, true): return String(line == cursorLine ? line + 1 : abs(line - cursorLine))
        }
    }

    /// One row per logical line whose first screen row is visible, top to bottom.
    var rows: [Row] {
        guard let view = textView, let layout = view.layoutManager,
              let container = view.textContainer else { return [] }
        let options = view.store.session.options
        let buffer = view.currentBuffer()
        let origin = view.textContainerOrigin
        let visible = view.visibleRect
        let cursorLine = buffer.lineIndex(of: min(view.cursorLocation, buffer.length))
        func row(_ line: Int, _ y: CGFloat) -> Row {
            Row(text: Self.label(line: line, cursorLine: cursorLine, options: options),
                y: y + origin.y - visible.minY, isCursorLine: line == cursorLine)
        }
        guard layout.numberOfGlyphs > 0 else { return [row(0, 0)] }
        let area = visible.offsetBy(dx: -origin.x, dy: -origin.y)
        var rows: [Row] = []
        layout.enumerateLineFragments(
            forGlyphRange: layout.glyphRange(forBoundingRect: area, in: container)
        ) { rect, _, _, glyphs, _ in
            let start = layout.characterIndexForGlyph(at: glyphs.location)
            let line = buffer.lineIndex(of: start)
            if buffer.lineRange(at: line).location == start { rows.append(row(line, rect.minY)) }
        }
        return rows
    }

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.9 : 0.5
        let isHybrid = textView.map {
            $0.store.session.options.number && $0.store.session.options.relativenumber
        } ?? false
        for row in rows {
            let color = row.isCursorLine ? Phosphor.amber : Phosphor.amber.withAlphaComponent(dim)
            let text = row.text as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: Phosphor.font, .foregroundColor: color
            ]
            let width = text.size(withAttributes: attributes).width
            let x = row.isCursorLine && isHybrid
                ? Self.padding : bounds.width - Self.padding - width
            text.draw(at: NSPoint(x: x, y: row.y), withAttributes: attributes)
        }
    }
}
