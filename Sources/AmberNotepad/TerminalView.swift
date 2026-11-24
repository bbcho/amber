import AppKit

@MainActor
enum Phosphor {
    static let amber = NSColor(srgbRed: 1, green: 0.69, blue: 0.22, alpha: 1)
    static let bar = NSColor(srgbRed: 1, green: 0.75, blue: 0.29, alpha: 1)
    static let screen = NSColor(srgbRed: 0.065, green: 0.039, blue: 0.012, alpha: 1)
    static let ink = NSColor(srgbRed: 0.20, green: 0.10, blue: 0.015, alpha: 1)
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
}

@MainActor
final class ScreenTexture: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast else { return }
        NSColor.black.withAlphaComponent(0.10).setFill()
        for y in stride(from: CGFloat(0), to: bounds.height, by: 3) {
            NSRect(x: 0, y: y, width: bounds.width, height: 0.5).fill()
        }
        let edge = NSColor.black.withAlphaComponent(0.28)
        let gradient = NSGradient(starting: .clear, ending: edge)
        gradient?.draw(
            fromCenter: NSPoint(x: bounds.midX, y: bounds.midY), radius: bounds.width * 0.2,
            toCenter: NSPoint(x: bounds.midX, y: bounds.midY), radius: bounds.width * 0.8,
            options: [.drawsBeforeStartingLocation, .drawsAfterEndingLocation]
        )
    }
}

