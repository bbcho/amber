import Foundation

/// Translates Vim patterns and `:s` replacement strings into `NSRegularExpression` forms.
/// Only the subset Amber documents is accepted; anything else throws instead of guessing.
public enum VimPattern {
    /// Markers a template carries for the case conversions `\u \U \l \L \e \E`. They are
    /// private-use scalars, so a document containing them would be misread by the code that
    /// applies them.
    public enum CaseMarker: Character {
        case upperNext = "\u{E000}"
        case upperUntilEnd = "\u{E001}"
        case lowerNext = "\u{E002}"
        case lowerUntilEnd = "\u{E003}"
        case end = "\u{E004}"
    }

    private static let lineBreaks = "\\n\\r\\x{2028}\\x{2029}\\x{85}"
    private static let classes: [Character: String] = [
        "s": "[ \\t]", "S": "[^ \\t\(lineBreaks)]",
        "d": "[0-9]", "D": "[^0-9\(lineBreaks)]",
        "w": "[0-9A-Za-z_]", "W": "[^0-9A-Za-z_\(lineBreaks)]",
        "a": "[A-Za-z]", "l": "[a-z]", "u": "[A-Z]", "x": "[0-9A-Fa-f]",
    ]
    private static let posixClasses: [String: String] = [
        "alpha": "A-Za-z", "digit": "0-9", "alnum": "0-9A-Za-z", "lower": "a-z",
        "upper": "A-Z", "space": " \\t\\n\\r\\f\\v", "blank": " \\t", "punct": "!-/:-@\\[-`{-~",
        "xdigit": "0-9A-Fa-f",
    ]
    private static let specials: Set<Character> = Set("()|+?={@<>%&*.[~")
    private static let magicSpecials: Set<Character> = Set("*.[~")

    private enum Level { case veryMagic, magic, veryNomagic }

    // MARK: Patterns

    /// Compiles a Vim pattern. `\c` and `\C` override the options; with both `ignoreCase` and
    /// `smartCase`, a pattern containing an uppercase letter is case-sensitive. `~` stands for
    /// `previousSubstitute`.
    public static func regex(_ pattern: String, ignoreCase: Bool, smartCase: Bool,
                             previousSubstitute: String? = nil) throws -> NSRegularExpression {
        var translator = Translator(pattern: pattern, previous: previousSubstitute)
        let icu = try translator.translate()
        var caseInsensitive = ignoreCase && !(smartCase && hasUppercase(pattern))
        if translator.forceIgnoreCase { caseInsensitive = true }
        else if translator.forceMatchCase { caseInsensitive = false }
        var options: NSRegularExpression.Options = [.anchorsMatchLines]
        if caseInsensitive { options.insert(.caseInsensitive) }
        do {
            return try NSRegularExpression(pattern: icu, options: options)
        } catch {
            throw VimError("E383: Invalid search string: \(pattern)")
        }
    }

    /// Vim's rule for `smartcase`: an uppercase letter counts unless it follows a backslash.
    private static func hasUppercase(_ pattern: String) -> Bool {
        var skip = false
        for character in pattern {
            if skip { skip = false; continue }
            if character == "\\" { skip = true; continue }
            if character.isUppercase { return true }
        }
        return false
    }

    private struct Translator {
        let chars: [Character]
        let pattern: String
        let previous: String?
        var index = 0
        var level = Level.magic
        var out = ""
        var depth = 0
        var forceIgnoreCase = false
        var forceMatchCase = false
        var atom = false
        var multi = false

        init(pattern: String, previous: String?) {
            self.pattern = pattern
            chars = Array(pattern)
            self.previous = previous
        }

        enum Token {
            case literal(Character)
            case special(Character)
            case anchor(Character)
            case charClass(Character)
            case flag(Character)
        }

        func unsupported(_ what: String) -> VimError {
            VimError("E383: Invalid search string: \(what) is not supported in \(pattern)")
        }

        func isSpecial(_ c: Character, escaped: Bool) -> Bool {
            let plain: Bool
            switch level {
            case .veryMagic: plain = true
            case .magic: plain = VimPattern.magicSpecials.contains(c)
            case .veryNomagic: plain = false
            }
            return plain != escaped
        }

        mutating func nextToken() throws -> Token {
            let c = chars[index]
            index += 1
            if c == "\\" {
                guard index < chars.count else { throw unsupported("a trailing backslash") }
                let d = chars[index]
                index += 1
                if VimPattern.specials.contains(d) {
                    return isSpecial(d, escaped: true) ? .special(d) : .literal(d)
                }
                if "vVcC".contains(d) { return .flag(d) }
                if VimPattern.classes[d] != nil { return .charClass(d) }
                if d.isLetter || d.isNumber || d == "_" { throw unsupported("\\\(d)") }
                return .literal(d)
            }
            if c == "^" || c == "$" { return .anchor(c) }
            if VimPattern.specials.contains(c) {
                return isSpecial(c, escaped: false) ? .special(c) : .literal(c)
            }
            return .literal(c)
        }

