import AppKit
import NotepadCore

/// The editor's text view: a thin adapter between AppKit and `VimEngine`. It turns key events
/// into `VimKey`s, applies the engine's edits through the text view's own change protocol so
/// undo and autosave keep working, and treats selection changes it did not make as input.
@MainActor
final class TerminalTextView: NSTextView {
    enum Mode: String {
        case normal = "NORMAL", insert = "INSERT", visual = "VISUAL", replace = "REPLACE"
        case visualLine = "VISUAL LINE", visualBlock = "VISUAL BLOCK"
    }

    private static let maximumReplayedKeys = 100_000
    private static let maximumRecursion = 100

    private(set) var mode: Mode = .normal
    var vimEnabled = true { didSet { vimToggled() } }
    var modeDidChange: (() -> Void)?
    /// `:` opened the command line; `commandPrefill` is what the engine typed after it.
    var commandRequested: (() -> Void)?
    /// `/` or `?` opened the command line.
    var searchRequested: ((Character) -> Void)?
    /// Runs an ex command line for the engine and says whether it succeeded.
    var exRequested: ((String) -> Bool)?
    var statusMessage: ((String) -> Void)?
    var store = VimSessionStore()

    var vim = VimWindowState()
    var cachedBuffer: VimBuffer?
    var highlightPattern: String?
    private let vimUndo = UndoManager()
    private var undoGroupOpen = false
    private var implicitUndoGroup = false
    private var scopeDepth = 0
    private var replayedKeys = 0
    private var lineMarks: ExLineMarks?
    var applyingState = false
    var typingNatively = false
    var mouseClick: (offset: Int, count: Int)?

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        observeTextStorage()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        observeTextStorage()
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    private func observeTextStorage() {
        vimUndo.groupsByEvent = false
        NotificationCenter.default.addObserver(
            self, selector: #selector(textStorageChanged),
            name: NSTextStorage.didProcessEditingNotification, object: textStorage
        )
    }

    @objc private func textStorageChanged() { cachedBuffer = nil }

    var isInserting: Bool { vim.mode == .insert || vim.mode == .replace }

    /// The buffer of the text on screen, rebuilt only after the text changed.
    func currentBuffer() -> VimBuffer {
        if let cachedBuffer { return cachedBuffer }
        let buffer = VimBuffer(NSString(string: string))
        cachedBuffer = buffer
        return buffer
    }

    /// The editor's own undo manager, so Vim's undo groups never meet the footer field's.
    override var undoManager: UndoManager? { vimUndo }

    // MARK: Modes

    func setMode(_ newMode: Mode) {
        endUndoGroup()
        let buffer = currentBuffer()
        let location = min(selectedRange().location, buffer.length)
        clearPendingCommand()
        vim.insertSession = nil
        vim.changeInProgress = nil
        vim.visualAnchor = nil
        vim.desiredColumn = nil
        vim.cursor = location
        vim.mode = VimMode(newMode)
        switch newMode {
        case .normal: vim.cursor = buffer.restingOffset(location)
        case .insert, .replace: vim.insertSession = InsertSession(start: location)
        case .visual, .visualLine, .visualBlock: vim.visualAnchor = location
        }
        if isInserting { beginUndoGroup() }
        if !newMode.isVisual { showSelection([NSRange(location: vim.cursor, length: 0)]) }
        syncMode()
    }

    func clearPendingCommand() {
        vim.pendingKeys = []
        vim.count = nil
        vim.leadingCount = nil
        vim.register = nil
        vim.operatorKeys = []
    }

    /// A reload or other outside change leaves any command, Visual selection or insert.
    func resetForOutsideChange() {
        guard vimEnabled else { return }
        setMode(.normal)
    }

    private func vimToggled() {
        endUndoGroup()
        vimUndo.groupsByEvent = !vimEnabled
        setMode(vimEnabled ? .normal : .insert)
    }

    func syncMode() {
        let newMode = vimEnabled ? Mode(vim.mode) : .insert
        let changed = newMode != mode
        mode = newMode
        if changed {
            updateInsertionPointStateAndRestartTimer(true)
            needsDisplay = true
        }
        modeDidChange?()
    }

    /// What the status line shows after the mode: a recording, and the keys typed so far.
    var statusDetail: String {
        var parts: [String] = []
        if let recording = store.session.recording {
            parts.append("recording @\(recording.register)")
        }
        let typed = pendingDescription
        if !typed.isEmpty { parts.append(typed) }
        return parts.joined(separator: "  ")
    }

