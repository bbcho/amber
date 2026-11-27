import AppKit

extension MarkdownPreviewView {
    /// Starts drawing every diagram the text still waits for. Each finished diagram replaces
    /// its placeholder, wherever the text has moved to since.
    func startDiagrams() {
        guard let storage = textStorage else { return }
        var sources = Set<String>()
        storage.enumerateAttribute(
            .mermaidSource, in: NSRange(location: 0, length: storage.length)
        ) { value, _, _ in
            if let source = value as? String { sources.insert(source) }
        }
        for source in sources {
            Task { [weak self] in
                guard let renderer = self?.diagrams else { return }
                let outcome = await renderer.render(source)
                self?.replacePlaceholders(for: source, with: outcome)
            }
        }
    }

    private func replacePlaceholders(for source: String, with outcome: MermaidOutcome) {
        guard let storage = textStorage, let clip = enclosingScrollView?.contentView else {
            return
        }
        var ranges: [NSRange] = []
        storage.enumerateAttribute(
            .mermaidSource, in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            if value as? String == source { ranges.append(range) }
        }
        guard !ranges.isEmpty else { return }
        var origin = clip.bounds.origin
        for range in ranges.reversed() {
            let attributes = storage.attributes(at: range.location, effectiveRange: nil)
            let replacement = MarkdownRenderer.diagramText(
                source: source, outcome: outcome, attributes: attributes
            )
            let top = clip.bounds.origin.y - textContainerOrigin.y
            let following = range.upperBound + 1
            let before = lineTop(at: following)
            let endsAboveView = bottom(of: range) <= top
            storage.replaceCharacters(in: range, with: replacement)
            if endsAboveView {
                origin.y += lineTop(at: range.location + replacement.length + 1) - before
            }
        }
        sizeToFit()
        let limit = max(frame.height - clip.bounds.height, 0)
        clip.scroll(to: NSPoint(x: origin.x, y: min(max(origin.y, 0), limit)))
        enclosingScrollView?.reflectScrolledClipView(clip)
    }

    /// Where the line holding the character at `index` starts, or the last line past the end.
    private func lineTop(at index: Int) -> CGFloat {
        guard let layout = layoutManager, let container = textContainer else { return 0 }
        layout.ensureLayout(for: container)
        guard layout.numberOfGlyphs > 0 else { return 0 }
        let glyph = layout.glyphIndexForCharacter(at: min(index, layout.numberOfGlyphs - 1))
        return layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
    }

    private func bottom(of range: NSRange) -> CGFloat {
        guard let layout = layoutManager, let container = textContainer else { return 0 }
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        return layout.boundingRect(forGlyphRange: glyphs, in: container).maxY
    }
}
