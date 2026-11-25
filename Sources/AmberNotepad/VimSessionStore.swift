import NotepadCore

/// The state one Vim process shares between its windows: the engine's session (registers,
/// options, last search, recording) and the command histories, which last for the app's run.
@MainActor
final class VimSessionStore {
    private static let historyLimit = 100

    var session = VimSession()
    private var histories: [Character: [String]] = [:]

    func history(for prompt: Character) -> [String] { histories[prompt] ?? [] }

    func remember(_ line: String, prompt: Character) {
        guard !line.isEmpty else { return }
        var list = histories[prompt] ?? []
        list.removeAll { $0 == line }
        list.append(line)
        histories[prompt] = Array(list.suffix(Self.historyLimit))
    }
}
