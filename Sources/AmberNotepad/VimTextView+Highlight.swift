import AppKit
import NotepadCore

/// `hlsearch`: the matches of the last search, drawn as temporary attributes.
extension TerminalTextView {
    private static let highlightLimit = 10_000

    func setHighlight(_ pattern: String?) {
        highlightPattern = pattern
        refreshHighlight()
    }

    func refreshHighlight() {
        guard let layout = layoutManager else { return }
        let whole = NSRange(location: 0, length: (string as NSString).length)
        layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: whole)
        let options = store.session.options
        guard let pattern = highlightPattern, options.hlsearch,
              let regex = try? VimPattern.regex(
                  pattern, ignoreCase: options.ignorecase,
                  smartCase: options.smartcase && store.session.lastSearch?.usesSmartCase != false
              ) else { return }
        let color = Phosphor.amber.withAlphaComponent(0.35)
        let text = currentBuffer().text
        var count = 0
        regex.enumerateMatches(in: text as String, range: whole) { match, _, stop in
            guard let range = match?.range, range.length > 0 else { return }
            layout.addTemporaryAttribute(.backgroundColor, value: color,
                                         forCharacterRange: range)
            count += 1
            if count >= Self.highlightLimit { stop.pointee = true }
        }
    }
}
