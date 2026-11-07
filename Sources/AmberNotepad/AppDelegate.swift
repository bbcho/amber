import AppKit
import NotepadCore
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextViewDelegate {
    private let session: DocumentSession
    private let recoveryURL: URL
    private var window: NSWindow!
    private var terminal: TerminalView!
    private var autosaveTimer: Timer?
    private var saveMessage = "Drafts save automatically"
    private var startupFailed = false
    private var pendingOpenURL: URL?

    init(recoveryURL: URL) {
        self.recoveryURL = recoveryURL
        session = DocumentSession(recoveryURL: recoveryURL)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        do {
            try session.restore()
            showDocument()
            saveMessage = session.url == nil ? "Draft recovery is on" : "Autosave is on"
            updateStatus()
            if let pendingOpenURL {
                self.pendingOpenURL = nil
                open(pendingOpenURL)
            }
        } catch {
            startupFailed = true
            let alert = NSAlert(error: error)
            alert.messageText = "Your previous draft could not be restored"
            alert.informativeText = "The recovery file has been kept at \(recoveryURL.path). "
                + "Move it aside before reopening Amber."
            alert.runModal()
            NSApp.terminate(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildWindow() {
        NSWindow.allowsAutomaticWindowTabbing = false
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "Amber"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .black
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 540, height: 360)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("AmberNotepadWindow")
        terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 1000, height: 720))
        terminal.textView.delegate = self
        terminal.textView.modeDidChange = { [weak self] in self?.updateStatus() }
        window.contentView = terminal
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(terminal.textView)
    }

    private func buildMenu() {
        let main = NSMenu()
        let app = NSMenu(title: "Amber")
        add("About Amber",
            #selector(NSApplication.orderFrontStandardAboutPanel(_:)), to: app)
        app.addItem(.separator())
        add("Hide Amber", #selector(NSApplication.hide(_:)), key: "h", to: app)
        add("Hide Others", #selector(NSApplication.hideOtherApplications(_:)),
            key: "h", modifiers: [.command, .option], to: app)
        add("Show All", #selector(NSApplication.unhideAllApplications(_:)), to: app)
        app.addItem(.separator())
        add("Quit Amber", #selector(NSApplication.terminate(_:)), key: "q", to: app)
        let file = NSMenu(title: "File")
        add("New", #selector(newDocument), key: "n", to: file, target: self)
        add("Open…", #selector(openDocument), key: "o", to: file, target: self)
        file.addItem(.separator())
        add("Save", #selector(saveDocument), key: "s", to: file, target: self)
        add("Save As…", #selector(saveAs), key: "s", modifiers: [.command, .shift],
            to: file, target: self)
        file.addItem(.separator())
        add("Close", #selector(NSWindow.performClose(_:)), key: "w", to: file)
        let edit = NSMenu(title: "Edit")
        add("Undo", Selector(("undo:")), key: "z", to: edit)
        add("Redo", Selector(("redo:")), key: "z", modifiers: [.command, .shift], to: edit)
        edit.addItem(.separator())
        add("Cut", #selector(NSText.cut(_:)), key: "x", to: edit)
        add("Copy", #selector(NSText.copy(_:)), key: "c", to: edit)
        add("Paste", #selector(NSText.paste(_:)), key: "v", to: edit)
        add("Select All", #selector(NSText.selectAll(_:)), key: "a", to: edit)
        edit.addItem(.separator())
        for (title, key, modifiers, action) in [
            ("Find…", "f", NSEvent.ModifierFlags.command, NSTextFinder.Action.showFindInterface),
            ("Find and Replace…", "f", [.command, .option], .showReplaceInterface),
            ("Find Next", "g", .command, .nextMatch),
            ("Find Previous", "g", [.command, .shift], .previousMatch)
        ] {
            let item = NSMenuItem(title: title,
                                  action: #selector(NSTextView.performFindPanelAction(_:)),
                                  keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.tag = action.rawValue
            edit.addItem(item)
        }
        edit.addItem(.separator())
        add("Vim Keybindings", #selector(toggleVim(_:)), to: edit, target: self)
        let windowMenu = NSMenu(title: "Window")
        add("Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m", to: windowMenu)
        add("Zoom", #selector(NSWindow.performZoom(_:)), to: windowMenu)
        for menu in [app, file, edit, windowMenu] {
            let item = NSMenuItem()
            item.submenu = menu
            main.addItem(item)
        }
        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    private func add(
        _ title: String, _ action: Selector, key: String = "",
        modifiers: NSEvent.ModifierFlags = .command, to menu: NSMenu, target: AnyObject? = nil
    ) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        if title == "Vim Keybindings" { item.state = .on }
        menu.addItem(item)
    }

    func textDidChange(_ notification: Notification) {
        session.updateText(terminal.textView.string)
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
            try session.autosave()
            saveMessage = session.url == nil ? "Draft saved locally" : "Saved automatically"
        } catch DocumentFailure.changedOnDisk {
            saveMessage = "File changed outside this app. Draft kept. Press ⌘S to resolve."
        } catch {
            saveMessage = "Autosave failed: \(error.localizedDescription) — press ⌘S"
        }
        updateStatus()
    }

    private func updateStatus() {
        guard terminal != nil else { return }
        let name = session.url?.lastPathComponent ?? "Untitled"
        terminal.filename.stringValue = name + (session.isDirty ? " *" : "")
        window.title = name + " — Amber"
        window.representedURL = session.url
        window.isDocumentEdited = session.isDirty
        let text = terminal.textView.string as NSString
        let offset = min(terminal.textView.selectedRange().location, text.length)
        let prefix = text.substring(to: offset)
        let lines = prefix.components(separatedBy: .newlines)
        let line = prefix.reduce(1) { count, character in
            character.isNewline ? count + 1 : count
        }
        let column = (lines.last?.count ?? 0) + 1
        terminal.position.stringValue = "Ln \(line)   Col \(column)"
        let mode = terminal.textView.vimEnabled ? "[\(terminal.textView.mode.rawValue)]  " : ""
        terminal.status.stringValue = mode + saveMessage
    }

    private func showDocument() {
        autosaveTimer?.invalidate()
        terminal.textView.string = session.file.text
        terminal.textView.setMode(terminal.textView.vimEnabled ? .normal : .insert)
        terminal.textView.undoManager?.removeAllActions()
        terminal.textView.setSelectedRange(NSRange(location: 0, length: 0))
        terminal.textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        saveMessage = session.url == nil ? "Draft recovery is on" : "Autosave is on"
        updateStatus()
        window.makeFirstResponder(terminal.textView)
    }

    @objc private func toggleVim(_ sender: NSMenuItem) {
        terminal.textView.vimEnabled.toggle()
        sender.state = terminal.textView.vimEnabled ? .on : .off
        updateStatus()
    }

    @objc private func newDocument() {
        guard mayReplaceDocument() else { return }
        do {
            try session.reset()
            showDocument()
        } catch { present(error) }
    }

    @objc private func openDocument() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.plainText, .text]
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    private func open(_ url: URL) {
        guard mayReplaceDocument() else { return }
        do {
            try session.open(url)
            showDocument()
        } catch { present(error) }
    }

    private func mayReplaceDocument() -> Bool {
        guard session.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes before opening another document?"
        alert.informativeText = "Your current text will be replaced."
        alert.addButton(withTitle: "Save…")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard Changes")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    @objc private func saveDocument() { _ = save() }
    @objc private func saveAs() { _ = chooseSaveLocation() }

    private func save() -> Bool {
        guard let url = session.url else { return chooseSaveLocation() }
        do {
            try session.save(to: url)
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
        do {
            try session.save(to: url, overwrite: true)
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
                try session.save(to: url, overwrite: true)
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

    private func flushBeforeClosing() -> Bool {
        autosaveTimer?.invalidate()
        do {
            try session.autosave()
            return true
        } catch {
            present(error)
            return false
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { flushBeforeClosing() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        startupFailed || flushBeforeClosing() ? .terminateNow : .terminateCancel
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        guard filenames.count == 1, let filename = filenames.first else {
            let alert = NSAlert()
            alert.messageText = "Open one file at a time"
            alert.runModal()
            sender.reply(toOpenOrPrint: .failure)
            return
        }
        guard window != nil else {
            pendingOpenURL = URL(fileURLWithPath: filename)
            sender.reply(toOpenOrPrint: .success)
            return
        }
        open(URL(fileURLWithPath: filename))
        window.makeKeyAndOrderFront(nil)
        sender.reply(toOpenOrPrint: .success)
    }
}
