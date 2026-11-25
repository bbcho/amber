import Foundation

// MARK: :sort

extension ExRun {
    /// What one line sorts by: the bytes of its key, or with `n`, the key's first number.
    private struct SortKey {
        let index: Int
        let bytes: [UInt8]
        let number: Int?
    }

    /// Vim's `:sort`: lines compare as UTF-8 bytes, or with `n` by their first decimal
    /// number, numberless lines first. Equal lines keep their order, and `!` reverses the
    /// whole result. A pattern's match is skipped, or with `r` is the key; a line without a
    /// match has an empty key.
    mutating func sort(_ sort: ExSort, _ range: ClosedRange<Int>) throws {
        guard range.count > 1 else { return }
        let regex = try sort.pattern.map {
            try compile(try searchPattern($0), ignoreCase: session.options.ignorecase,
                        smartCase: false)
        }
        let contents = range.map(lines.content)
        let keys = contents.enumerated().map { index, content in
            Self.sortKey(index, content, regex, sort)
        }
        var order = keys.sorted { Self.precedes($0, $1, numeric: sort.numeric) }
            .map { contents[$0.index] }
        if sort.reverse { order.reverse() }
        if sort.unique {
            order = order.enumerated().filter { index, line in
                index == 0 || Self.bytes(line, sort.ignoreCase)
                    != Self.bytes(order[index - 1], sort.ignoreCase)
            }.map(\.element)
        }
        lines.replace(range.lowerBound..<(range.upperBound + 1), with: order)
        moveCursor(toFirstNonBlankOf: range.lowerBound)
        reportChange(order.count - range.count)
    }

    private static func sortKey(_ index: Int, _ content: String, _ regex: NSRegularExpression?,
                                _ sort: ExSort) -> SortKey {
        let text = content as NSString
        var key = NSRange(location: 0, length: text.length)
        if let regex {
            if let match = firstMatch(regex, in: content)?.range {
                key = sort.onMatch ? match
                    : NSRange(location: NSMaxRange(match), length: text.length - NSMaxRange(match))
            } else {
                key = NSRange(location: 0, length: 0)
            }
        }
        let keyText = text.substring(with: key)
        return SortKey(index: index, bytes: bytes(keyText, sort.ignoreCase),
                       number: sort.numeric ? firstNumber(in: keyText) : nil)
    }

    /// The first decimal number, with one `-` before it.
    private static func firstNumber(in text: String) -> Int? {
        let characters = Array(text)
        guard let start = characters.firstIndex(where: { $0.isASCII && $0.isNumber }) else {
            return nil
        }
        let digits = characters[start...].prefix { $0.isASCII && $0.isNumber }
        let value = Int(String(digits.prefix(18))) ?? Int.max
        return start > 0 && characters[start - 1] == "-" ? -value : value
    }

    private static func bytes(_ text: String, _ ignoreCase: Bool) -> [UInt8] {
        let bytes = Array(text.utf8)
        guard ignoreCase else { return bytes }
        return bytes.map { (0x41...0x5A).contains($0) ? $0 + 0x20 : $0 }
    }

    private static func precedes(_ a: SortKey, _ b: SortKey, numeric: Bool) -> Bool {
        if numeric, a.number != b.number {
            guard let first = a.number else { return true }
            guard let second = b.number else { return false }
            return first < second
        }
        if !numeric {
            let order = compare(a.bytes, b.bytes)
            if order != 0 { return order < 0 }
        }
        return a.index < b.index
    }

    /// `strcmp` on the bytes.
    private static func compare(_ a: [UInt8], _ b: [UInt8]) -> Int {
        let common = min(a.count, b.count)
        let order = common == 0 ? 0 : a.withUnsafeBytes { first in
            b.withUnsafeBytes { second in
                Int(memcmp(first.baseAddress, second.baseAddress, common))
            }
        }
        return order != 0 ? order : a.count - b.count
    }
}