        mutating func translate() throws -> String {
            var branchStart = true
            while index < chars.count {
                let startOfToken = index
                let token = try nextToken()
                switch token {
                case .flag(let flag):
                    switch flag {
                    case "v": level = .veryMagic
                    case "V": level = .veryNomagic
                    case "c": forceIgnoreCase = true
                    default: forceMatchCase = true
                    }
                case .literal(let c):
                    emitAtom(VimPattern.escape(c))
                    branchStart = false
                case .charClass(let c):
                    emitAtom(VimPattern.classes[c] ?? "")
                    branchStart = false
                case .anchor(let c):
                    if c == "^" {
                        if level == .veryMagic || branchStart {
                            out += "^"
                        } else {
                            emitAtom("\\^")
                            branchStart = false
                        }
                    } else if level == .veryMagic || atBranchEnd() {
                        out += "$"
                        atom = false
                    } else {
                        emitAtom("\\$")
                        branchStart = false
                    }
                case .special(let c):
                    try handleSpecial(c, branchStart: &branchStart, tokenStart: startOfToken)
                }
            }
            guard depth == 0 else { throw VimError("E54: Unmatched \\(") }
            return out
        }

        /// Whether only `\c`, `\C`, `\v` or `\V` may sit between here and the end of the
        /// pattern, `\|` or `\)`; Vim skips those flags when deciding that `$` is an anchor.
        func atBranchEnd() -> Bool {
            var probe = self
            while probe.index < probe.chars.count {
                guard let next = try? probe.nextToken() else { return false }
                switch next {
                case .flag: continue
                case .special(let c): return c == "|" || c == ")"
                case .literal, .anchor, .charClass: return false
                }
            }
            return true
        }

        mutating func emitAtom(_ text: String) {
            out += text
            atom = true
            multi = false
        }

        mutating func applyMulti(_ text: String, name: String) throws {
            guard atom else { throw VimError("E64: \(name) follows nothing") }
            guard !multi else { throw VimError("E871: Can't have a multi follow a multi") }
            out += text
            multi = true
        }

        mutating func handleSpecial(_ c: Character, branchStart: inout Bool,
                                    tokenStart: Int) throws {
            switch c {
            case "*":
                if !atom && branchStart && level == .magic {
                    emitAtom("\\*")
                    branchStart = false
                } else {
                    try applyMulti("*", name: "*")
                }
            case "+": try applyMulti("+", name: "\\+")
            case "?", "=": try applyMulti("?", name: "\\\(c)")
            case "{": try applyMulti(try braces(), name: "\\{")
            case ".":
                emitAtom(".")
                branchStart = false
            case "<", ">":
                out += "\\b"
                atom = false
                multi = false
            case "(":
                depth += 1
                out += "("
                atom = false
                multi = false
                branchStart = true
            case ")":
                guard depth > 0 else { throw VimError("E55: Unmatched \\)") }
                depth -= 1
                out += ")"
                atom = true
                multi = false
                branchStart = false
            case "|":
                out += "|"
                atom = false
                multi = false
                branchStart = true
            case "[":
                if let collection = try collection() {
                    emitAtom(collection)
                } else {
                    emitAtom("\\[")
                }
                branchStart = false
            case "~":
                guard let previous else {
                    throw VimError("E33: No previous substitute regular expression")
                }
                emitAtom("(?:" + NSRegularExpression.escapedPattern(for: previous) + ")")
                branchStart = false
            default:
                throw unsupported(String(chars[tokenStart..<index]))
            }
        }

        mutating func braces() throws -> String {
            var body = ""
            while index < chars.count, chars[index] != "}" {
                if chars[index] == "\\" , index + 1 < chars.count, chars[index + 1] == "}" { break }
                body.append(chars[index])
                index += 1
            }
            guard index < chars.count else { throw VimError("E554: Syntax error in \\{...}") }
            index += chars[index] == "}" ? 1 : 2
            let lazy = body.hasPrefix("-")
            if lazy { body.removeFirst() }
            let parts = body.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
            let digitsOnly = parts.allSatisfy { $0.allSatisfy { $0.isASCII && $0.isNumber } }
            guard parts.count <= 2, digitsOnly else {
                throw VimError("E554: Syntax error in \\{...}")
            }
            let low = parts.first.map(String.init) ?? ""
            let suffix = lazy ? "?" : ""
            if parts.count == 1 {
                return low.isEmpty ? "*" + suffix : "{\(low)}" + suffix
            }
            let high = String(parts[1])
            if low.isEmpty && high.isEmpty { return "*" + suffix }
            return "{\(low.isEmpty ? "0" : low),\(high)}" + suffix
        }

