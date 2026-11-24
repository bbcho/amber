import Foundation

/// A failure reported in Vim's wording, such as `E518: Unknown option: x`.
public struct VimError: Error, Equatable, CustomStringConvertible {
    public let message: String

    public init(_ message: String) { self.message = message }

    public var description: String { message }
}
