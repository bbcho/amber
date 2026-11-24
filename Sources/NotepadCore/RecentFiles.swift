import Foundation

/// The files most recently opened or saved, newest first.
public struct RecentFiles: Codable, Equatable {
    public static let limit = 10
    public private(set) var urls: [URL] = []

    public init() {}

    public func adding(_ url: URL) -> RecentFiles {
        var next = self
        next.urls = Array(([url] + urls.filter { $0 != url }).prefix(Self.limit))
        return next
    }

    /// A missing or unreadable list starts empty: recents are a convenience, never a blocker.
    public static func load(from file: URL) -> RecentFiles {
        guard let data = try? Data(contentsOf: file),
              let recent = try? JSONDecoder().decode(RecentFiles.self, from: data) else {
            return RecentFiles()
        }
        return recent
    }

    public func save(to file: URL) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try JSONEncoder().encode(self).write(to: file, options: .atomic)
    }
}
