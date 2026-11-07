import AppKit
import NotepadCore
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let legacyRecoveryURL: URL
    private var recoveryDirectory: URL {
        legacyRecoveryURL.deletingLastPathComponent().appendingPathComponent("Drafts")
    }
    private(set) var editors: [EditorWindow] = []
    private var didLaunch = false
    private var startupFailed = false
    private var pendingOpenURLs: [URL] = []

    init(recoveryURL: URL) { legacyRecoveryURL = recoveryURL }

    private var activeEditor: EditorWindow? {
        editors.first { $0.window === NSApp.keyWindow }
            ?? editors.first { $0.window === NSApp.mainWindow }
            ?? editors.last
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        buildMenu()
        do {
            try restoreWindows()
            didLaunch = true
            let pending = pendingOpenURLs
            pendingOpenURLs = []
            for url in pending { openFile(url) }
            NSApp.activate(ignoringOtherApps: true)
        } catch {
            startupFailed = true
            NSAlert(error: error).runModal()
            NSApp.terminate(nil)
        }
    }

    func restoreWindows() throws {
        for url in try recoveryFiles() { try createWindow(recoveryURL: url) }
        if editors.isEmpty { try createWindow() }
    }

    private func recoveryFiles() throws -> [URL] {
        var files: [URL] = []
        if FileManager.default.fileExists(atPath: legacyRecoveryURL.path) {
            files.append(legacyRecoveryURL)
        }
        do {
            files += try FileManager.default.contentsOfDirectory(
                at: recoveryDirectory, includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return files
        }
        return files
    }

    @discardableResult
    func createWindow(fileURL: URL? = nil, recoveryURL: URL? = nil) throws -> EditorWindow {
        if let fileURL, let existing = try owner(of: fileURL) {
            existing.show()
            return existing
        }
        let recovery = recoveryURL ?? recoveryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
        let editor = try EditorWindow(recoveryURL: recovery)
        editor.canUseFile = { [weak self] editor, url in
            try self?.owner(of: url, excluding: editor) == nil
        }
        editor.onCommand = { [weak self] editor, command in
            self?.execute(command, in: editor)
        }
        editor.onClose = { [weak self] editor in
            self?.editors.removeAll { $0 === editor }
        }
        do {
            if let fileURL { try editor.load(fileURL) }
            else if let restored = editor.documentURL, try owner(of: restored) != nil {
                try editor.detachFromFile()
            }
        } catch {
            editor.window.close()
            throw error
        }
        let previous = activeEditor?.window
        editors.append(editor)
        if let previous {
            let origin = NSPoint(x: previous.frame.minX + 24, y: previous.frame.maxY - 24)
            editor.window.setFrameTopLeftPoint(origin)
        }
        editor.show()
        return editor
    }

    func owner(of url: URL, excluding editor: EditorWindow? = nil) throws -> EditorWindow? {
        for candidate in editors where candidate !== editor {
            if let owned = candidate.documentURL, try sameFile(owned, url) { return candidate }
        }
        return nil
    }

    func execute(_ input: String, in editor: EditorWindow) {
        do {
            switch try VimCommand.parse(input) {
            case let .write(path, force, quit):
                if editor.write(path: path, force: force), quit { editor.close() }
            case let .writeAll(force, quit):
                for candidate in editors where candidate.hasUnsavedChanges {
                    candidate.show()
                    guard candidate.write(force: force) else { return }
                }
                if quit { closeAll(force: false, reportingTo: editor) }
                else { editor.show(); editor.showCommandMessage("All windows saved") }
            case let .quit(all, force):
                if all { closeAll(force: force, reportingTo: editor) }
                else { editor.close(force: force) }
            case .exit:
                if !editor.hasUnsavedChanges || editor.write() { editor.close() }
            case let .edit(path, force): editor.edit(path: path, force: force)
            case .newWindow: try createWindow()
            }
        } catch { editor.showCommandMessage(error.localizedDescription) }
    }

    private func closeAll(force: Bool, reportingTo editor: EditorWindow) {
        if !force, editors.contains(where: { $0.hasUnsavedChanges }) {
            editor.showCommandMessage("E37: An open window has unsaved changes (add ! to discard)")
            return
        }
        for candidate in editors {
            guard candidate.close(force: force) else { return }
        }
    }

    @objc private func newDocument() {
        do { try createWindow() }
        catch { NSAlert(error: error).runModal() }
    }

    @objc private func openDocument() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.plainText, .text]
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { openFile(url) }
    }

    private func openFile(_ url: URL) {
        do { try createWindow(fileURL: url) }
        catch { NSAlert(error: error).runModal() }
    }

    @objc private func saveDocument() { activeEditor?.write() }
    @objc private func saveAs() { activeEditor?.saveAs() }
    @objc private func toggleVim(_ sender: NSMenuItem) { activeEditor?.toggleVim(sender) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleVim(_:)) {
            menuItem.state = activeEditor?.terminal.textView.vimEnabled == true ? .on : .off
            return activeEditor != nil
        }
        if menuItem.action == #selector(saveDocument) || menuItem.action == #selector(saveAs) {
            return activeEditor != nil
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if startupFailed { return .terminateNow }
        for editor in editors {
            guard editor.prepareForApplicationQuit() else { return .terminateCancel }
        }
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { newDocument() }
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        if !didLaunch { pendingOpenURLs += urls }
        else { for url in urls { openFile(url) } }
        sender.reply(toOpenOrPrint: urls.isEmpty ? .failure : .success)
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

}

private func sameFile(_ first: URL, _ second: URL) throws -> Bool {
    let left = first.resolvingSymlinksInPath().standardizedFileURL
    let right = second.resolvingSymlinksInPath().standardizedFileURL
    if left == right { return true }
    guard let leftID = try fileIdentity(left), let rightID = try fileIdentity(right) else {
        return false
    }
    return leftID == rightID
}

private struct FileIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
}

private func fileIdentity(_ url: URL) throws -> FileIdentity? {
    do {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else {
            throw CocoaError(.fileReadUnknown)
        }
        return FileIdentity(device: device.uint64Value, inode: inode.uint64Value)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
        return nil
    }
}
