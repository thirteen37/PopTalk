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
    /// The latest `record` and the entries it replaced (nil: it added the term), for `forget(request:)`.
    private var last: (request: UUID, prior: [String: LearnedTerm?])?

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
    public func record(_ texts: [String], request: UUID, at now: Date = Date()) -> Int {
        guard !texts.isEmpty else { return lock.withLock { _terms.count } }
        return lock.withLock {
            var terms = _terms
            var prior: [String: LearnedTerm?] = [:]
            for text in texts {
                let key = text.lowercased()
                guard prior[key] == nil else { continue }  // once per request
                let i = terms.firstIndex { $0.text.lowercased() == key }
                prior[key] = .some(i.map { terms[$0] })
                let count = i.map { terms.remove(at: $0).count } ?? 0
                terms.insert(LearnedTerm(text: text, lastUsed: now, count: count + 1), at: 0)
            }
            last = (request, prior)
            save(Self.pruned(terms, now: now))
            return _terms.count
        }
    }

    /// Esc undo: puts back what `request` changed, if it was the latest `record`. Returns how many terms that was.
    @discardableResult
    public func forget(request: UUID) -> Int {
        lock.withLock {
            guard let last, last.request == request else { return 0 }
            self.last = nil
            var terms = _terms.filter { last.prior[$0.text.lowercased()] == nil }
            terms += last.prior.values.compactMap { $0 }
            save(terms.sorted { $0.lastUsed > $1.lastUsed })
            return last.prior.count
        }
    }

    public func forget(_ text: String) {
        lock.withLock { save(_terms.filter { $0.text.lowercased() != text.lowercased() }) }
    }

    public func forgetAll() { lock.withLock { last = nil; save([]) } }

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
        func count(_ term: String, _ s: String) -> Int {
            let re = try? NSRegularExpression(pattern: #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: term) + #"(?![\p{L}\p{N}])"#)
            return re?.numberOfMatches(in: s, range: NSRange(s.startIndex..., in: s)) ?? 0
        }
        return terms.filter { !known.contains($0.lowercased()) && count($0, after) > count($0, before) }
    }
}
