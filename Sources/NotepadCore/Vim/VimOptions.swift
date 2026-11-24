import Foundation

/// The settings changed by `:set`, with Amber's defaults rather than Vim's.
public struct VimOptions: Equatable {
    public var tabstop = 4
    public var shiftwidth = 4
    public var softtabstop = 0
    public var expandtab = true
    public var autoindent = false
    public var textwidth = 0
    public var nrformats = "bin,hex"
    public var ignorecase = false
    public var smartcase = false
    public var hlsearch = true
    public var incsearch = true
    public var wrapscan = true
    public var autoread = true
    public var clipboard = ""
    public var scrolloff = 0
    public var showcmd = true
    public var timeoutlen = 1000
    public var number = false
    public var relativenumber = false
    public var wrap = true
    public var list = false
    public var cursorline = false

    public init() {}

    private enum Kind {
        case flag(WritableKeyPath<VimOptions, Bool>)
        case number(WritableKeyPath<VimOptions, Int>, minimum: Int, maximum: Int)
        case list(WritableKeyPath<VimOptions, String>, allowed: [String])
    }

    private struct Descriptor {
        let name: String
        let short: String
        let kind: Kind
    }

    private static let nrformatValues = ["alpha", "octal", "hex", "bin", "unsigned", "blank"]

    private static let descriptors: [Descriptor] = [
        Descriptor(name: "tabstop", short: "ts", kind: .number(\.tabstop, minimum: 1, maximum: 9999)),
        Descriptor(name: "shiftwidth", short: "sw", kind: .number(\.shiftwidth, minimum: 0, maximum: 1_000_000_000)),
        Descriptor(name: "softtabstop", short: "sts", kind: .number(\.softtabstop, minimum: 0, maximum: 1_000_000_000)),
        Descriptor(name: "expandtab", short: "et", kind: .flag(\.expandtab)),
        Descriptor(name: "autoindent", short: "ai", kind: .flag(\.autoindent)),
        Descriptor(name: "textwidth", short: "tw", kind: .number(\.textwidth, minimum: 0, maximum: 1_000_000_000)),
        Descriptor(name: "nrformats", short: "nf",
                   kind: .list(\.nrformats, allowed: nrformatValues)),
        Descriptor(name: "ignorecase", short: "ic", kind: .flag(\.ignorecase)),
        Descriptor(name: "smartcase", short: "scs", kind: .flag(\.smartcase)),
        Descriptor(name: "hlsearch", short: "hls", kind: .flag(\.hlsearch)),
        Descriptor(name: "incsearch", short: "is", kind: .flag(\.incsearch)),
        Descriptor(name: "wrapscan", short: "ws", kind: .flag(\.wrapscan)),
        Descriptor(name: "autoread", short: "ar", kind: .flag(\.autoread)),
        Descriptor(name: "clipboard", short: "cb",
                   kind: .list(\.clipboard, allowed: ["unnamed", "unnamedplus"])),
        Descriptor(name: "scrolloff", short: "so", kind: .number(\.scrolloff, minimum: 0, maximum: 1_000_000_000)),
        Descriptor(name: "showcmd", short: "sc", kind: .flag(\.showcmd)),
        Descriptor(name: "timeoutlen", short: "tm", kind: .number(\.timeoutlen, minimum: 0, maximum: 1_000_000_000)),
        Descriptor(name: "number", short: "nu", kind: .flag(\.number)),
        Descriptor(name: "relativenumber", short: "rnu", kind: .flag(\.relativenumber)),
        Descriptor(name: "wrap", short: "wrap", kind: .flag(\.wrap)),
        Descriptor(name: "list", short: "list", kind: .flag(\.list)),
        Descriptor(name: "cursorline", short: "cul", kind: .flag(\.cursorline)),
    ]

    private static func descriptor(named name: String) -> Descriptor? {
        descriptors.first { $0.name == name || $0.short == name }
    }

    /// Applies the arguments of one `:set` command, such as `ts=2 noic list!`. Arguments are
    /// applied in order, so an error leaves the earlier ones applied, as in Vim. Returns the
    /// text for query arguments (`ts?`, or a bare number or string option), nil otherwise.
    @discardableResult
    public mutating func set(_ arguments: String) throws -> String? {
        var messages: [String] = []
        for argument in arguments.split(whereSeparator: { $0.isWhitespace }) {
            if let message = try apply(String(argument)) { messages.append(message) }
        }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    /// The options that differ from the defaults, as shown by a bare `:set`.
    public var changedSummary: String {
        let defaults = VimOptions()
        return Self.descriptors.compactMap { descriptor -> String? in
            guard describe(descriptor, plain: true) != defaults.describe(descriptor, plain: true)
            else { return nil }
            return describe(descriptor, plain: true)
        }.joined(separator: " ")
    }

    /// Reads an `amberrc` file. Blank lines and lines starting with `"` are skipped, `set` and
    /// `:set` lines are applied, and anything else is reported with its line number. A bad
    /// line changes nothing and never stops the lines after it.
    public static func load(rc text: String) -> (options: VimOptions, errors: [String]) {
        var options = VimOptions()
        var errors: [String] = []
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("\"") { continue }
            do {
                var attempt = options
                try attempt.set(try setArguments(of: line))
                options = attempt
            } catch let error as VimError {
                errors.append("line \(index + 1): \(error.message)")
            } catch {
                errors.append("line \(index + 1): \(error)")
            }
        }
        return (options, errors)
    }

