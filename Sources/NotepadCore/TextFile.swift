import Foundation

public enum DocumentFailure: LocalizedError {
    case unsupportedEncoding
    case changedOnDisk

    public var errorDescription: String? {
        switch self {
        case .unsupportedEncoding:
            return "This file is not valid UTF-8 or UTF-16 text. "
                + "Its contents have not been changed."
        case .changedOnDisk:
            return "This file was changed or removed outside Amber. "
                + "Your edits are safe in recovery."
        }
    }
}

public struct TextFile: Codable {
    public var text: String
    public let encoding: Encoding

    public enum Encoding: String, Codable { case utf8, utf8BOM, utf16LE, utf16BE }

    public init(text: String = "", encoding: Encoding = .utf8) {
        self.text = text
        self.encoding = encoding
    }

    public static func decode(_ bytes: Data) throws -> TextFile {
        let encoding: Encoding
        let payload: Data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            encoding = .utf8BOM
            payload = bytes.dropFirst(3)
        } else if bytes.starts(with: [0xFF, 0xFE]) {
            encoding = .utf16LE
            payload = bytes.dropFirst(2)
        } else if bytes.starts(with: [0xFE, 0xFF]) {
            encoding = .utf16BE
            payload = bytes.dropFirst(2)
        } else {
            encoding = .utf8
            payload = bytes
        }
        guard let text = String(data: payload, encoding: encoding.foundation),
              !text.contains("\0") else {
            throw DocumentFailure.unsupportedEncoding
        }
        let file = TextFile(text: text, encoding: encoding)
        guard try file.encoded() == bytes else { throw DocumentFailure.unsupportedEncoding }
        return file
    }

    public func encoded() throws -> Data {
        guard let payload = text.data(using: encoding.foundation) else {
            throw DocumentFailure.unsupportedEncoding
        }
        return Data(encoding.prefix) + payload
    }
}

private extension TextFile.Encoding {
    var foundation: String.Encoding {
        switch self {
        case .utf8, .utf8BOM: return .utf8
        case .utf16LE: return .utf16LittleEndian
        case .utf16BE: return .utf16BigEndian
        }
    }
    var prefix: [UInt8] {
        switch self {
        case .utf8: return []
        case .utf8BOM: return [0xEF, 0xBB, 0xBF]
        case .utf16LE: return [0xFF, 0xFE]
        case .utf16BE: return [0xFE, 0xFF]
        }
    }
}
