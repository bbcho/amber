import AppKit

@main
enum AmberNotepad {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        if let iconURL = Bundle.main.url(forResource: "Amber", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            app.applicationIconImage = icon
        }
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        let recovery = support.appendingPathComponent("Amber Notepad/Recovery.json")
        let delegate = AppDelegate(recoveryURL: recovery)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
