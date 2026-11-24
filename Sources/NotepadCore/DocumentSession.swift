import Foundation

/// What `DocumentSession.checkDisk()` found on disk.
public enum DiskChange: Equatable {
    case unchanged
    /// Clean text was replaced with the file's new contents.
    case reloaded
    /// The file changed, but unsaved edits were kept.
    case conflict
    case missing
}

public final class DocumentSession {
    private struct DiskStamp: Equatable {
        let modified: Date?
        let size: Int?
    }

    private struct Snapshot: Codable {
        var file = TextFile()
        var url: URL?
        var savedBytes: Data?
    }

    private var snapshot = Snapshot()
    private let recoveryURL: URL
    private var diskStamp: DiskStamp?

    public var file: TextFile { snapshot.file }
    public var url: URL? { snapshot.url }
    public var isDirty: Bool {
        guard let saved = snapshot.savedBytes else { return !file.text.isEmpty }
        return (try? file.encoded()) != saved
    }

    public init(recoveryURL: URL) {
        self.recoveryURL = recoveryURL
    }

    public func restore() throws {
        guard FileManager.default.fileExists(atPath: recoveryURL.path) else { return }
        let recovered = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: recoveryURL))
        snapshot = recovered
        // When recovery was clean, prefer newer on-disk contents on the next launch.
        if !isDirty, let url, let bytes = try? Data(contentsOf: url),
           let latest = try? TextFile.decode(bytes) {
            snapshot = Snapshot(file: latest, url: url, savedBytes: bytes)
        }
        diskStamp = url.flatMap(Self.stamp)
    }

    public func open(_ url: URL) throws {
        let resolved = url.resolvingSymlinksInPath()
        let bytes = try Data(contentsOf: resolved)
        let next = Snapshot(file: try TextFile.decode(bytes), url: resolved, savedBytes: bytes)
        try writeRecovery(next)
        snapshot = next
        diskStamp = Self.stamp(resolved)
    }

    /// Reloads the file when it changed outside Amber and there are no unsaved edits.
    /// Bytes equal to Amber's last save are not a change, so autosave never triggers this.
    public func checkDisk() throws -> DiskChange {
        guard let url else { return .unchanged }
        guard let current = Self.stamp(url) else { return .missing }
        guard current != diskStamp else { return .unchanged }
        let bytes = try Data(contentsOf: url)
        if bytes == snapshot.savedBytes {
            diskStamp = current
            return .unchanged
        }
        if isDirty { return .conflict }
        let next = Snapshot(file: try TextFile.decode(bytes), url: url, savedBytes: bytes)
        try writeRecovery(next)
        snapshot = next
        diskStamp = current
        return .reloaded
    }

    public func updateText(_ text: String) {
        snapshot.file.text = text
    }

    public func autosave() throws {
        try writeRecovery(snapshot)
        if let url, isDirty { try save(to: url) }
    }

    public func save(to destination: URL, overwrite: Bool = false) throws {
        try writeRecovery(snapshot)
        let resolved = destination.resolvingSymlinksInPath()
        if resolved == url, !overwrite {
            guard let actual = try? Data(contentsOf: resolved), actual == snapshot.savedBytes else {
                throw DocumentFailure.changedOnDisk
            }
        }
        let bytes = try file.encoded()
        try bytes.write(to: resolved, options: .atomic)
        snapshot.url = resolved
        snapshot.savedBytes = bytes
        diskStamp = Self.stamp(resolved)
        try writeRecovery(snapshot)
    }

    public func reset() throws {
        let empty = Snapshot()
        try writeRecovery(empty)
        snapshot = empty
    }

    public func removeRecovery() throws {
        if FileManager.default.fileExists(atPath: recoveryURL.path) {
            try FileManager.default.removeItem(at: recoveryURL)
        }
    }

    public func detachFromFile() throws {
        let detached = Snapshot(file: file, url: nil, savedBytes: nil)
        try writeRecovery(detached)
        snapshot = detached
    }

    private static func stamp(_ url: URL) -> DiskStamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return DiskStamp(
            modified: attributes[.modificationDate] as? Date,
            size: (attributes[.size] as? NSNumber)?.intValue
        )
    }

    private func writeRecovery(_ value: Snapshot) throws {
        try FileManager.default.createDirectory(
            at: recoveryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let bytes = try JSONEncoder().encode(value)
        try bytes.write(to: recoveryURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: recoveryURL.path
        )
    }
}
