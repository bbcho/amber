import Foundation

/// A file command, which the app runs: it reads and writes files and opens and closes
/// windows.
public enum VimCommand: Equatable {
    case write(path: String?, force: Bool, quit: Bool)
    case writeAll(force: Bool, quit: Bool)
    case quit(all: Bool, force: Bool)
    case exit
    case edit(path: String?, force: Bool)
    case newWindow
}

/// One ex command line, as typed after `:`.
public enum ExCommand: Equatable {
    case file(VimCommand)
    /// `:set` and its arguments, for `VimOptions.set`, which the app applies to the session
    /// so that every window sees the change.
    case set(String)
    /// `:mm`, which toggles the Markdown preview.
    case markdown
    case checkTime
    /// A command that `ExRunner` runs on the text. A nil range means none was typed.
    case text(range: ExRange?, command: ExTextCommand)

    /// Parses one command line: an optional `:`, a range, a command name, an optional `!`
    /// and the command's argument. Errors use Vim's wording. Blanks at the end are kept, as
    /// they can be keys for `:norm` or a `:s` replacement; the file commands drop them.
    public static func parse(_ line: String) throws -> ExCommand {
        var trimmed = Substring(line.drop(while: \.isWhitespace))
        while trimmed.last?.isNewline == true { trimmed.removeLast() }
        let body = String(trimmed.hasPrefix(":") ? trimmed.dropFirst() : trimmed)
        var scanner = ExScanner(body)
        scanner.skipBlanks()
        guard !scanner.atEnd else { throw VimError("Empty command") }
        let unknown = VimError("E492: Not an editor command: \(scanner.rest)")
        let range = try scanner.range()
        scanner.skipBlanks()
        let name = scanner.commandName()
        if fileCommandNames.contains(name) {
            guard range == nil else { throw VimError("E481: No range allowed") }
            return try fileCommand(body)
        }
        if name.isEmpty {
            guard scanner.atEnd, let range else { throw unknown }
            return .text(range: range, command: .goTo)
        }
        let bang = scanner.take("!")
        scanner.skipBlanks()
        let argument = ExArgument(name: name, bang: bang, text: scanner.rest)
        if name.count >= 2 && "set".hasPrefix(name) {
            guard range == nil else { throw VimError("E481: No range allowed") }
            try argument.refuseBang()
            return .set(argument.text)
        }
        guard let kind = ExCommandName.named(name) else { throw unknown }
        let command = try kind.command(argument)
        if range != nil, [.noHighlight, .undo, .redo].contains(command) {
            throw VimError("E481: No range allowed")
        }
        return .text(range: range, command: command)
    }

    private static let fileCommandNames: Set<String> = [
        "w", "write", "wq", "wquit", "wa", "wall", "wqa", "wqall", "q", "quit", "qa", "qall",
        "x", "exit", "e", "edit", "new", "mm", "checkt", "checkti", "checktim", "checktime",
    ]

    /// The file commands and `:mm` and `:checktime`, which keep the wording and the exact
    /// names they had before ex commands grew ranges.
    private static func fileCommand(_ body: String) throws -> ExCommand {
        let parts = body.trimmingCharacters(in: .whitespaces)
            .split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        guard let first = parts.first else { throw VimError("Empty command") }
        let token = String(first)
        let force = token.hasSuffix("!")
        let name = force ? String(token.dropLast()) : token
        let argument = parts.count == 2
            ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let path = argument.isEmpty ? nil : argument
        let unknown = VimError("E492: Not an editor command: \(token)")

        switch name {
        case "w", "write": return .file(.write(path: path, force: force, quit: false))
        case "wq", "wquit": return .file(.write(path: path, force: force, quit: true))
        case "e", "edit": return .file(.edit(path: path, force: force))
        default: break
        }

        let command: ExCommand
        switch name {
        case "wa", "wall": command = .file(.writeAll(force: force, quit: false))
        case "wqa", "wqall": command = .file(.writeAll(force: force, quit: true))
        case "q", "quit": command = .file(.quit(all: false, force: force))
        case "qa", "qall": command = .file(.quit(all: true, force: force))
        case "x", "exit", "new", "mm", "checkt", "checkti", "checktim", "checktime":
            guard !force else { throw unknown }
            switch name {
            case "x", "exit": command = .file(.exit)
            case "new": command = .file(.newWindow)
            case "mm": command = .markdown
            default: command = .checkTime
            }
        default:
            throw unknown
        }
        guard path == nil else { throw VimError("E488: Trailing characters: \(argument)") }
        return command
    }
}

