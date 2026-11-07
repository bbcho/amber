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
final class TerminalView: NSView {
    let textView = TerminalTextView(frame: .zero)
    let filename = NSTextField(labelWithString: "Untitled")
    let position = NSTextField(labelWithString: "Ln 1   Col 1")
    let status = NSTextField(labelWithString: "Drafts save automatically")
    private let screen = NSView()
    private let header = NSView()
    private let scroll = NSScrollView()
    private let texture = ScreenTexture()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0.025, green: 0.021, blue: 0.014, alpha: 1)
            .cgColor
        screen.wantsLayer = true
        screen.layer?.backgroundColor = Phosphor.screen.cgColor
        screen.layer?.cornerRadius = 12
        screen.layer?.masksToBounds = true
        screen.layer?.borderWidth = 1
        screen.layer?.borderColor = Phosphor.amber.withAlphaComponent(0.10).cgColor
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
        status.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        status.textColor = Phosphor.amber.withAlphaComponent(0.65)
        status.lineBreakMode = .byTruncatingMiddle
        status.setAccessibilityLabel("Save status")
        screen.addSubview(status)
        screen.addSubview(texture)
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

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
        textView.textContainerInset = NSSize(width: 22, height: 22)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
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
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        scroll.scrollerKnobStyle = .light
    }

    override func layout() {
        super.layout()
        screen.frame = NSRect(x: 16, y: 16, width: bounds.width - 32, height: bounds.height - 52)
        let size = screen.bounds.size
        header.frame = NSRect(x: 0, y: size.height - 36, width: size.width, height: 36)
        filename.frame = NSRect(x: 20, y: 8, width: max(100, size.width - 220), height: 21)
        position.frame = NSRect(x: size.width - 190, y: 8, width: 170, height: 21)
        scroll.frame = NSRect(x: 0, y: 30, width: size.width, height: size.height - 66)
        textView.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        textView.setFrameSize(NSSize(
            width: scroll.contentSize.width,
            height: max(textView.frame.height, scroll.contentSize.height)
        ))
        textView.sizeToFit()
        status.frame = NSRect(x: 22, y: 9, width: size.width - 44, height: 15)
        texture.frame = NSRect(x: 0, y: 30, width: size.width, height: size.height - 66)
    }
}
