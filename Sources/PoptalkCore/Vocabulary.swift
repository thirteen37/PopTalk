import Foundation

public struct VocabTerm: Codable, Hashable, Sendable {
    public var text: String
    public var aliases: [String]
    public var weight: Float

    public init(text: String, aliases: [String] = [], weight: Float = 10) {
        self.text = text
        self.aliases = aliases
        self.weight = weight
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
        weight = try c.decodeIfPresent(Float.self, forKey: .weight) ?? 10
    }
}