@MainActor
final class TerminalView: NSView, NSTextFieldDelegate {
    let textView = TerminalTextView(frame: .zero)
    let filename = NSTextField(labelWithString: "Untitled")
    let position = NSTextField(labelWithString: "Ln 1   Col 1")
    let status = NSTextField(labelWithString: "Drafts save automatically")
    let commandLine = NSTextField()
    var commandSubmitted: ((String) -> Void)?
    /// Candidate full command lines for Tab completion of the typed command.
    var completeCommand: ((String) -> [String])?
    private var completions: [String] = []
    private var completionIndex = 0
    let preview = MarkdownPreviewView()
    private(set) var isShowingMarkdown = false
    private var sourceSelection = NSRange(location: 0, length: 0)
    private var sourceTop = (character: 0, offset: CGFloat(0))
    private let screen = NSView()
    private let header = NSView()
    private let scroll = NSScrollView()
    private let previewScroll = NSScrollView()
    private let texture = ScreenTexture()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0.025, green: 0.021, blue: 0.014, alpha: 1)
            .cgColor
        screen.wantsLayer = true
        screen.layer?.backgroundColor = Phosphor.screen.cgColor
        screen.layer?.masksToBounds = true
        addSubview(screen)
        header.wantsLayer = true
        header.layer?.backgroundColor = Phosphor.bar.cgColor
        screen.addSubview(header)
        for label in [filename, position] {
            label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
            label.textColor = Phosphor.ink
            header.addSubview(label)
        }
        filename.lineBreakMode = .byTruncatingMiddle
        position.alignment = .right
        filename.setAccessibilityLabel("Document name")
        position.setAccessibilityLabel("Cursor position")
        configureEditor()
        screen.addSubview(scroll)
        Self.configure(previewScroll)
        previewScroll.documentView = preview
        previewScroll.isHidden = true
        screen.addSubview(previewScroll)
        preview.commandRequested = { [weak self] in self?.beginCommand() }
        status.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        status.textColor = Phosphor.amber.withAlphaComponent(0.65)
        status.lineBreakMode = .byTruncatingMiddle
        status.setAccessibilityLabel("Save status")
        screen.addSubview(status)
        commandLine.font = status.font
        commandLine.textColor = Phosphor.amber
        commandLine.isBordered = false
        commandLine.drawsBackground = false
        commandLine.focusRingType = .none
        commandLine.usesSingleLineMode = true
        commandLine.lineBreakMode = .byClipping
        commandLine.delegate = self
        commandLine.isHidden = true
        commandLine.setAccessibilityLabel("Vim command")
        screen.addSubview(commandLine)
        screen.addSubview(texture)
        textView.commandRequested = { [weak self] in self?.beginCommand() }
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    func beginCommand() {
        commandLine.stringValue = ":"
        status.isHidden = true
        commandLine.isHidden = false
        window?.makeFirstResponder(commandLine)
        if let editor = commandLine.currentEditor() as? NSTextView {
            editor.insertionPointColor = Phosphor.amber
            editor.setSelectedRange(NSRange(location: 1, length: 0))
        }
    }

    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
    ) -> Bool {
        guard control === commandLine, !commandLine.isHidden else { return false }
        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            completeCommandLine(textView)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            endCommand()
            return true
        }
        guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
        let command = textView.string
        endCommand()
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != ":" { commandSubmitted?(command) }
        return true
    }

    func controlTextDidChange(_ notification: Notification) {
        completions = []
    }

    /// The first Tab inserts the first match; later Tabs cycle, as Vim's command line does.
    private func completeCommandLine(_ editor: NSTextView) {
        if let index = completions.firstIndex(of: editor.string) {
            completionIndex = (index + 1) % completions.count
        } else {
            completions = completeCommand?(editor.string) ?? []
            completionIndex = 0
        }
        guard !completions.isEmpty else { return }
        editor.string = completions[completionIndex]
        commandLine.stringValue = editor.string
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
    }

    private func endCommand() {
        commandLine.isHidden = true
        status.isHidden = false
        if isShowingMarkdown {
            window?.makeFirstResponder(preview)
            return
        }
        if textView.mode != .normal { textView.setMode(.normal) }
        window?.makeFirstResponder(textView)
    }

    /// Shows `text` read-only in place of the editor, which keeps its text, undo and position.
    func showMarkdown(_ text: NSAttributedString) {
        if !isShowingMarkdown {
            sourceSelection = textView.selectedRange()
            sourceTop = topOfSource()
        }
        dismissCommandLine()
        isShowingMarkdown = true
        preview.textStorage?.setAttributedString(text)
        scroll.isHidden = true
        previewScroll.isHidden = false
        needsLayout = true
        layoutSubtreeIfNeeded()
        previewScroll.contentView.scroll(to: .zero)
        previewScroll.reflectScrolledClipView(previewScroll.contentView)
        window?.makeFirstResponder(preview)
    }

    func showSource() {
        guard isShowingMarkdown else { return }
        dismissCommandLine()
        isShowingMarkdown = false
        previewScroll.isHidden = true
        scroll.isHidden = false
        window?.makeFirstResponder(textView)
        if textView.vimEnabled { textView.setMode(.normal) }
        let length = (textView.string as NSString).length
        let cursor = min(sourceSelection.location, length)
        textView.setSelectedRange(NSRange(location: cursor, length: 0))
        restoreTopOfSource(sourceTop)
    }

    /// Replaces the editor's text as one undoable change, keeping the cursor's line and
    /// column and the scroll position. Used when the file changes outside Amber. A cursor on
    /// the last line follows it to the new last line, like `tail -f`.
    func replaceSourceText(_ text: String) {
        let old = textView.string as NSString
        let new = text as NSString
        let cursor = isShowingMarkdown
            ? sourceSelection.location : textView.selectedRange().location
        let position = Self.linePosition(of: min(cursor, old.length), in: old)
        let follows = position.line == Self.linePosition(of: old.length, in: old).line
        let origin = scroll.contentView.bounds.origin
        let whole = NSRange(location: 0, length: old.length)
        guard textView.shouldChangeText(in: whole, replacementString: text) else { return }
        let replacement = NSAttributedString(string: text, attributes: textView.typingAttributes)
        textView.textStorage?.replaceCharacters(in: whole, with: replacement)
        textView.didChangeText()
        if textView.mode == .visual { textView.setMode(.normal) }
        let line = follows ? Self.linePosition(of: new.length, in: new).line : position.line
        let moved = NSRange(
            location: Self.offset(line: line, column: position.column, in: new), length: 0
        )
        if isShowingMarkdown { sourceSelection = moved } else { textView.setSelectedRange(moved) }
        if let container = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: container)
        }
        textView.sizeToFit()
        let clip = scroll.contentView
        let bottom = max(textView.frame.height - clip.bounds.height, 0)
        clip.scroll(to: NSPoint(x: origin.x, y: follows ? bottom : min(origin.y, bottom)))
        scroll.reflectScrolledClipView(clip)
    }

    /// Replaces the rendered text, keeping the rendered view's scroll position, or keeping
    /// it at the bottom if it was there.
    func updateMarkdown(_ text: NSAttributedString) {
        let clip = previewScroll.contentView
        let origin = clip.bounds.origin
        let wasAtBottom = origin.y >= preview.frame.height - clip.bounds.height - 1
        preview.textStorage?.setAttributedString(text)
        if let container = preview.textContainer {
            preview.layoutManager?.ensureLayout(for: container)
        }
        preview.sizeToFit()
        let bottom = max(preview.frame.height - clip.bounds.height, 0)
        clip.scroll(to: NSPoint(x: origin.x, y: wasAtBottom ? bottom : min(origin.y, bottom)))
        previewScroll.reflectScrolledClipView(clip)
    }

    private static func linePosition(
        of offset: Int, in text: NSString
    ) -> (line: Int, column: Int) {
        var lineStart = 0
        text.getLineStart(&lineStart, end: nil, contentsEnd: nil,
                          for: NSRange(location: offset, length: 0))
        var line = 0
        var start = 0
        while start < lineStart {
            start = NSMaxRange(text.lineRange(for: NSRange(location: start, length: 0)))
            line += 1
        }
        return (line, offset - lineStart)
    }

    private static func offset(line: Int, column: Int, in text: NSString) -> Int {
        var start = 0
        for _ in 0..<line {
            let next = NSMaxRange(text.lineRange(for: NSRange(location: start, length: 0)))
            guard next > start else { break }
            start = next
        }
        var contentsEnd = 0
        text.getLineStart(nil, end: nil, contentsEnd: &contentsEnd,
                          for: NSRange(location: start, length: 0))
        let target = min(start + column, contentsEnd)
        guard target < text.length else { return target }
        return text.rangeOfComposedCharacterSequence(at: target).location
    }

    private func dismissCommandLine() {
        commandLine.stringValue = ""
        commandLine.isHidden = true
        status.isHidden = false
    }

    /// The source's top line as a character and an offset into its line, so it can be
    /// found again after the text re-wraps at a new window width.
    private func topOfSource() -> (character: Int, offset: CGFloat) {
        let y = scroll.contentView.bounds.minY - textView.textContainerOrigin.y
        guard let layout = textView.layoutManager, let container = textView.textContainer,
              layout.numberOfGlyphs > 0 else { return (0, y) }
        let glyph = layout.glyphIndex(for: NSPoint(x: 0, y: max(y, 0)), in: container)
        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return (layout.characterIndexForGlyph(at: glyph), y - line.minY)
    }

    private func restoreTopOfSource(_ top: (character: Int, offset: CGFloat)) {
        var y = top.offset
        if let layout = textView.layoutManager, layout.numberOfGlyphs > 0 {
            let glyph = min(layout.glyphIndexForCharacter(at: top.character),
                            layout.numberOfGlyphs - 1)
            y += layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
        }
        let clip = scroll.contentView
        let bottom = max(textView.frame.height - clip.bounds.height, 0)
        clip.scroll(to: NSPoint(
            x: 0, y: min(max(y + textView.textContainerOrigin.y, 0), bottom)
        ))
        scroll.reflectScrolledClipView(clip)
    }

    private func configureEditor() {
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.font = Phosphor.font
        textView.textColor = Phosphor.amber
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.insertionPointColor = Phosphor.amber
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.defaultTabInterval = Phosphor.font.maximumAdvancement.width * 4
        let glow = NSShadow()
        glow.shadowColor = Phosphor.amber.withAlphaComponent(0.32)
        glow.shadowBlurRadius = 3
        glow.shadowOffset = .zero
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = [
            .font: Phosphor.font, .foregroundColor: Phosphor.amber,
            .paragraphStyle: paragraph, .shadow: glow
        ]
        textView.selectedTextAttributes = [
            .backgroundColor: Phosphor.amber.withAlphaComponent(0.28),
            .foregroundColor: Phosphor.bar
        ]
        textView.setAccessibilityLabel("Document text")
        scroll.documentView = textView
        Self.configure(scroll)
    }

    private static func configure(_ scrollView: NSScrollView) {
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .overlay
        scrollView.scrollerKnobStyle = .light
    }

    override func layout() {
        super.layout()
        screen.frame = bounds
        let size = screen.bounds.size
        header.frame = NSRect(x: 0, y: size.height - 28, width: size.width, height: 28)
        let rowCenter: CGFloat
        if let button = window?.standardWindowButton(.closeButton) {
            rowCenter = header.convert(button.bounds, from: button).midY
        } else {
            rowCenter = header.bounds.midY
        }
        let labelHeight = filename.intrinsicContentSize.height
        let labelY = rowCenter - labelHeight / 2
        filename.frame = NSRect(
            x: 84, y: labelY, width: max(100, size.width - 272), height: labelHeight
        )
        position.frame = NSRect(
            x: size.width - 178, y: labelY, width: 170, height: labelHeight
        )
        scroll.frame = NSRect(x: 0, y: 22, width: size.width, height: size.height - 50)
        textView.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        textView.setFrameSize(NSSize(
            width: scroll.contentSize.width,
            height: max(textView.frame.height, scroll.contentSize.height)
        ))
        textView.sizeToFit()
        previewScroll.frame = scroll.frame
        preview.minSize = NSSize(width: 0, height: previewScroll.contentSize.height)
        preview.setFrameSize(NSSize(
            width: previewScroll.contentSize.width,
            height: max(preview.frame.height, previewScroll.contentSize.height)
        ))
        preview.sizeToFit()
        status.frame = NSRect(x: 8, y: 4, width: size.width - 16, height: 15)
        commandLine.frame = status.frame
        texture.frame = scroll.frame
    }
}
