import Foundation
@testable import NotepadCore

/// One comparison case: the text with `|` at the cursor, the keys in Vim key notation, and any
/// `:set` arguments (such as `"ic scs"`) that both Vim and the engine start with. The text
/// gets a final line break, which Vim's buffer always has, and a cursor at the start when it
/// has no `|`. Keys must not start with `<Space>`: `:normal!` drops whitespace before them.
struct VimCase {
    let name: String
    let before: String
    let keys: String
    let options: String
    /// Registers that both start with, in key notation: macros, since Vim records only typed
    /// keys and `:normal!` keys are not typed.
    let macros: [Character: String]

    init(_ name: String, _ before: String, _ keys: String, options: String = "",
         macros: [Character: String] = [:]) {
        self.name = name
        let marked = before.contains("|") ? before : "|" + before
        self.before = marked.hasSuffix("\n") ? marked : marked + "\n"
        self.keys = keys
        self.options = options
        self.macros = macros
    }
}

/// What a run leaves behind: the text and the cursor as a UTF-16 offset.
struct VimOutcome: Equatable, CustomStringConvertible {
    let text: String
    let cursor: Int

    var description: String {
        render(text, cursor: cursor, selections: []) + "\n(\(text.debugDescription), \(cursor))"
    }
}

enum VimRunnerError: Error, CustomStringConvertible {
    case vimFailed(String)
    case unreadableResult(String)

    var description: String {
        switch self {
        case .vimFailed(let message): return "vim failed: \(message)"
        case .unreadableResult(let message): return "unreadable vim result: \(message)"
        }
    }
}

/// Runs cases through the real `/usr/bin/vim`, headless, with Amber's option defaults rather
/// than Vim's. Vim is a test tool only; the app never starts it.
struct RealVim {
    static let path = "/usr/bin/vim"

    /// `-u NONE -N` skips vimrc and defaults.vim, so only these options apply.
    private static let defaultOptions = "set ts=4 sw=4 sts=0 et noai tw=0 nf=bin,hex noic "
        + "nosmartcase ws so=0 nomodeline noswapfile"

    /// A folder the runner may write its input and output files in.
    let directory: URL

    func run(_ testCase: VimCase) throws -> VimOutcome {
        let input = directory.appendingPathComponent("input.txt")
        let output = directory.appendingPathComponent("output.txt")
        try? FileManager.default.removeItem(at: output)
        let (text, cursor) = splitCursor(testCase.before)
        try text.write(to: input, atomically: true, encoding: .utf8)
        let (line, column) = Self.position(of: cursor, in: text)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.path)
        var arguments = ["-u", "NONE", "-N", "-i", "NONE", "-es", "--cmd", "set encoding=utf-8",
                         "-c", Self.defaultOptions]
        if !testCase.options.isEmpty { arguments += ["-c", "set \(testCase.options)"] }
        for (register, notation) in testCase.macros.sorted(by: { $0.key < $1.key }) {
            arguments += ["-c", "let @\(register) = \"\(Self.escape(notation))\""]
        }
        let report = "[line('.') . ':' . col('.') . ':' . wordcount().bytes] + getline(1, '$')"
        arguments += [
            "-c", "call cursor(\(line), \(column))",
            "-c", "exe \"norm! \(Self.escape(testCase.keys))\"",
            "-c", "call writefile(\(report), '\(output.path)')",
            "-c", "qa!", input.path,
        ]
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard let data = try? Data(contentsOf: output),
              let result = String(data: data, encoding: .utf8) else {
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8) ?? ""
            throw VimRunnerError.vimFailed("status \(process.terminationStatus) \(message)")
        }
        return try Self.parse(result)
    }

    /// The 1-based line and byte column that Vim's `cursor()` takes for a UTF-16 offset.
    private static func position(of offset: Int, in text: String) -> (line: Int, column: Int) {
        let ns = text as NSString
        let before = ns.substring(to: offset)
        let lineStart = (before as NSString).range(of: "\n", options: .backwards)
        let start = lineStart.location == NSNotFound ? 0 : lineStart.location + 1
        let prefix = ns.substring(with: NSRange(location: start, length: offset - start))
        return (before.filter { $0 == "\n" }.count + 1, prefix.utf8.count + 1)
    }

    /// Key notation as the inside of a double-quoted Vim string: `<Esc>` becomes `\<Esc>`, and
    /// a non-ASCII character becomes a `\U` escape.
    private static func escape(_ notation: String) -> String {
        var result = ""
        var rest = Substring(notation)
        while let character = rest.first {
            if character == "<", let close = rest.firstIndex(of: ">") {
                result += "\\" + rest[...close]
                rest = rest[rest.index(after: close)...]
                continue
            }
            if character == "\"" || character == "\\" { result += "\\" }
            for scalar in character.unicodeScalars {
                // Process may re-normalize non-ASCII arguments, so spell them as code points.
                result += scalar.isASCII ? String(scalar)
                    : "\\U" + String(format: "%08x", scalar.value)
            }
            rest = rest.dropFirst()
        }
        return result
    }

    private static func parse(_ result: String) throws -> VimOutcome {
        var lines = result.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard let first = lines.first else { throw VimRunnerError.unreadableResult(result) }
        let numbers = first.split(separator: ":").compactMap { Int($0) }
        guard numbers.count == 3 else { throw VimRunnerError.unreadableResult(first) }
        let text = Array(lines.dropFirst())
        let cursorLine = numbers[0] - 1
        guard text.indices.contains(cursorLine) else {
            throw VimRunnerError.unreadableResult(first)
        }
        let before = text[..<cursorLine].reduce(0) { $0 + ($1 as NSString).length + 1 }
        let bytes = Array(text[cursorLine].utf8.prefix(numbers[1] - 1))
        let column = (String(decoding: bytes, as: UTF8.self) as NSString).length
        let joined = numbers[2] == 0 ? "" : text.joined(separator: "\n") + "\n"
        return VimOutcome(text: joined, cursor: before + column)
    }
}

/// Runs cases through the engine the way `:normal!` runs keys: ex commands run, and the keys
/// after one that fails are dropped, as Vim flushes them.
enum AmberEngine {
    static func run(_ testCase: VimCase) throws -> VimOutcome {
        var session = VimSession()
        if !testCase.options.isEmpty { try session.options.set(testCase.options) }
        for (register, notation) in testCase.macros {
            session.registers.storeMacro(notation, in: register)
        }
        var driver = VimDriver(testCase.before, session: session)
        driver.runsExCommands = true
        for key in try VimKey.parse(testCase.keys) {
            let seen = driver.effects.count
            driver.feed([key], replayed: false)
            if driver.effects[seen...].contains(.failure) { break }
        }
        let unfinished = !driver.window.pendingKeys.isEmpty || driver.window.mode == .insert
            || driver.window.mode == .replace || driver.window.mode == .operatorPending
        if unfinished { driver.feed([VimKey(.escape)], replayed: false) }
        return VimOutcome(text: driver.text as String, cursor: driver.window.cursor)
    }
}
