import Foundation

/// A Claude account id: a lowercase UUID string. Safe to use as a folder name.
public struct AccountID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let raw: String

    public init?(_ string: String) {
        let lower = string.lowercased()
        let parts = lower.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.map(\.count) == [8, 4, 4, 4, 12] else { return nil }
        let hex = Set("0123456789abcdef")
        guard parts.allSatisfy({ $0.allSatisfy { hex.contains($0) } }) else { return nil }
        raw = lower
    }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let id = AccountID(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not an account id"))
        }
        self = id
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }

    public var description: String { raw }
}