    private static func setArguments(of line: String) throws -> String {
        let command = line.hasPrefix(":") ? String(line.dropFirst()) : line
        let word = command.prefix { !$0.isWhitespace }
        guard word == "set" || word == "se" else {
            throw VimError("E492: Not an editor command: \(line)")
        }
        return String(command.dropFirst(word.count))
    }

    private enum Action {
        case bare, show, reset, toggle
        case assign(op: Character?, value: String)
    }

    private static func parse(_ argument: String) -> (name: String, action: Action) {
        if let index = argument.firstIndex(where: { $0 == "=" || $0 == ":" }) {
            var name = String(argument[..<index])
            var op: Character?
            if let last = name.last, "+-^".contains(last) {
                op = last
                name.removeLast()
            }
            return (name, .assign(op: op, value: String(argument[argument.index(after: index)...])))
        }
        switch argument.last {
        case "?": return (String(argument.dropLast()), .show)
        case "&": return (String(argument.dropLast()), .reset)
        case "!": return (String(argument.dropLast()), .toggle)
        default: return (argument, .bare)
        }
    }

    private mutating func apply(_ argument: String) throws -> String? {
        let (name, parsed) = Self.parse(argument)
        var action = parsed
        var descriptor = Self.descriptor(named: name)
        var forced: Bool?
        if descriptor == nil, case .bare = action {
            if name.hasPrefix("no") {
                (descriptor, forced) = (Self.descriptor(named: String(name.dropFirst(2))), false)
            } else if name.hasPrefix("inv") {
                (descriptor, action) = (Self.descriptor(named: String(name.dropFirst(3))), .toggle)
            }
            if descriptor != nil, case .number = descriptor?.kind { throw invalid(argument) }
            if descriptor != nil, case .list = descriptor?.kind { throw invalid(argument) }
        }
        guard let descriptor else { throw VimError("E518: Unknown option: \(name)") }

        switch (descriptor.kind, action) {
        case (_, .show):
            return describe(descriptor, plain: false)
        case (_, .reset):
            reset(descriptor)
        case (.flag(let path), .bare):
            self[keyPath: path] = forced ?? true
        case (.flag(let path), .toggle):
            self[keyPath: path].toggle()
        case (.flag, .assign):
            throw invalid(argument)
        case (_, .toggle):
            throw VimError("E488: Trailing characters: \(argument)")
        case (.number, .bare), (.list, .bare):
            return describe(descriptor, plain: false)
        case (.number(let path, let minimum, let maximum), .assign(let op, let value)):
            guard let number = Int(value) else {
                throw VimError("E521: Number required after =: \(argument)")
            }
            let current = self[keyPath: path]
            let computed: (partialValue: Int, overflow: Bool)
            switch op {
            case "+": computed = current.addingReportingOverflow(number)
            case "-": computed = current.subtractingReportingOverflow(number)
            case "^": computed = current.multipliedReportingOverflow(by: number)
            default: computed = (number, false)
            }
            guard !computed.overflow, computed.partialValue <= maximum else { throw invalid(argument) }
            guard computed.partialValue >= minimum else {
                throw VimError("E487: Argument must be positive: \(argument)")
            }
            self[keyPath: path] = computed.partialValue
        case (.list(let path, let allowed), .assign(let op, let value)):
            let items = value.split(separator: ",").map(String.init)
            guard items.allSatisfy(allowed.contains) else { throw invalid(argument) }
            var current = self[keyPath: path].split(separator: ",").map(String.init)
            switch op {
            case "+": current += items.filter { !current.contains($0) }
            case "-": current.removeAll { items.contains($0) }
            case "^": current = items.filter { !current.contains($0) } + current
            default: current = items
            }
            self[keyPath: path] = current.joined(separator: ",")
        }
        return nil
    }

    private func invalid(_ argument: String) -> VimError {
        VimError("E474: Invalid argument: \(argument)")
    }

    private mutating func reset(_ descriptor: Descriptor) {
        let defaults = VimOptions()
        switch descriptor.kind {
        case .flag(let path): self[keyPath: path] = defaults[keyPath: path]
        case .number(let path, _, _): self[keyPath: path] = defaults[keyPath: path]
        case .list(let path, _): self[keyPath: path] = defaults[keyPath: path]
        }
    }

    /// `plain` is the form listed by a bare `:set`; otherwise it is Vim's query output.
    private func describe(_ descriptor: Descriptor, plain: Bool) -> String {
        switch descriptor.kind {
        case .flag(let path):
            if self[keyPath: path] { return (plain ? "" : "  ") + descriptor.name }
            return "no" + descriptor.name
        case .number(let path, _, _):
            return (plain ? "" : "  ") + "\(descriptor.name)=\(self[keyPath: path])"
        case .list(let path, _):
            return (plain ? "" : "  ") + "\(descriptor.name)=\(self[keyPath: path])"
        }
    }
}
