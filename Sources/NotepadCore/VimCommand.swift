import Foundation

public enum VimCommand: Equatable {
    case write(path: String?, force: Bool, quit: Bool)
    case writeAll(force: Bool, quit: Bool)
    case quit(all: Bool, force: Bool)
    case exit
    case edit(path: String?, force: Bool)
    case newWindow

    public static func parse(_ input: String) throws -> VimCommand {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.hasPrefix(":") ? String(trimmed.dropFirst()) : trimmed
        let parts = body.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        guard let first = parts.first else { throw VimCommandError.empty }
        let token = String(first)
        let force = token.hasSuffix("!")
        let name = force ? String(token.dropLast()) : token
        let argument = parts.count == 2
            ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let path = argument.isEmpty ? nil : argument

        switch name {
        case "w", "write":
            return .write(path: path, force: force, quit: false)
        case "wq", "wquit":
            return .write(path: path, force: force, quit: true)
        case "e", "edit":
            return .edit(path: path, force: force)
        default:
            break
        }

        let command: VimCommand
        switch name {
        case "wa", "wall":
            command = .writeAll(force: force, quit: false)
        case "wqa", "wqall":
            command = .writeAll(force: force, quit: true)
        case "q", "quit":
            command = .quit(all: false, force: force)
        case "qa", "qall":
            command = .quit(all: true, force: force)
        case "x", "exit":
            guard !force else { throw VimCommandError.unknown(token) }
            command = .exit
        case "new":
            guard !force else { throw VimCommandError.unknown(token) }
            command = .newWindow
        default:
            throw VimCommandError.unknown(token)
        }
        guard path == nil else { throw VimCommandError.trailing(argument) }
        return command
    }
}

private enum VimCommandError: LocalizedError {
    case empty
    case unknown(String)
    case trailing(String)

    var errorDescription: String? {
        switch self {
        case .empty:
            return "Empty command"
        case .unknown(let command):
            return "E492: Not an editor command: \(command)"
        case .trailing(let argument):
            return "E488: Trailing characters: \(argument)"
        }
    }
}