/// The addresses typed before a command, unresolved. Vim keeps the last two.
public struct ExRange: Equatable {
    public var addresses: [ExAddress]

    public init(addresses: [ExAddress]) {
        self.addresses = addresses
    }
}

public struct ExAddress: Equatable {
    public enum Base: Equatable {
        case current
        case last
        /// A line number counted from 1; 0 is the line before the first.
        case line(Int)
        case mark(Character)
        /// `/pat/` or `?pat?`, each search starting from the line the one before found.
        case search([ExSearch])
    }

    public var base: Base
    public var offset: Int
    /// Followed by `;`, which moves the cursor to this line before the next address.
    public var movesCursor: Bool

    public init(_ base: Base, offset: Int = 0, movesCursor: Bool = false) {
        self.base = base
        self.offset = offset
        self.movesCursor = movesCursor
    }
}

public struct ExSearch: Equatable {
    /// Empty for the last search pattern.
    public var pattern: String
    public var forward: Bool

    public init(pattern: String, forward: Bool) {
        self.pattern = pattern
        self.forward = forward
    }
}

/// The flags of `:s`.
public struct SubstituteFlags: Equatable {
    /// `&`: the flags of the last substitute come first.
    public var keepFlags = false
    /// `g`, which each repetition toggles.
    public var global = false
    /// `i` (true) or `I` (false); nil follows `ignorecase` and `smartcase`.
    public var ignoreCase: Bool?
    /// `n`: count the matches instead of replacing them.
    public var countOnly = false
    /// `e`: a pattern that is not found is not an error.
    public var noError = false

    public init(keepFlags: Bool = false, global: Bool = false, ignoreCase: Bool? = nil,
                countOnly: Bool = false, noError: Bool = false) {
        self.keepFlags = keepFlags
        self.global = global
        self.ignoreCase = ignoreCase
        self.countOnly = countOnly
        self.noError = noError
    }
}

/// `:s/pattern/replacement/flags count`, or with a nil pattern and replacement, `:s`, `:&`
/// and `:&&`, which repeat the last substitute.
public struct ExSubstitute: Equatable {
    /// Empty for the last search pattern.
    public var pattern: String?
    public var replacement: String?
    public var flags: SubstituteFlags
    public var count: Int?

    public init(pattern: String?, replacement: String?, flags: SubstituteFlags, count: Int?) {
        self.pattern = pattern
        self.replacement = replacement
        self.flags = flags
        self.count = count
    }
}

/// `:sort` with `!` (reverse), `i`, `n`, `u`, `r` and a pattern.
public struct ExSort: Equatable {
    public var reverse: Bool
    public var ignoreCase: Bool
    public var numeric: Bool
    public var unique: Bool
    /// `r`: sort on the pattern's match rather than on what follows it.
    public var onMatch: Bool
    /// Empty for the last search pattern; nil for none.
    public var pattern: String?

    public init(reverse: Bool = false, ignoreCase: Bool = false, numeric: Bool = false,
                unique: Bool = false, onMatch: Bool = false, pattern: String? = nil) {
        self.reverse = reverse
        self.ignoreCase = ignoreCase
        self.numeric = numeric
        self.unique = unique
        self.onMatch = onMatch
        self.pattern = pattern
    }
}

/// An ex command that changes or reads the text.
public enum ExTextCommand: Equatable {
    /// A range alone, `:{n}`: go to its last line.
    case goTo
    case delete(register: Character?, count: Int?)
    case yank(register: Character?, count: Int?)
    case move(to: ExAddress)
    /// `:t` and `:co`.
    case copy(to: ExAddress)
    /// `:j`, and `:j!` without `spaces`.
    case join(spaces: Bool, count: Int?)
    /// `:>` and `:<`, repeated `amount` times.
    case shift(left: Bool, amount: Int, count: Int?)
    case substitute(ExSubstitute)
    /// `:g`, and `:g!` and `:v` without `matching`. An empty command lists the lines.
    case global(pattern: String, matching: Bool, command: String)
    /// `:norm`, whose keys are the typed characters.
    case normal(keys: String)
    case sort(ExSort)
    /// `:retab`, and with `bang`, `:retab!`.
    case retab(bang: Bool)
    case noHighlight
    case undo
    case redo
    /// `:pu`, and `:pu!` when `above`.
    case put(register: Character?, above: Bool)
}

