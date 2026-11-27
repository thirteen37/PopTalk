import Foundation

public struct LearnedTerm: Codable, Hashable, Sendable {
    public var text: String
    public var lastUsed: Date
    public var count: Int
}

/// Screen terms that changed a dictation (#87), remembered only with "Remember screen terms that fix dictations" on.
/// A JSON array of `LearnedTerm` next to the vocabulary file, on this Mac only (Application Support isn't synced).
/// Newest first; a term unused for `maxAge` goes, and past `cap` the least recently used does.
public final class LearnedTerms: @unchecked Sendable {
    public static var defaultURL: URL {
        VocabularyStore.defaultURL.deletingLastPathComponent().appendingPathComponent("learned-terms.json")
    }
    public static let maxAge: TimeInterval = 30 * 86_400
    public static let cap = 200

    private let url: URL
    private let lock = NSLock()
    private var _terms: [LearnedTerm]

    public init(url: URL = LearnedTerms.defaultURL) {
        self.url = url
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        _terms = (try? dec.decode([LearnedTerm].self, from: Data(contentsOf: url))) ?? []
    }

    public func terms(at now: Date = Date()) -> [LearnedTerm] { lock.withLock { Self.pruned(_terms, now: now) } }
    public func vocabTerms(at now: Date = Date()) -> [VocabTerm] { terms(at: now).map { VocabTerm(text: $0.text) } }

    /// Bumps each of `texts` (case-insensitive; the newest spelling wins), adding the new ones. Returns the list's size.
    @discardableResult
    public func record(_ texts: [String], at now: Date = Date()) -> Int {
        guard !texts.isEmpty else { return lock.withLock { _terms.count } }
        return lock.withLock {
            var terms = _terms
            var seen = Set<String>()
            for text in texts where seen.insert(text.lowercased()).inserted {  // once per call
                let i = terms.firstIndex { $0.text.lowercased() == text.lowercased() }
                let count = i.map { terms.remove(at: $0).count } ?? 0
                terms.insert(LearnedTerm(text: text, lastUsed: now, count: count + 1), at: 0)
            }
            save(Self.pruned(terms, now: now))
            return _terms.count
        }
    }

    /// Removes `texts` (case-insensitive), however long known: a Settings delete, or an undo or typed fix of a
    /// dictation they changed (#130). Returns how many were removed.
    @discardableResult
    public func forget(_ texts: [String]) -> Int {
        let gone = Set(texts.map { $0.lowercased() })
        return lock.withLock {
            let kept = _terms.filter { !gone.contains($0.text.lowercased()) }
            let n = _terms.count - kept.count
            if n > 0 { save(kept) }
            return n
        }
    }

    public func forgetAll() { lock.withLock { save([]) } }

    static func pruned(_ terms: [LearnedTerm], now: Date) -> [LearnedTerm] {
        Array(terms.filter { now.timeIntervalSince($0.lastUsed) < maxAge }.sorted { $0.lastUsed > $1.lastUsed }.prefix(cap))
    }

    /// Callers hold the lock. A failed write keeps the terms in memory; they're relearned anyway.
    private func save(_ terms: [LearnedTerm]) {
        _terms = terms
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try? enc.encode(terms).write(to: url, options: .atomic)
    }
}

extension Pipeline {
    /// The `terms` that `after` spells exactly (whole words, case-sensitive) more often than `before`, other than
    /// `saved` ones (case-insensitive): what a boost or the casing fix wrote (#87).
    public static func termsWritten(from before: String, to after: String, terms: [String], saved: [String]) -> [String] {
        let known = Set(saved.map { $0.lowercased() })
        return terms.filter { !known.contains($0.lowercased()) && count($0, in: after) > count($0, in: before) }
    }

    /// How often `s` spells `term` exactly, as whole words.
    static func count(_ term: String, in s: String) -> Int {
        let re = try? NSRegularExpression(pattern: #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: term) + #"(?![\p{L}\p{N}])"#)
        return re?.numberOfMatches(in: s, range: NSRange(s.startIndex..., in: s)) ?? 0
    }

    /// The screen and learned terms a dictation's boost (raw → boosted transcript) or casing fix (`recased`) wrote, if
    /// still in the text `inserted`; saved terms aside (#87). What an undo or typed fix of it unlearns (#130).
    public static func screenTermsWritten(_ raw: RawInsert, recased: [String], inserted: String,
                                          saved: [String]) -> (boost: [String], casing: [String]) {
        let boosted = termsWritten(from: raw.rawTranscript, to: raw.request.transcript, terms: raw.boost, saved: saved)
        return (boosted.filter { inserted.contains($0) }, recased.filter { inserted.contains($0) })
    }

    /// What `learn()` records for a dictation (#87): `screenTermsWritten`. Nil with learning off, in Settings or in the
    /// app's profile (#96).
    public static func termsToLearn(_ raw: RawInsert, recased: [String], inserted: String,
                                    saved: [String]) -> (boost: [String], casing: [String])? {
        raw.sources.learnScreenTerms ? screenTermsWritten(raw, recased: recased, inserted: inserted, saved: saved) : nil
    }
}
