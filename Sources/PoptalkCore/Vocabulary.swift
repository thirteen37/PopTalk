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

/// Saved vocabulary, a JSON array of `VocabTerm`. Only grows when the user opts in.
public final class VocabularyStore: @unchecked Sendable {
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Poptalk/vocabulary.json")
    }

    private let url: URL
    private let lock = NSLock()
    private var _terms: [VocabTerm]
    public var terms: [VocabTerm] { lock.withLock { _terms } }

    public init(url: URL = VocabularyStore.defaultURL) {
        self.url = url
        _terms = (try? JSONDecoder().decode([VocabTerm].self, from: Data(contentsOf: url))) ?? []
    }

    /// Locks across the file write too, so concurrent saves can't interleave.
    public func add(_ term: VocabTerm) throws {
        lock.lock()
        defer { lock.unlock() }
        var terms = _terms
        if let i = terms.firstIndex(where: { $0.text.lowercased() == term.text.lowercased() }) {
            for alias in term.aliases where !terms[i].aliases.contains(where: { $0.lowercased() == alias.lowercased() }) {
                terms[i].aliases.append(alias)
            }
        } else {
            terms.append(term)
        }
        _terms = terms
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(terms).write(to: url, options: .atomic)
    }

    /// Reads FluidVoice's `parakeet_custom_vocabulary.json` (`{"terms":[…], …}`).
    public static func importFluidVoice(from url: URL) throws -> [VocabTerm] {
        struct File: Decodable { var terms: [VocabTerm] }
        return try JSONDecoder().decode(File.self, from: Data(contentsOf: url)).terms
    }
}