/// The text commands by name, with Vim's shortest abbreviations.
private enum ExCommandName {
    case delete, yank, move, copy, join, shift, substitute, repeatSubstitute, global
    case vglobal, normal, sort, retab, noHighlight, undo, redo, put

    private static let names: [(name: String, shortest: Int, kind: ExCommandName)] = [
        ("delete", 1, .delete), ("yank", 1, .yank), ("move", 1, .move), ("copy", 2, .copy),
        ("t", 1, .copy), ("join", 1, .join), ("substitute", 1, .substitute),
        ("global", 1, .global), ("vglobal", 1, .vglobal), ("normal", 4, .normal),
        ("sort", 3, .sort), ("retab", 3, .retab), ("nohlsearch", 3, .noHighlight),
        ("undo", 1, .undo), ("redo", 3, .redo), ("put", 2, .put),
    ]

    static func named(_ name: String) -> ExCommandName? {
        if name == "&" { return .repeatSubstitute }
        if name.allSatisfy({ $0 == ">" }) || name.allSatisfy({ $0 == "<" }) { return .shift }
        return names.first { name.count >= $0.shortest && $0.name.hasPrefix(name) }?.kind
    }

    func command(_ argument: ExArgument) throws -> ExTextCommand {
        switch self {
        case .delete, .yank:
            try argument.refuseBang()
            let (register, count) = try argument.registerAndCount()
            return self == .delete ? .delete(register: register, count: count)
                : .yank(register: register, count: count)
        case .move, .copy:
            try argument.refuseBang()
            let target = try argument.address()
            return self == .move ? .move(to: target) : .copy(to: target)
        case .join:
            return .join(spaces: !argument.bang, count: try argument.countOnly())
        case .shift:
            try argument.refuseBang()
            return .shift(left: argument.name.first == "<", amount: argument.name.count,
                          count: try argument.countOnly())
        case .substitute, .repeatSubstitute:
            try argument.refuseBang()
            return .substitute(try argument.substitute(repeating: self == .repeatSubstitute))
        case .global, .vglobal:
            return try argument.global(matching: self == .global && !argument.bang)
        case .normal:
            guard !argument.text.isEmpty else { throw VimError("E471: Argument required") }
            return .normal(keys: argument.text)
        case .sort:
            return .sort(try argument.sort())
        case .retab:
            try argument.retab()
            return .retab(bang: argument.bang)
        case .noHighlight:
            try argument.refuseBangAndText()
            return .noHighlight
        case .undo:
            try argument.refuseBangAndText()
            return .undo
        case .redo:
            try argument.refuseBangAndText()
            return .redo
        case .put:
            return .put(register: try argument.register(), above: argument.bang)
        }
    }
}

/// What follows a command's name and `!`, with leading blanks skipped.
private struct ExArgument {
    let name: String
    let bang: Bool
    let text: String

    func refuseBang() throws {
        if bang { throw VimError("E477: No ! allowed") }
    }

    func refuseBangAndText() throws {
        try refuseBang()
        if !text.isEmpty { throw trailing(text) }
    }

    private func trailing(_ rest: String) -> VimError {
        VimError("E488: Trailing characters: \(rest)")
    }

    private func finish(_ scanner: ExScanner) throws {
        var scanner = scanner
        scanner.skipBlanks()
        if !scanner.atEnd { throw trailing(scanner.rest) }
    }

    /// `[x] [count]`: a register name that is not a digit, then a count.
    func registerAndCount() throws -> (Character?, Int?) {
        var scanner = ExScanner(text)
        var register: Character?
        if let first = scanner.peek, !first.isNumber,
           VimRegisters.isWritable(first) || first == "\"" {
            register = first
            scanner.advance()
        }
        scanner.skipBlanks()
        let count = try scanner.count()
        try finish(scanner)
        return (register, count)
    }

