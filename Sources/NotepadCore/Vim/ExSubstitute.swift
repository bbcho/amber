import Foundation

// MARK: :s, :& and :&&

extension ExRun {
    mutating func substitute(_ command: ExSubstitute, _ range: ExRange?) throws {
        let (pattern, replacement, flags) = try substitution(command)
        let regex = try compile(pattern, ignoreCase: flags.ignoreCase)
        let template = ReplacementTemplate(try VimPattern.template(replacement, previous: nil))
        session.lastSubstitute = LastSubstitute(pattern: pattern, replacement: replacement,
                                                flags: flags)
        rememberSearch(pattern, forward: session.lastSearch?.forward ?? true)
        let span = try lineRange(range, count: command.count)
        var line = span.lowerBound
        var last = span.upperBound
        var substitutions = 0
        var substitutedLines = 0
        var lastSubstituted: Int?
        while line <= last {
            let content = lines.content(line)
            let matches = Self.matches(regex, in: content, global: flags.global)
            guard !matches.isEmpty else {
                line += 1
                continue
            }
            substitutions += matches.count
            substitutedLines += 1
            guard !flags.countOnly else {
                line += 1
                continue
            }
            let pieces = template.substitute(matches, regex, in: content)
            lines.replace(line..<(line + 1), with: pieces)
            lastSubstituted = line + pieces.count - 1
            line += pieces.count
            last += pieces.count - 1
        }
        try finish(substitutions, lines: substitutedLines, lastSubstituted, pattern, flags)
    }

    /// The pattern, the replacement with `~` expanded, and the flags a substitute uses.
    private func substitution(_ command: ExSubstitute) throws
        -> (String, String, SubstituteFlags) {
        let last = session.lastSubstitute
        var flags = command.flags
        if flags.keepFlags, let last { flags = Self.merged(last.flags, flags) }
        flags.keepFlags = false
        guard let pattern = command.pattern else {
            guard let last else {
                throw VimError("E33: No previous substitute regular expression")
            }
            return (last.pattern, last.replacement, flags)
        }
        let replacement = try VimPattern.expandPrevious(command.replacement ?? "",
                                                        previous: last?.replacement)
        return (try searchPattern(pattern), replacement, flags)
    }

    /// `&` takes the last flags first; the flags after it add to them, and `g` toggles.
    private static func merged(_ last: SubstituteFlags,
                               _ added: SubstituteFlags) -> SubstituteFlags {
        SubstituteFlags(global: last.global != added.global,
                        ignoreCase: added.ignoreCase ?? last.ignoreCase,
                        countOnly: last.countOnly || added.countOnly,
                        noError: last.noError || added.noError)
    }

    private mutating func finish(_ substitutions: Int, lines substituted: Int,
                                 _ lastSubstituted: Int?, _ pattern: String,
                                 _ flags: SubstituteFlags) throws {
        if var totals = global {
            totals.substitutions += substitutions
            totals.substitutedLines += substituted
            totals.countOnly = totals.countOnly || flags.countOnly
            global = totals
        } else if substitutions == 0 {
            if flags.noError { return }
            throw VimError("E486: Pattern not found: \(pattern)")
        } else {
            reportSubstitutions(substitutions, lines: substituted, countOnly: flags.countOnly)
        }
        guard let lastSubstituted else { return }
        if global == nil { VimEngine.recordJump(&window, lines.original) }
        moveCursor(toFirstNonBlankOf: lastSubstituted)
    }

    /// Vim's `do_sub_msg`: matches are always counted; substitutions over `report`.
    mutating func reportSubstitutions(_ count: Int, lines: Int, countOnly: Bool) {
        let onLines = "on " + Self.plural(lines, "line", "lines")
        if countOnly && count > 0 {
            effects.append(.message("\(Self.plural(count, "match", "matches")) \(onLines)"))
        } else if !countOnly && count > Self.report {
            let what = Self.plural(count, "substitution", "substitutions")
            effects.append(.message("\(what) \(onLines)"))
        }
    }

    /// The matches `:s` replaces in `line`, as Vim's `do_sub` finds them: after a match the
    /// search goes on from its end, or after an empty match, from the next character; an
    /// empty match where the last one ended does not count; and nothing is found once the
    /// search reaches the end of the line after a match.
    static func matches(_ regex: NSRegularExpression, in line: String,
                        global: Bool) -> [NSTextCheckingResult] {
        let text = line as NSString
        var found: [NSTextCheckingResult] = []
        var position = 0
        var lastEnd = -1
        while let match = firstMatch(regex, in: line, from: position) {
            let range = match.range
            let next = range.location < text.length
                ? NSMaxRange(text.rangeOfComposedCharacterSequence(at: range.location))
                : text.length + 1
            if range.length == 0 && range.location == lastEnd {
                position = next
                if position >= text.length { break }
                continue
            }
            found.append(match)
            lastEnd = NSMaxRange(range)
            position = range.length == 0 ? next : NSMaxRange(range)
            if !global || position >= text.length { break }
        }
        return found
    }
}

/// A `:s` replacement template from `VimPattern.template`, split at its case markers so
/// that each piece is expanded on its own and text from the document is never read as a
/// marker.
struct ReplacementTemplate {
    private enum Part {
        case template(String)
        case marker(VimPattern.CaseMarker)
    }

    private let parts: [Part]

    init(_ template: String) {
        var parts: [Part] = []
        var piece = ""
        for character in template {
            guard let marker = VimPattern.CaseMarker(rawValue: character) else {
                piece.append(character)
                continue
            }
            if !piece.isEmpty { parts.append(.template(piece)) }
            piece = ""
            parts.append(.marker(marker))
        }
        if !piece.isEmpty { parts.append(.template(piece)) }
        self.parts = parts
    }

    /// `line` with each match replaced, split where the replacement breaks the line.
    func substitute(_ matches: [NSTextCheckingResult], _ regex: NSRegularExpression,
                    in line: String) -> [String] {
        let text = line as NSString
        var out = ""
        var copied = 0
        for match in matches {
            out += text.substring(with: NSRange(location: copied,
                                                length: match.range.location - copied))
            out += expand(match, regex, in: line)
            copied = NSMaxRange(match.range)
        }
        out += text.substring(from: copied)
        guard out.contains(where: { $0 == "\n" || $0 == "\r" }) else { return [out] }
        return out.replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
    }

    private func expand(_ match: NSTextCheckingResult, _ regex: NSRegularExpression,
                        in line: String) -> String {
        var out = ""
        var next: CaseChange?
        var running: CaseChange?
        for part in parts {
            switch part {
            case .marker(let marker):
                switch marker {
                case .upperNext: next = .upper
                case .lowerNext: next = .lower
                case .upperUntilEnd: running = .upper
                case .lowerUntilEnd: running = .lower
                case .end: running = nil
                }
            case .template(let template):
                let text = regex.replacementString(for: match, in: line, offset: 0,
                                                   template: template)
                guard next != nil || running != nil else {
                    out += text
                    continue
                }
                for character in text {
                    guard let change = next ?? running else {
                        out.append(character)
                        continue
                    }
                    out += change.apply(to: String(character))
                    next = nil
                }
            }
        }
        return out
    }
}
