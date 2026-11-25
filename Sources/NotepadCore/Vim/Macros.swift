import Foundation

/// Macro recording and playback. `handle` adds each typed key to `session.recording`; the
/// adapter feeds the keys of a `.replay` effect back with `replayed: true`, stops at the
/// first failure, and enforces the recursion and key limits.
extension VimEngine {
    /// The most keys one run replays. `@` repeats a macro no more often than this needs,
    /// so a huge count cannot build a huge replay, and the adapter still sees the limit
    /// passed.
    static let replayKeyLimit = 100_000

    private static let recordKey = VimKey(.character("q"))

    static func startRecording(_ name: Character, _ result: inout VimResult) {
        guard name.isASCII, name.isLetter else {
            fail(&result)
            return
        }
        result.session.recording = Recording(register: name, keys: [])
    }

    /// `q` while recording, outside an operator, stores the keys typed since `q{register}`
    /// in that register as key notation, leaving the unnamed register alone, as Vim does.
    static func stopsRecording(_ result: inout VimResult) -> Bool {
        guard result.window.pendingKeys == [recordKey], result.window.mode != .operatorPending,
              let recording = result.session.recording else { return false }
        clearPending(&result.window)
        result.session.recording = nil
        result.session.registers.storeMacro(recording.keys.map(\.notation).joined(),
                                            in: recording.register)
        return true
    }

    /// `@{register}` replays the register's keys `count` times; `@@` replays the register
    /// played last, and `@:` the last command line.
    static func play(_ name: Character, count: Int?, _ result: inout VimResult,
                     _ clipboard: () -> String?) {
        guard let register = name == "@" ? result.session.lastPlayedRegister : name else {
            result.effects.append(.message("E748: No previously used register"))
            fail(&result)
            return
        }
        guard let keys = macroKeys(register, &result, clipboard) else { return }
        result.session.lastPlayedRegister = register
        guard !keys.isEmpty else { return }
        let repeats = min(max(count ?? 1, 1), replayKeyLimit / keys.count + 1)
        result.effects.append(.replay(Array(Array(repeating: keys, count: repeats).joined())))
    }

    /// The keys `register` plays, or nil after reporting why there are none.
    private static func macroKeys(_ register: Character, _ result: inout VimResult,
                                  _ clipboard: () -> String?) -> [VimKey]? {
        let registers = result.session.registers
        if register == ":" {
            guard let command = registers.value(":", clipboard: clipboard)?.text,
                  !command.isEmpty else {
                result.effects.append(.message("E30: No previous command line"))
                fail(&result)
                return nil
            }
            return [VimKey(.character(":"))] + command.map { VimKey(.character($0)) }
                + [VimKey(.enter)]
        }
        guard isRegisterName(register), let value = registers.value(register,
                                                                    clipboard: clipboard)
        else {
            fail(&result)
            return nil
        }
        return keys(fromMacro: value.text)
    }

    /// The keys a register's text stands for: Vim key notation such as `<Esc>`, a line break
    /// as Control-J, which is how Vim plays the line breaks of a linewise register, and any
    /// other character as itself, including a `<` that starts no key name.
    static func keys(fromMacro text: String) -> [VimKey] {
        var keys: [VimKey] = []
        var rest = Substring(text)
        while let first = rest.first {
            if first == "<", let close = rest.firstIndex(of: ">"),
               let named = try? VimKey.parse(String(rest[...close])), named.count == 1 {
                keys.append(named[0])
                rest = rest[rest.index(after: close)...]
                continue
            }
            keys.append(first == "\n" ? VimKey(.character("j"), control: true)
                : VimKey(.character(first)))
            rest = rest.dropFirst()
        }
        return keys
    }
}