    private var pendingDescription: String {
        guard store.session.options.showcmd else { return "" }
        let keys = (vim.operatorKeys + vim.pendingKeys).map(\.notation).joined()
        return [vim.leadingCount.map(String.init), vim.register.map { "\"\($0)" },
                vim.count.map(String.init), keys.isEmpty ? nil : keys]
            .compactMap { $0 }.joined()
    }

    /// What the engine typed after `:`, such as `'<,'>` in Visual mode.
    var commandPrefill: String {
        guard vim.pendingKeys.first == VimKey(.character(":")) else { return "" }
        return String(vim.pendingKeys.dropFirst().compactMap(\.baseCharacter))
    }

    var hasOpenPrompt: Bool {
        guard let first = vim.pendingKeys.first?.baseCharacter else { return false }
        return "/?:".contains(first)
    }

    // MARK: Drawing

    override var shouldDrawInsertionPoint: Bool { !vimEnabled || mode == .insert }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard vimEnabled, mode != .insert, selectedRange().length == 0,
              window?.firstResponder === self, let window else { return }
        var actual = NSRange()
        let rect = firstRect(forCharacterRange: selectedRange(), actualRange: &actual)
        var caret = convert(window.convertFromScreen(rect), from: nil)
        caret.size.width = ceil(Phosphor.font.maximumAdvancement.width)
        Phosphor.amber.withAlphaComponent(0.65).setFill()
        caret.fill()
    }

    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        guard vimEnabled else { return super.keyDown(with: event) }
        switch event.vimInput {
        case .shortcut:
            super.keyDown(with: event)
        case .optionChord, .unmapped:
            if isInserting { super.keyDown(with: event) }
        case .key(let key):
            if isInserting && (hasMarkedText() || !engineOwnsInsertKey(key)) {
                super.keyDown(with: event)
            } else {
                feed([key])
            }
        }
    }

    /// In Insert mode AppKit types text and moves the cursor; the engine takes the keys that
    /// edit by Vim's rules, and every key in Replace mode, which AppKit cannot overwrite.
    private func engineOwnsInsertKey(_ key: VimKey) -> Bool {
        if vim.mode == .replace || !vim.pendingKeys.isEmpty { return true }
        switch (key.base, key.control) {
        case (.escape, _), (.enter, _), (.backspace, _), (.tab, false): return true
        case (.character(let character), true): return "wurtdhjmci[".contains(character)
        case (.character, false), (.tab, true), (.up, _), (.down, _), (.left, _), (.right, _),
             (.home, _), (.end, _), (.pageUp, _), (.pageDown, _), (.delete, _):
            return false
        }
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard vimEnabled, isInserting else {
            return super.insertText(string, replacementRange: replacementRange)
        }
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        typingNatively = true
        super.insertText(string, replacementRange: replacementRange)
        typingNatively = false
        let result = VimEngine.recordTyped(text, window: vim, session: store.session)
        vim = result.window
        store.session = result.session
        vim.cursor = selectedRange().location
        syncMode()
    }

    // MARK: Feeding keys to the engine

    /// Feeds typed keys to the engine, then the keys of any replay they start, marked as
    /// replayed, until a replayed key fails or a limit passes. One call is one undo step.
    func feed(_ keys: [VimKey]) {
        withUndoGroup { _ = play(keys, replayed: false) }
    }

    private struct Queued {
        var key: VimKey
        var replayed: Bool
        var level: Int
    }

    private func play(_ keys: [VimKey], replayed: Bool) -> Bool {
        var stack = keys.reversed().map { Queued(key: $0, replayed: replayed, level: 0) }
        var failed = false
        var geometry: ScreenGeometry?
        while let item = stack.popLast() {
            if item.replayed, !countReplayedKey(item.level) {
                failed = true
                break
            }
            if !item.replayed, scopeDepth <= 1 { bringCursorIntoView() }
            let buffer = currentBuffer()
            let screen = geometry ?? screenGeometry(buffer)
            geometry = screen
            let result = VimEngine.handle(
                item.key, window: vim, session: store.session, buffer: buffer, screen: screen,
                clipboard: { NSPasteboard.general.string(forType: .string) },
                replayed: item.replayed
            )
            let outcome = finish(result, replayed: item.replayed)
            if outcome.changedView { geometry = nil }
            if item.replayed && outcome.failed {
                stack.removeAll { $0.replayed }
                failed = true
            }
            stack.append(contentsOf: outcome.replay.reversed().map {
                Queued(key: $0, replayed: true, level: item.level + 1)
            })
        }
        return failed
    }

    private func countReplayedKey(_ level: Int) -> Bool {
        replayedKeys += 1
        guard replayedKeys <= Self.maximumReplayedKeys, level <= Self.maximumRecursion else {
            statusMessage?("E223: Recursive mapping")
            return false
        }
        return true
    }

    private struct Outcome {
        var failed = false
        var changedView = false
        var replay: [VimKey] = []
    }

    private func finish(_ result: VimResult, replayed: Bool) -> Outcome {
        var outcome = Outcome(changedView: !result.edits.isEmpty)
        let recordingBefore = store.session.recording
        let previous = (window: vim, session: store.session)
        vim = result.window
        store.session = result.session
        guard applyEdits(result.edits) else {
            (vim, store.session) = previous
            showSelection([NSRange(location: vim.cursor, length: 0)])
            syncMode()
            statusMessage?("E21: Cannot make changes, 'modifiable' is off")
            outcome.failed = true
            return outcome
        }
        showSelection(result.selections)
        if !result.edits.isEmpty { refreshHighlight() }
        for effect in result.effects {
            switch effect {
            case .scroll(let request):
                scroll(request)
                outcome.changedView = true
            case .openCommandLine(let prompt, _):
                if !replayed { openCommandLine(prompt) }
            case .undo(let count): undoSteps(count, redo: false)
            case .redo(let count): undoSteps(count, redo: true)
            case .replay(let keys): outcome.replay = keys
            case .replayLines(let replay): runLines(replay)
            case .message(let message): statusMessage?(message)
            case .failure: outcome.failed = true
            case .setClipboard(let text):
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            case .highlightSearch(let pattern): setHighlight(pattern)
            case .ex(let line):
                if exRequested?(line) == false { outcome.failed = true }
            }
        }
        if isInserting { beginUndoGroup() }
        revealCursor()
        syncMode()
        if recordingBefore != store.session.recording { modeDidChange?() }
        return outcome
    }

    private func openCommandLine(_ prompt: Character) {
        if prompt == ":" { commandRequested?() } else { searchRequested?(prompt) }
    }

    // MARK: Applying results

    /// Applies the edits in order; false if the view refused one, which leaves the rest
    /// unapplied since their offsets assume the earlier edits.
    private func applyEdits(_ edits: [TextEdit]) -> Bool {
        guard !edits.isEmpty else { return true }
        beginUndoGroup()
        applyingState = true
        defer { applyingState = false }
        for edit in edits {
            lineMarks?.update(after: edit, in: textStorage?.mutableString ?? NSMutableString())
            guard shouldChangeText(in: edit.range, replacementString: edit.replacement) else {
                return false
            }
            textStorage?.replaceCharacters(
                in: edit.range,
                with: NSAttributedString(string: edit.replacement, attributes: typingAttributes)
            )
            didChangeText()
        }
        return true
    }

    func showSelection(_ ranges: [NSRange]) {
        applyingState = true
        defer { applyingState = false }
        let length = (string as NSString).length
        let valid = ranges.map { range -> NSRange in
            let location = min(range.location, length)
            return NSRange(location: location, length: min(range.length, length - location))
        }
        setSelectedRanges(valid.map { NSValue(range: $0) }, affinity: .downstream,
                          stillSelecting: false)
        needsDisplay = true
    }

    // MARK: Undo

    func beginUndoGroup() {
        guard vimEnabled, !undoGroupOpen else { return }
        breakUndoCoalescing()
        vimUndo.beginUndoGrouping()
        undoGroupOpen = true
    }

    func endUndoGroup() {
        guard undoGroupOpen else { return }
        breakUndoCoalescing()
        vimUndo.endUndoGrouping()
        undoGroupOpen = false
    }

    /// Runs `body` as one undo step: the group opens at the first edit, or is already open
    /// for an insert, and closes when the outermost scope ends outside Insert mode.
    @discardableResult
    func withUndoGroup(_ body: () -> Void) -> Bool {
        if scopeDepth == 0 { replayedKeys = 0 }
        scopeDepth += 1
        let allowed = scopeDepth <= Self.maximumRecursion
        if allowed {
            body()
        } else {
            statusMessage?("E223: Recursive mapping")
        }
        scopeDepth -= 1
        if scopeDepth == 0, !isInserting { endUndoGroup() }
        return allowed
    }

    private func undoSteps(_ count: Int, redo: Bool) {
        endUndoGroup()
        for _ in 0..<count where redo ? vimUndo.canRedo : vimUndo.canUndo {
            redo ? vimUndo.redo() : vimUndo.undo()
        }
    }

    @objc func undo(_ sender: Any?) { undoSteps(1, redo: false) }
    @objc func redo(_ sender: Any?) { undoSteps(1, redo: true) }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) { return vimUndo.canUndo }
        if item.action == #selector(redo(_:)) { return vimUndo.canRedo }
        return super.validateUserInterfaceItem(item)
    }

    /// An edit AppKit makes outside Vim, such as a paste or the find bar's Replace, is its
    /// own undo step.
    override func shouldChangeText(in range: NSRange, replacementString: String?) -> Bool {
        let opensGroup = vimEnabled && !undoGroupOpen && vimUndo.groupingLevel == 0
        if opensGroup { vimUndo.beginUndoGrouping() }
        let allowed = super.shouldChangeText(in: range, replacementString: replacementString)
        if opensGroup && allowed {
            implicitUndoGroup = true
        } else if opensGroup {
            vimUndo.endUndoGrouping()
        }
        return allowed
    }

    override func didChangeText() {
        super.didChangeText()
        if implicitUndoGroup {
            implicitUndoGroup = false
            breakUndoCoalescing()
            vimUndo.endUndoGrouping()
        }
    }

    // MARK: Ex commands

    /// Runs a text ex command on this window as one undo step; false if it failed.
    func runTextCommand(range: ExRange?, command: ExTextCommand) -> Bool {
        var failed = false
        let ran = withUndoGroup {
            let result = ExRunner.run(
                command, range: range, window: vim, session: store.session,
                text: currentBuffer().text,
                clipboard: { NSPasteboard.general.string(forType: .string) }
            )
            failed = finish(result, replayed: false).failed
        }
        return ran && !failed
    }

    /// Plays `:normal` on its lines as `LineReplay` describes.
    private func runLines(_ replay: LineReplay) {
        switch replay.lines {
        case .cursor:
            replayOnce(replay.keys)
        case .numbers(let lines):
            for line in lines {
                let buffer = currentBuffer()
                vim.cursor = buffer.lineRange(at: min(line, buffer.lineCount - 1)).location
                replayOnce(replay.keys)
            }
        case .marked(let lines):
            lineMarks = ExLineMarks(lines: lines, in: currentBuffer())
            while let offset = lineMarks?.next() {
                vim.cursor = offset
                replayOnce(replay.keys)
            }
            lineMarks = nil
        }
    }

    private func replayOnce(_ keys: [VimKey]) {
        _ = play(keys, replayed: true)
        let unfinished = !vim.pendingKeys.isEmpty || vim.mode == .insert
            || vim.mode == .replace || vim.mode == .operatorPending
        if unfinished { _ = play([VimKey(.escape)], replayed: true) }
    }

    // MARK: The footer prompts

    /// Submits the text typed at the `:` prompt, after what the engine typed itself.
    func submitCommand(_ typed: String) {
        feed(typed.map { VimKey(.character($0)) } + [VimKey(.enter)])
    }

    /// Submits the text typed at the `/` or `?` prompt.
    func submitSearch(_ pattern: String, forward: Bool) {
        withUndoGroup {
            let buffer = currentBuffer()
            let result = VimEngine.search(
                pattern, forward: forward, window: vim, session: store.session,
                buffer: buffer, screen: screenGeometry(buffer)
            )
            _ = finish(result, replayed: false)
        }
    }

    /// Closes a prompt without running it; macro recording keeps the keys typed.
    func cancelPrompt(typed: String) {
        feed(typed.map { VimKey(.character($0)) } + [VimKey(.escape)])
    }
}

extension TerminalTextView.Mode {
    init(_ mode: VimMode) {
        switch mode {
        case .normal, .operatorPending, .commandLine: self = .normal
        case .insert: self = .insert
        case .replace: self = .replace
        case .visual: self = .visual
        case .visualLine: self = .visualLine
        case .visualBlock: self = .visualBlock
        }
    }

    var isVisual: Bool { self == .visual || self == .visualLine || self == .visualBlock }
}

extension VimMode {
    init(_ mode: TerminalTextView.Mode) {
        switch mode {
        case .normal: self = .normal
        case .insert: self = .insert
        case .replace: self = .replace
        case .visual: self = .visual
        case .visualLine: self = .visualLine
        case .visualBlock: self = .visualBlock
        }
    }
}

extension VimKey {
    var baseCharacter: Character? {
        if case .character(let character) = base { return character }
        return nil
    }
}