        /// A `[...]` collection, or nil when there is no closing `]` and the `[` is literal.
        mutating func collection() throws -> String? {
            var i = index
            var negated = false
            if i < chars.count, chars[i] == "^" { negated = true; i += 1 }
            var items = ""
            var first = true
            while i < chars.count {
                let c = chars[i]
                if c == "]" && !first {
                    index = i + 1
                    return negated ? "[^" + items + VimPattern.lineBreaks + "]" : "[" + items + "]"
                }
                first = false
                if c == "[", i + 1 < chars.count, chars[i + 1] == ":",
                   let close = chars[(i + 2)...].firstIndex(of: ":"),
                   close + 1 < chars.count, chars[close + 1] == "]" {
                    let name = String(chars[(i + 2)..<close])
                    guard let body = VimPattern.posixClasses[name] else {
                        throw unsupported("[:\(name):]")
                    }
                    items += body
                    i = close + 2
                    continue
                }
                var literal = c
                i += 1
                if c == "\\", i < chars.count {
                    guard "\\]^-".contains(chars[i]) else {
                        throw unsupported("\\\(chars[i]) inside []")
                    }
                    literal = chars[i]
                    i += 1
                }
                items += VimPattern.escapeInSet(literal)
                if i + 1 < chars.count, chars[i] == "-", chars[i + 1] != "]" {
                    var high = chars[i + 1]
                    i += 2
                    if high == "\\", i < chars.count { high = chars[i]; i += 1 }
                    items += "-" + VimPattern.escapeInSet(high)
                }
            }
            return nil
        }
    }

    private static func escape(_ c: Character) -> String {
        NSRegularExpression.escapedPattern(for: String(c))
    }

    private static func escapeInSet(_ c: Character) -> String {
        guard !(c.isLetter || c.isNumber), let scalar = c.unicodeScalars.first else {
            return String(c)
        }
        return "\\x{" + String(scalar.value, radix: 16) + "}"
    }

    // MARK: Replacements

    /// Replaces each unescaped `~` with `previous`, the previous `:s` replacement string.
    /// Vim stores the expanded text as the next previous string.
    public static func expandPrevious(_ replacement: String, previous: String?) throws -> String {
        var result = ""
        var escaped = false
        for character in replacement {
            if escaped {
                result.append(character)
                escaped = false
            } else if character == "\\" {
                result.append(character)
                escaped = true
            } else if character == "~" {
                guard let previous else {
                    throw VimError("E33: No previous substitute regular expression")
                }
                result += previous
            } else {
                result.append(character)
            }
        }
        return result
    }

    /// Turns a `:s` replacement string into an `NSRegularExpression` template. `&` and
    /// `\0`-`\9` become `$0`-`$9`, `\r` a line break, `\n` a NUL as in Vim, and the case
    /// conversions become `CaseMarker` characters in the output.
    public static func template(_ replacement: String, previous: String?) throws -> String {
        let source = Array(try expandPrevious(replacement, previous: previous))
        var out = ""
        var index = 0
        while index < source.count {
            let c = source[index]
            index += 1
            if c == "&" { out += "$0"; continue }
            guard c == "\\" else { out += templateLiteral(c); continue }
            guard index < source.count else {
                throw VimError("E10: \\ should be followed by /, ? or &")
            }
            let d = source[index]
            index += 1
            switch d {
            case "0"..."9": out += "$\(d)"
            case "n": out += "\u{0}"
            case "r": out += "\n"
            case "u": out.append(CaseMarker.upperNext.rawValue)
            case "U": out.append(CaseMarker.upperUntilEnd.rawValue)
            case "l": out.append(CaseMarker.lowerNext.rawValue)
            case "L": out.append(CaseMarker.lowerUntilEnd.rawValue)
            case "e", "E": out.append(CaseMarker.end.rawValue)
            default:
                if d.isLetter {
                    throw VimError("E383: Invalid replacement: \\\(d) is not supported")
                }
                out += templateLiteral(d)
            }
        }
        return out
    }

    /// A digit is escaped so it cannot extend a preceding `$n` into a larger group number.
    private static func templateLiteral(_ c: Character) -> String {
        c == "$" || c == "\\" || c.isASCII && c.isNumber ? "\\" + String(c) : String(c)
    }
}
