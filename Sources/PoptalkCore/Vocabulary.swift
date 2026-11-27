import Foundation

public struct VocabTerm: Codable, Hashable, Sendable {
    public var text: String
    public var aliases: [String]

    public init(text: String, aliases: [String] = []) {
        self.text = text
        self.aliases = aliases
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
    }
}

public enum VocabularyError: Error, LocalizedError {
    case emptyTerm
    public var errorDescription: String? { "A term can't be empty." }
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

    /// Adds `term`, or merges its aliases into the saved term with the same text (case-insensitive).
    /// Locks across the file write too, so concurrent saves can't interleave.
    public func add(_ term: VocabTerm) throws {
        let term = try Self.normalized(term)
        lock.lock()
        defer { lock.unlock() }
        try save(Self.merging(term, into: _terms, at: _terms.endIndex))
    }

    /// Replaces the term with text `old` (case-insensitive) by `term`, in place.
    /// Renamed onto another saved term, it merges into that one like `add`; a missing `old` just adds.
    public func update(_ old: String, to term: VocabTerm) throws {
        let term = try Self.normalized(term)
        lock.lock()
        defer { lock.unlock() }
        var terms = _terms
        var at = terms.endIndex
        if let i = terms.firstIndex(where: { $0.text.lowercased() == old.lowercased() }) {
            terms.remove(at: i)
            at = i
        }
        try save(Self.merging(term, into: terms, at: at))
    }

    /// `term` inserted at `index`, or its new aliases appended to the term with the same text.
    private static func merging(_ term: VocabTerm, into terms: [VocabTerm], at index: Int) -> [VocabTerm] {
        var terms = terms
        if let i = terms.firstIndex(where: { $0.text.lowercased() == term.text.lowercased() }) {
            for alias in term.aliases where !terms[i].aliases.contains(where: { $0.lowercased() == alias.lowercased() }) {
                terms[i].aliases.append(alias)
            }
        } else {
            terms.insert(term, at: index)
        }
        return terms
    }

    /// Text and aliases trimmed; aliases without empties, case-insensitive repeats or the text itself.
    static func normalized(_ term: VocabTerm) throws -> VocabTerm {
        var t = term
        t.text = t.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.text.isEmpty else { throw VocabularyError.emptyTerm }
        var seen: Set<String> = [t.text.lowercased()]
        t.aliases = t.aliases.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        return t
    }

    /// Removes the term with this text (case-insensitive).
    public func remove(_ text: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try save(_terms.filter { $0.text.lowercased() != text.lowercased() })
    }

    /// Callers hold the lock.
    private func save(_ terms: [VocabTerm]) throws {
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
