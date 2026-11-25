import AppKit
import NotepadCore
import UniformTypeIdentifiers

@MainActor
final class EditorWindow: NSObject, NSWindowDelegate, NSTextViewDelegate {
    let window: NSWindow
    let terminal: TerminalView
    let vimSession: VimSessionStore
    private let session: DocumentSession
    private var autosaveTimer: Timer?
    private var saveMessage = "Draft recovery is on"
    private var diskTimer: Timer?
    /// Set when undo brings back text from before an outside change: autosave then keeps it
    /// in recovery only, so the outside change on disk is replaced only by an explicit save.
    private var autosaveHeld = false
    private var commandMessage: String?
    private var discardOnClose = false
    var onClose: ((EditorWindow) -> Void)?
    var onCommand: ((EditorWindow, String) -> Bool)?
    /// Called whenever the window starts editing a different file on disk.
    var onFileUsed: ((EditorWindow, URL) -> Void)?
    var recentFiles: (() -> [URL])?
    private var reportedURL: URL?
    var canUseFile: ((EditorWindow, URL) throws -> Bool)?

    var documentURL: URL? { session.url }
    var hasUnsavedChanges: Bool { session.isDirty }
    var isShowingMarkdown: Bool { terminal.isShowingMarkdown }

    init(recoveryURL: URL, vimSession: VimSessionStore? = nil) throws {
        self.vimSession = vimSession ?? VimSessionStore()
        let restoredSession = DocumentSession(recoveryURL: recoveryURL)
        try restoredSession.restore()
        session = restoredSession
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 1000, height: 720))
        super.init()
        window.title = "Amber"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .black
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 540, height: 360)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName(
            "Amber-" + recoveryURL.deletingPathExtension().lastPathComponent
        )
        terminal.textView.store = self.vimSession
        terminal.applyDisplayOptions()
        terminal.textView.delegate = self
        terminal.textView.modeDidChange = { [weak self] in self?.updateStatus() }
        terminal.textView.statusMessage = { [weak self] in self?.showCommandMessage($0) }
        terminal.completeCommand = { [weak self] input in
            guard let self else { return [] }
            return PathCompletion.candidates(
                for: input,
                relativeTo: self.documentURL?.deletingLastPathComponent()
                    ?? FileManager.default.homeDirectoryForCurrentUser,
                recent: self.recentFiles?() ?? []
            )
        }
        terminal.commandSubmitted = { [weak self] command in
            guard let self else { return }
            self.commandMessage = nil
            _ = self.onCommand?(self, command)
        }
        terminal.commandRun = { [weak self] command in
            guard let self else { return false }
            return self.onCommand?(self, command) ?? false
        }
        window.contentView = terminal
        window.center()
        showDocument()
        diskTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkDisk(waitForQuiet: true) }
        }
    }

    /// Shows changes made to the file outside Amber, such as an agent's edits, like Vim's
    /// `autoread`: clean text reloads, and unsaved edits are never replaced.
    func checkDisk(waitForQuiet: Bool = false) {
        if waitForQuiet, !vimSession.session.options.autoread { return }
        do {
            switch try session.checkDisk(waitForQuiet: waitForQuiet) {
            case .unchanged:
                return
            case .reloaded:
                terminal.textView.resetForOutsideChange()
                let undo = terminal.textView.undoManager
                terminal.textView.breakUndoCoalescing()
                undo?.beginUndoGrouping()
                terminal.replaceSourceText(session.file.text)
                undo?.registerUndo(withTarget: self) { $0.reloadWasUndone() }
                undo?.endUndoGrouping()
                autosaveTimer?.invalidate()
                if terminal.isShowingMarkdown {
                    terminal.updateMarkdown(MarkdownRenderer.render(session.file.text))
                }
                saveMessage = "Reloaded: the file changed outside Amber"
            case .conflict:
                saveMessage = "File changed outside this app. Draft kept. Press ⌘S to resolve."
            case .missing:
                saveMessage = "File was deleted outside this app. Your text is kept."
            }
            updateStatus()
        } catch {
            showCommandMessage("Could not reload: \(error.localizedDescription)")
        }
    }

    private func reloadWasUndone() {
        autosaveHeld = true
        terminal.textView.undoManager?.registerUndo(withTarget: self) { $0.reloadWasRedone() }
    }

    private func reloadWasRedone() {
        terminal.textView.undoManager?.registerUndo(withTarget: self) { $0.reloadWasUndone() }
    }

    /// Every explicit save goes through here: it is the user's choice, so it ends the hold.
    private func saveFile(to url: URL, overwrite: Bool = false) throws {
        try session.save(to: url, overwrite: overwrite)
        autosaveHeld = false
    }

    /// Autosave that respects `autosaveHeld`.
    private func persistDraft() throws {
        if autosaveHeld, session.isDirty { try session.saveRecovery() }
        else { try session.autosave() }
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        terminal.needsLayout = true
        terminal.layoutSubtreeIfNeeded()
        window.makeFirstResponder(terminal.textView)
    }

    func load(_ url: URL) throws {
        try session.open(url)
        showDocument()
    }

    func detachFromFile() throws {
        try session.detachFromFile()
        reportedURL = nil
        showDocument()
        showCommandMessage("Recovered copy: original file is already open in another window")
    }

    func toggleVim(_ sender: NSMenuItem) {
        terminal.textView.vimEnabled.toggle()
        sender.state = terminal.textView.vimEnabled ? .on : .off
        updateStatus()
    }

    func toggleMarkdown() {
        if terminal.isShowingMarkdown {
            terminal.showSource()
        } else {
            terminal.showMarkdown(MarkdownRenderer.render(terminal.textView.string))
        }
        updateStatus()
    }

    func showCommandMessage(_ message: String) {
        commandMessage = message
        updateStatus()
    }

    private func mayUseFile(_ url: URL) -> Bool {
        do {
            guard try canUseFile?(self, url) ?? true else {
                showCommandMessage("E95: File is already open in another window")
                return false
            }
            return true
        } catch { showCommandMessage(error.localizedDescription); return false }
    }

    private func fileURL(for path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded) }
        let directory = documentURL?.deletingLastPathComponent()
            ?? FileManager.default.homeDirectoryForCurrentUser
        return directory.appendingPathComponent(expanded).standardizedFileURL
    }

    @discardableResult
    func write(path: String? = nil, force: Bool = false) -> Bool {
        guard let path else {
            if !force || session.url == nil { return save() }
            guard let url = session.url, mayUseFile(url) else { return false }
            do {
                try saveFile(to: url, overwrite: true)
                saveMessage = "Saved"
                updateStatus()
                return true
            } catch { showCommandMessage(error.localizedDescription); return false }
        }
        let url = fileURL(for: path).resolvingSymlinksInPath()
        guard mayUseFile(url) else { return false }
        if url != documentURL, !force, FileManager.default.fileExists(atPath: url.path) {
            showCommandMessage("E13: File exists (add ! to overwrite)")
            return false
        }
        do {
            try saveFile(to: url, overwrite: force)
            saveMessage = "Saved — autosave is on"
            updateStatus()
            return true
        } catch { showCommandMessage(error.localizedDescription); return false }
    }

    func edit(path: String?, force: Bool) {
        if session.isDirty, !force {
            showCommandMessage("E37: No write since last change (add ! to discard)")
            return
        }
        let url: URL
        if let path { url = fileURL(for: path) }
        else if let current = documentURL { url = current }
        else {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.allowedContentTypes = [.plainText, .text]
            panel.allowsOtherFileTypes = true
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            url = chosen
        }
        guard mayUseFile(url) else { return }
        do { try load(url) }
        catch { showCommandMessage(error.localizedDescription) }
    }

    @discardableResult
    func close(force: Bool = false) -> Bool {
        if session.isDirty, !force {
            showCommandMessage("E37: No write since last change (add ! to discard)")
            return false
        }
        discardOnClose = force
        window.performClose(nil)
        return !window.isVisible
    }

    func prepareForApplicationQuit() -> Bool {
        autosaveTimer?.invalidate()
        do { try persistDraft(); return true }
        catch { present(error); return false }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        defer { discardOnClose = false }
        if !discardOnClose, session.isDirty, !mayCloseDocument() { return false }
        autosaveTimer?.invalidate()
        do {
            if !discardOnClose, !session.isDirty { try session.autosave() }
            try session.removeRecovery()
            return true
        } catch { present(error); return false }
    }

    func windowWillClose(_ notification: Notification) {
        diskTimer?.invalidate()
        onClose?(self)
    }

    func textDidChange(_ notification: Notification) {
        commandMessage = nil
        session.updateText(terminal.textView.string)
        if !session.isDirty { autosaveHeld = false }
        saveMessage = "Saving…"
        updateStatus()
        autosaveTimer?.invalidate()
        autosaveTimer = Timer.scheduledTimer(
            withTimeInterval: 0.6, repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.autosave() }
        }
    }

    func textViewDidChangeSelection(_ notification: Notification) { updateStatus() }

    private func autosave() {
        do {
            try persistDraft()
            if autosaveHeld, session.isDirty {
                saveMessage = "Undo brought back text from before the outside change. "
                    + "Press ⌘S to save it over the file."
            } else {
                saveMessage = session.url == nil ? "Draft saved locally" : "Saved automatically"
            }
        } catch DocumentFailure.changedOnDisk {
            saveMessage = "File changed outside this app. Draft kept. Press ⌘S to resolve."
        } catch {
            saveMessage = "Autosave failed: \(error.localizedDescription) — press ⌘S"
        }
        updateStatus()
    }

    private func updateStatus() {
        if let url = session.url, url != reportedURL {
            reportedURL = url
            onFileUsed?(self, url)
        }
        let name = session.url?.lastPathComponent ?? "Untitled"
        terminal.filename.stringValue = name + (session.isDirty ? " *" : "")
        window.title = name + " — Amber"
        window.representedURL = session.url
        window.isDocumentEdited = session.isDirty
        let (line, column) = terminal.textView.cursorPosition()
        terminal.position.stringValue = "Ln \(line)   Col \(column)"
        var mode = terminal.textView.vimEnabled ? vimStatus() : ""
        if terminal.isShowingMarkdown {
            terminal.position.stringValue = "Rendered"
            mode = "[RENDERED]  "
        }
        terminal.status.stringValue = mode + (commandMessage ?? saveMessage)
    }

    private func vimStatus() -> String {
        let detail = terminal.textView.statusDetail
        return "[\(terminal.textView.mode.rawValue)]  " + (detail.isEmpty ? "" : detail + "  ")
    }

    private func showDocument() {
        autosaveTimer?.invalidate()
        autosaveHeld = false
        commandMessage = nil
        terminal.showSource()
        terminal.textView.string = session.file.text
        terminal.textView.setMode(terminal.textView.vimEnabled ? .normal : .insert)
        terminal.textView.undoManager?.removeAllActions()
        terminal.textView.setSelectedRange(NSRange(location: 0, length: 0))
        terminal.textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        saveMessage = session.url == nil ? "Draft recovery is on" : "Autosave is on"
        updateStatus()
        window.makeFirstResponder(terminal.textView)
    }

    private func mayCloseDocument() -> Bool {
        guard session.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes before closing this window?"
        alert.informativeText = "Unsaved changes will be discarded if you close without saving."
        alert.addButton(withTitle: "Save…")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard Changes")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    func saveAs() { _ = chooseSaveLocation() }

    private func save() -> Bool {
        guard let url = session.url else { return chooseSaveLocation() }
        guard mayUseFile(url) else { return false }
        do {
            try saveFile(to: url)
            saveMessage = "Saved"
            updateStatus()
            return true
        } catch DocumentFailure.changedOnDisk {
            return resolveConflict(url)
        } catch {
            present(error)
            return false
        }
    }

    private func chooseSaveLocation() -> Bool {
        let panel = NSSavePanel()
        panel.title = "Save your document"
        panel.nameFieldStringValue = session.url?.lastPathComponent ?? "Untitled.txt"
        panel.directoryURL = session.url?.deletingLastPathComponent()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        guard mayUseFile(url) else { return false }
        do {
            try saveFile(to: url, overwrite: true)
            saveMessage = "Saved — autosave is on"
            updateStatus()
            return true
        } catch {
            present(error)
            return false
        }
    }

    private func resolveConflict(_ url: URL) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "This file changed outside Amber"
        alert.informativeText = "Your edits are kept in recovery. Save a separate copy, "
            + "or deliberately replace the file on disk with your text."
        alert.addButton(withTitle: "Save As…")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Replace File")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return chooseSaveLocation()
        case .alertThirdButtonReturn:
            do {
                try saveFile(to: url, overwrite: true)
                saveMessage = "Saved"
                updateStatus()
                return true
            } catch { present(error); return false }
        default: return false
        }
    }

    private func present(_ error: Error) {
        saveMessage = "Save or open failed — your current text is still here"
        updateStatus()
        NSAlert(error: error).runModal()
    }

}