    func countOnly() throws -> Int? {
        var scanner = ExScanner(text)
        let count = try scanner.count()
        try finish(scanner)
        return count
    }

    func register() throws -> Character? {
        var scanner = ExScanner(text)
        let register = scanner.peek
        if register != nil { scanner.advance() }
        try finish(scanner)
        return register
    }

    func address() throws -> ExAddress {
        var scanner = ExScanner(text)
        guard let address = try scanner.address() else { throw VimError("E16: Invalid range") }
        try finish(scanner)
        return address
    }

    /// `/pattern/replacement/[&][flags] [count]`, or for `:s` alone and `:&`, the flags and
    /// count of a repeat.
    func substitute(repeating: Bool) throws -> ExSubstitute {
        var scanner = ExScanner(text)
        var pattern: String?
        var replacement: String?
        if !repeating, let delimiter = scanner.peek,
           !"0123456789cegriIp|\"".contains(delimiter) {
            try Self.checkDelimiter(delimiter)
            scanner.advance()
            let (found, closed) = scanner.delimited(by: delimiter)
            pattern = found
            replacement = closed ? scanner.replacement(until: delimiter) : ""
        }
        let flags = scanner.substituteFlags()
        scanner.skipBlanks()
        let count = try scanner.count()
        try finish(scanner)
        return ExSubstitute(pattern: pattern, replacement: replacement, flags: flags,
                            count: count)
    }

    func global(matching: Bool) throws -> ExTextCommand {
        var scanner = ExScanner(text)
        guard let delimiter = scanner.peek else {
            throw VimError("E148: Regular expression missing from :global")
        }
        try Self.checkDelimiter(delimiter)
        scanner.advance()
        let (pattern, _) = scanner.delimited(by: delimiter)
        return .global(pattern: pattern, matching: matching, command: scanner.rest)
    }

    private static func checkDelimiter(_ delimiter: Character) throws {
        if delimiter.isLetter || delimiter.isNumber || "\\\"|".contains(delimiter) {
            throw VimError("E146: Regular expressions can't be delimited by letters")
        }
    }

    func sort() throws -> ExSort {
        var sort = ExSort(reverse: bang)
        var scanner = ExScanner(text)
        while let next = scanner.peek {
            if next == " " || next == "\t" {
                scanner.advance()
                continue
            }
            switch next {
            case "i": sort.ignoreCase = true
            case "n": sort.numeric = true
            case "u": sort.unique = true
            case "r": sort.onMatch = true
            default:
                if next.isLetter || next == "\"" {
                    throw VimError("E475: Invalid argument: \(scanner.rest)")
                }
                scanner.advance()
                let after = scanner.rest
                let (pattern, closed) = scanner.delimited(by: next)
                guard closed else {
                    throw VimError("E654: Missing delimiter after search pattern: \(after)")
                }
                sort.pattern = pattern
                continue
            }
            scanner.advance()
        }
        return sort
    }

    /// Amber's `:retab` keeps the tabstop, so a new one is trailing text.
    func retab() throws {
        guard let first = text.first else { return }
        if first.isNumber { throw trailing(text) }
        throw VimError("E475: Invalid argument: \(text)")
    }
}

/// Reads an ex command line from left to right.
struct ExScanner {
    private let characters: [Character]
    private(set) var index = 0

    init(_ text: String) {
        characters = Array(text)
    }

    var atEnd: Bool { index >= characters.count }
    var peek: Character? { atEnd ? nil : characters[index] }
    var rest: String { String(characters[min(index, characters.count)...]) }

    mutating func advance() { index += 1 }

    mutating func take(_ character: Character) -> Bool {
        guard peek == character else { return false }
        index += 1
        return true
    }

    mutating func skipBlanks() {
        while peek == " " || peek == "\t" { index += 1 }
    }

    private mutating func number() -> Int? {
        var digits = ""
        while let next = peek, next.isASCII, next.isNumber {
            digits.append(next)
            index += 1
        }
        guard !digits.isEmpty else { return nil }
        return Int(digits.prefix(18)) ?? Int.max
    }

    mutating func count() throws -> Int? {
        guard let count = number() else { return nil }
        guard count > 0 else { throw VimError("E939: Positive count required") }
        return count
    }

