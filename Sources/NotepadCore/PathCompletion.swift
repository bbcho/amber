import Foundation

/// Completes the path argument of a file command typed in the command line.
public enum PathCompletion {
    private static let pathCommands: Set<String> = ["e", "edit", "w", "write", "wq", "wquit"]

    /// Full command lines that complete `input`, in display order. Relative paths start in
    /// `directory`; an empty path offers `recent` files.
    public static func candidates(
        for input: String, relativeTo directory: URL, recent: [URL]
    ) -> [String] {
        let leading = input.prefix { $0 == ":" || $0.isWhitespace }
        let rest = input.dropFirst(leading.count)
        let token = rest.prefix { !$0.isWhitespace }
        let name = token.hasSuffix("!") ? token.dropLast() : token
        guard pathCommands.contains(String(name)) else { return [] }
        let argument = rest.dropFirst(token.count).drop { $0.isWhitespace }
        let head = leading + token + " "
        guard !argument.isEmpty else { return recent.map { head + $0.path } }

        let typed = String(argument)
        let slash = typed.lastIndex(of: "/")
        let folderPart = slash.map { String(typed[...$0]) } ?? ""
        let prefix = slash.map { String(typed[typed.index(after: $0)...]) } ?? typed
        let expanded = (folderPart as NSString).expandingTildeInPath
        let folder = expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded)
            : directory.appendingPathComponent(expanded)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }
        return entries
            .filter { entry in
                let entryName = entry.lastPathComponent
                let visible = prefix.hasPrefix(".") || !entryName.hasPrefix(".")
                return visible && entryName.hasPrefix(prefix)
            }
            .map { entry -> String in
                let isFolder = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
                return entry.lastPathComponent + (isFolder == true ? "/" : "")
            }
            .sorted()
            .map { head + folderPart + $0 }
    }
}
