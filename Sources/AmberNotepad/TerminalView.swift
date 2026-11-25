import AppKit
import NotepadCore

@MainActor
enum Phosphor {
    static let amber = NSColor(srgbRed: 1, green: 0.69, blue: 0.22, alpha: 1)
    static let bar = NSColor(srgbRed: 1, green: 0.75, blue: 0.29, alpha: 1)
    static let screen = NSColor(srgbRed: 0.065, green: 0.039, blue: 0.012, alpha: 1)
    static let ink = NSColor(srgbRed: 0.20, green: 0.10, blue: 0.015, alpha: 1)
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let cellWidth = font.maximumAdvancement.width
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
    /// A command line typed with no engine prompt behind it, such as the preview's `:`.
    var commandSubmitted: ((String) -> Void)?
    /// Runs a command line for the engine, which has typed its keys; true if it succeeded.
    var commandRun: ((String) -> Bool)?
    private var prompt: Character = ":"
    private var prefill = ""
    private var historyIndex: Int?
    private var historyDraft = ""
    /// Candidate full command lines for Tab completion of the typed command.
    var completeCommand: ((String) -> [String])?
    private var completions: [String] = []
    private var completionIndex = 0
    let gutter = LineNumberGutter()
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
        screen.addSubview(gutter)
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
        textView.commandRequested = { [weak self] in
            guard let self else { return }
            self.beginCommand(prefill: self.textView.commandPrefill)
        }
        textView.searchRequested = { [weak self] prompt in self?.beginCommand(prompt: prompt) }
        gutter.textView = textView
        gutter.isHidden = true
        textView.displayDidChange = { [weak self] in self?.refreshGutter() }
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
            object: scroll.contentView
        )
        textView.exRequested = { [weak self] line in self?.commandRun?(line) ?? false }
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    private var showsGutter: Bool {
        let options = textView.store.session.options
        return (options.number || options.relativenumber) && !isShowingMarkdown
    }

    @objc private func scrolled() { refreshGutter() }

    private func refreshGutter() {
        guard showsGutter else { return }
        gutter.needsDisplay = true
        if gutter.preferredWidth != gutter.frame.width { needsLayout = true }
    }

    /// Makes the display options of the shared session show: line numbers, wrapping, tab
    /// width, and the `list` and `cursorline` drawing. Called whenever the options change.
    func applyDisplayOptions() {
        let options = textView.store.session.options
        applyWrap(options.wrap)
        applyTabstop(options.tabstop)
        gutter.isHidden = !showsGutter
        textView.needsDisplay = true
        gutter.needsDisplay = true
        needsLayout = true
    }

    private func applyWrap(_ wraps: Bool) {
        textView.isHorizontallyResizable = !wraps
        textView.autoresizingMask = wraps ? [.width] : []
        textView.textContainer?.widthTracksTextView = wraps
        textView.textContainer?.size = NSSize(
            width: wraps ? scroll.contentSize.width : 10_000_000,
            height: CGFloat.greatestFiniteMagnitude
        )
        scroll.hasHorizontalScroller = !wraps
    }

    /// Sets the tab width of the text already in the editor and of the text typed next.
    private func applyTabstop(_ tabstop: Int) {
        let interval = Phosphor.cellWidth * CGFloat(tabstop)
        let current = textView.defaultParagraphStyle?.defaultTabInterval
        guard current != interval,
              let paragraph = textView.defaultParagraphStyle?.mutableCopy()
                as? NSMutableParagraphStyle else { return }
        paragraph.tabStops = []
        paragraph.defaultTabInterval = interval
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes[.paragraphStyle] = paragraph
        guard let storage = textView.textStorage else { return }
        storage.beginEditing()
        storage.addAttribute(
            .paragraphStyle, value: paragraph, range: NSRange(location: 0, length: storage.length)
        )
        storage.endEditing()
    }

    /// Opens the footer for `:`, `/` or `?`. `prefill` is text the engine already holds, such
    /// as `'<,'>` after `:` in Visual mode.
    func beginCommand(prompt: Character = ":", prefill: String = "") {
        self.prompt = prompt
        self.prefill = prefill
        historyIndex = nil
        let opening = String(prompt) + prefill
        commandLine.stringValue = opening
        status.isHidden = true
        commandLine.isHidden = false
        window?.makeFirstResponder(commandLine)
        if let editor = commandLine.currentEditor() as? NSTextView {
            editor.insertionPointColor = Phosphor.amber
            editor.setSelectedRange(NSRange(location: (opening as NSString).length, length: 0))
        }
    }

    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
    ) -> Bool {
        guard control === commandLine, !commandLine.isHidden else { return false }
        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            browseHistory(textView, step: -1)
            return true
        }
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            browseHistory(textView, step: 1)
            return true
        }
        let isTab = commandSelector == #selector(NSResponder.insertTab(_:))
            || commandSelector == #selector(NSResponder.insertBacktab(_:))
        if isTab, prompt != ":" { return true }
        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            completeCommandLine(textView, step: 1)
            return true
        }
        if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
            completeCommandLine(textView, step: -1)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            let typed = typedText(in: textView.string)
            endCommand()
            if self.textView.hasOpenPrompt { self.textView.cancelPrompt(typed: typed ?? "") }
            return true
        }
        guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
        submit(textView.string)
        return true
    }

    private func submit(_ command: String) {
        let typed = typedText(in: command)
        endCommand()
        guard textView.hasOpenPrompt else {
            let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, trimmed != ":" { commandSubmitted?(command) }
            return
        }
        guard let typed, prompt != ":" || !(typed + prefill).isEmpty else {
            textView.cancelPrompt(typed: "")
            return
        }
        textView.store.remember(typed, prompt: prompt)
        if prompt == ":" { textView.submitCommand(typed) }
        else { textView.submitSearch(typed, forward: prompt == "/") }
    }

    /// What the user typed after the prompt and the engine's prefill; nil if they erased those.
    private func typedText(in field: String) -> String? {
        let opening = String(prompt) + prefill
        guard field.hasPrefix(opening) else { return nil }
        return String(field.dropFirst(opening.count))
    }

    /// Up and Down walk the history of this kind of prompt, keeping what was typed first.
    private func browseHistory(_ editor: NSTextView, step: Int) {
        let history = textView.store.history(for: prompt)
        guard !history.isEmpty else { return }
        if historyIndex == nil {
            historyDraft = typedText(in: editor.string) ?? ""
            historyIndex = history.count
        }
        let next = min(max((historyIndex ?? history.count) + step, 0), history.count)
        historyIndex = next
        let typed = next == history.count ? historyDraft : history[next]
        editor.string = String(prompt) + prefill + typed
        commandLine.stringValue = editor.string
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
    }

    func controlTextDidChange(_ notification: Notification) {
        completions = []
    }

    /// As in Vim's command line: the first Tab inserts the first match, later Tabs cycle,
    /// and one past the last match returns to what was typed. Shift-Tab cycles backwards.
    private func completeCommandLine(_ editor: NSTextView, step: Int) {
        if let index = completions.firstIndex(of: editor.string) {
            completionIndex = (index + step + completions.count) % completions.count
        } else {
            let matches = completeCommand?(editor.string) ?? []
            guard !matches.isEmpty else { return }
            completions = matches + [editor.string]
            completionIndex = step > 0 ? 0 : matches.count - 1
        }
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
        needsLayout = true
        window?.makeFirstResponder(textView)
        if textView.vimEnabled { textView.setMode(.normal) }
        let length = (textView.string as NSString).length
        let cursor = min(sourceSelection.location, length)
        textView.setSelectedRange(NSRange(location: cursor, length: 0))
        restoreTopOfSource(sourceTop)
    }

    /// Replaces the editor's text as one undoable change, keeping the cursor's line and
    /// column and the scroll position. Used when the file changes outside Amber. A visible
    /// cursor on the last line of text follows it to the new last line, like `tail -f`.
    func replaceSourceText(_ text: String) {
        let old = textView.string as NSString
        let new = text as NSString
        let cursor = isShowingMarkdown
            ? sourceSelection.location : textView.selectedRange().location
        let position = Self.linePosition(of: min(cursor, old.length), in: old)
        let lastLine = Self.linePosition(of: old.length, in: old).line
        let onEmptyFinalLine = position.line == lastLine && lastLine != Self.lastTextLine(in: old)
        let follows = position.line >= Self.lastTextLine(in: old)
            && (isShowingMarkdown || isSourceOffsetVisible(min(cursor, old.length)))
        let origin = scroll.contentView.bounds.origin
        textView.resetForOutsideChange()
        let whole = NSRange(location: 0, length: old.length)
        guard textView.shouldChangeText(in: whole, replacementString: text) else { return }
        let replacement = NSAttributedString(string: text, attributes: textView.typingAttributes)
        textView.textStorage?.replaceCharacters(in: whole, with: replacement)
        textView.didChangeText()
        let line: Int
        if !follows { line = position.line }
        else if onEmptyFinalLine { line = Self.linePosition(of: new.length, in: new).line }
        else { line = Self.lastTextLine(in: new) }
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

    /// The last line holding text: a final line break leaves an empty line after it.
    private static func lastTextLine(in text: NSString) -> Int {
        let last = linePosition(of: text.length, in: text).line
        guard text.length > 0, let scalar = UnicodeScalar(text.character(at: text.length - 1)),
              CharacterSet.newlines.contains(scalar) else { return last }
        return max(last - 1, 0)
    }

    private func isSourceOffsetVisible(_ offset: Int) -> Bool {
        guard let layout = textView.layoutManager, layout.numberOfGlyphs > 0 else { return true }
        let glyph = min(layout.glyphIndexForCharacter(at: offset), layout.numberOfGlyphs - 1)
        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return line.offsetBy(dx: 0, dy: textView.textContainerOrigin.y)
            .intersects(scroll.contentView.bounds)
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
        paragraph.tabStops = []
        paragraph.defaultTabInterval = Phosphor.cellWidth * 4
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
        let shelf = NSRect(x: 0, y: 22, width: size.width, height: size.height - 50)
        let gutterWidth = showsGutter ? gutter.preferredWidth : 0
        gutter.isHidden = !showsGutter
        gutter.frame = NSRect(x: 0, y: shelf.minY, width: gutterWidth, height: shelf.height)
        scroll.frame = NSRect(x: gutterWidth, y: shelf.minY,
                              width: shelf.width - gutterWidth, height: shelf.height)
        let wraps = textView.store.session.options.wrap
        textView.minSize = NSSize(
            width: wraps ? 0 : scroll.contentSize.width, height: scroll.contentSize.height
        )
        let width = wraps ? scroll.contentSize.width
            : max(textView.frame.width, scroll.contentSize.width)
        textView.setFrameSize(NSSize(
            width: width,
            height: max(textView.frame.height, scroll.contentSize.height)
        ))
        textView.sizeToFit()
        previewScroll.frame = shelf
        preview.minSize = NSSize(width: 0, height: previewScroll.contentSize.height)
        preview.setFrameSize(NSSize(
            width: previewScroll.contentSize.width,
            height: max(preview.frame.height, previewScroll.contentSize.height)
        ))
        preview.sizeToFit()
        status.frame = NSRect(x: 8, y: 4, width: size.width - 16, height: 15)
        commandLine.frame = status.frame
        texture.frame = shelf
    }
}