    /// A command name: letters, or a run of `<` or `>`, or `&`.
    mutating func commandName() -> String {
        guard let first = peek else { return "" }
        var name = ""
        if first.isASCII && first.isLetter {
            while let next = peek, next.isASCII, next.isLetter {
                name.append(next)
                index += 1
            }
        } else if first == "<" || first == ">" {
            while peek == first {
                name.append(first)
                index += 1
            }
        } else if first == "&" {
            name = "&"
            index += 1
        }
        return name
    }

    /// The addresses before a command, or nil when there are none. `%` is the first line
    /// through the last, and an empty address next to a separator is the current line.
    mutating func range() throws -> ExRange? {
        var addresses: [ExAddress] = []
        var afterSeparator = false
        while true {
            skipBlanks()
            if take("%") {
                addresses += [ExAddress(.line(1)), ExAddress(.last)]
                afterSeparator = false
            } else if let address = try address() {
                addresses.append(address)
                afterSeparator = false
            } else if afterSeparator || peek == "," || peek == ";" {
                addresses.append(ExAddress(.current))
            }
            skipBlanks()
            guard let separator = peek, separator == "," || separator == ";" else { break }
            index += 1
            if separator == ";" { addresses[addresses.count - 1].movesCursor = true }
            afterSeparator = true
        }
        return addresses.isEmpty ? nil : ExRange(addresses: addresses)
    }

    /// One address: a base, then offsets, where a number without a sign adds to the base.
    mutating func address() throws -> ExAddress? {
        var base: ExAddress.Base?
        if let line = number() {
            base = .line(line)
        } else if take(".") {
            base = .current
        } else if take("$") {
            base = .last
        } else if take("'") {
            guard let mark = peek else { throw VimError("E20: Mark not set") }
            index += 1
            base = .mark(mark)
        } else if peek == "/" || peek == "?" {
            var searches: [ExSearch] = []
            while let delimiter = peek, delimiter == "/" || delimiter == "?" {
                index += 1
                searches.append(ExSearch(pattern: delimited(by: delimiter).text,
                                         forward: delimiter == "/"))
            }
            base = .search(searches)
        }
        var offset = 0
        var hasOffset = false
        while true {
            let start = index
            skipBlanks()
            if let sign = peek, sign == "+" || sign == "-" {
                index += 1
                let amount = number() ?? 1
                offset += sign == "+" ? amount : -amount
            } else if base != nil, let amount = number() {
                offset += amount
            } else {
                index = start
                break
            }
            hasOffset = true
        }
        guard base != nil || hasOffset else { return nil }
        return ExAddress(base ?? .current, offset: offset)
    }

    /// The text up to an unescaped `delimiter`, and whether the delimiter closed it. A
    /// backslash stays with the character after it, except that `\?` becomes `?` when `?`
    /// delimits, as in Vim.
    mutating func delimited(by delimiter: Character) -> (text: String, closed: Bool) {
        var text = ""
        while let next = peek {
            index += 1
            if next == delimiter { return (text, true) }
            if next == "\\", let escaped = peek {
                index += 1
                if !(escaped == "?" && delimiter == "?") { text.append(next) }
                text.append(escaped)
            } else {
                text.append(next)
            }
        }
        return (text, false)
    }

    /// A `:s` replacement up to an unescaped `delimiter`, keeping every backslash for
    /// `VimPattern.template`.
    mutating func replacement(until delimiter: Character) -> String {
        var text = ""
        while let next = peek {
            index += 1
            if next == delimiter { break }
            text.append(next)
            if next == "\\", let escaped = peek {
                index += 1
                text.append(escaped)
            }
        }
        return text
    }

    /// `[&][g i I n e]...`, where each `g` toggles.
    mutating func substituteFlags() -> SubstituteFlags {
        var flags = SubstituteFlags()
        flags.keepFlags = take("&")
        while let next = peek, "giIne".contains(next) {
            switch next {
            case "g": flags.global.toggle()
            case "i": flags.ignoreCase = true
            case "I": flags.ignoreCase = false
            case "n": flags.countOnly = true
            default: flags.noError = true
            }
            index += 1
        }
        return flags
    }
}
