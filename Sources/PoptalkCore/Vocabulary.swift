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

/// One term's latest state in a Mac's synced vocabulary file (#129): an upsert of `term`, or a delete.
public struct VocabChange: Codable, Equatable, Sendable {
    /// The term's lowercased text: the key changes merge on.
    public var text: String
    public var term: VocabTerm?
    public var deleted: Bool
    public var modifiedAt: Date

    public init(_ term: VocabTerm, at: Date) { (text, self.term, deleted, modifiedAt) = (term.text.lowercased(), term, false, at) }
    public init(deleted key: String, at: Date) { (text, term, deleted, modifiedAt) = (key, nil, true, at) }
}

/// Saved vocabulary, a JSON array of `VocabTerm`. Only grows when the user opts in.
///
/// With `sync` on (#129), `sync()` keeps this Mac's file in an iCloud Drive folder (one file per Mac, like history)
/// as one change per term, and merges every Mac's file into the local terms: the newest change per lowercased text
/// wins, so another Mac's older copy can't bring back a delete. vocabulary.json stays the source of truth offline.
/// Learned screen terms (`LearnedTerms`) never sync.
public final class VocabularyStore: @unchecked Sendable {
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Poptalk/vocabulary.json")
    }

    /// Next to history's synced folder.
    public static var iCloudDirectory: URL {
        HistoryStore.iCloudDirectory.deletingLastPathComponent().appendingPathComponent("vocabulary")
    }

    public struct Sync: Sendable {
        public let root: URL
        public let deviceID: String
        /// Read per sync, so toggling takes effect at once.
        public let enabled: @Sendable () -> Bool
        /// This Mac's file: only this Mac writes it.
        public var file: URL { root.appendingPathComponent("vocabulary-\(deviceID).json") }

        public init(root: URL = VocabularyStore.iCloudDirectory, defaults: UserDefaults, enabled: @escaping @Sendable () -> Bool) {
            (self.root, self.deviceID, self.enabled) = (root, HistoryStore.deviceID(defaults), enabled)
        }
    }

    private let url: URL
    public let sync: Sync?
    private let lock = NSLock()
    private var _terms: [VocabTerm]
    public var terms: [VocabTerm] { lock.withLock { _terms } }

    public init(url: URL = VocabularyStore.defaultURL, sync: Sync? = nil) {
        self.url = url
        self.sync = sync
        _terms = (try? JSONDecoder().decode([VocabTerm].self, from: Data(contentsOf: url))) ?? []
    }

    /// When syncing: records the local changes since the last sync in this Mac's file, at `now`, and merges in
    /// every Mac's file. Reads the sync folder: call it off the hotkey path.
    public func sync(now: Date = Date()) {
        guard let sync, sync.enabled() else { return }
        let others = HistoryStore.syncedFiles(in: sync.root, prefix: "vocabulary-", ext: ".json").files
            .filter { $0.lastPathComponent != sync.file.lastPathComponent }.map(Self.read)
        lock.lock()
        defer { lock.unlock() }
        let own = Self.read(sync.file)
        // This Mac's file keeps the merged state, so a change taken from another Mac isn't recorded again as new.
        let merged = Self.merge([Self.record(_terms, in: own, now: now)] + others)
        if merged != own {
            try? FileManager.default.createDirectory(at: sync.root, withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? enc.encode(merged.values.sorted { $0.text < $1.text }).write(to: sync.file, options: .atomic)
        }
        let terms = Self.apply(merged, to: _terms)
        if terms != _terms { try? save(terms) }
    }

    /// Deletes this Mac's synced file, e.g. after the user turns sync off. Other Macs' files stay.
    public func deleteSyncedCopy() {
        if let sync { try? FileManager.default.removeItem(at: sync.file) }
    }

    /// A synced file's changes by key; empty when missing or unreadable.
    private static func read(_ file: URL) -> [String: VocabChange] {
        let changes = (try? JSONDecoder().decode([VocabChange].self, from: Data(contentsOf: file))) ?? []
        return Dictionary(changes.map { ($0.text, $0) }) { a, _ in a }
    }

    /// `log` with how `terms` differ from it recorded at `now`: a new or changed term is an upsert, and an upserted
    /// key `terms` lacks is a delete. A rename is both.
    static func record(_ terms: [VocabTerm], in log: [String: VocabChange], now: Date) -> [String: VocabChange] {
        var log = log
        for t in terms where log[t.text.lowercased()]?.term != t { log[t.text.lowercased()] = VocabChange(t, at: now) }
        let keys = Set(terms.map { $0.text.lowercased() })
        for (k, c) in log where !c.deleted && !keys.contains(k) { log[k] = VocabChange(deleted: k, at: now) }
        return log
    }

    /// The newest change per key across `logs`; a delete wins a tie.
    static func merge(_ logs: [[String: VocabChange]]) -> [String: VocabChange] {
        var out: [String: VocabChange] = [:]
        for log in logs {
            for (k, c) in log {
                if let o = out[k], o.modifiedAt > c.modifiedAt || (o.modifiedAt == c.modifiedAt && (o.deleted || !c.deleted)) { continue }
                out[k] = c
            }
        }
        return out
    }

    /// `terms` brought to `merged`: changed in place, deletes dropped, new terms appended oldest first.
    static func apply(_ merged: [String: VocabChange], to terms: [VocabTerm]) -> [VocabTerm] {
        let keys = Set(terms.map { $0.text.lowercased() })
        let kept = terms.compactMap { t in merged[t.text.lowercased()].map(\.term) ?? t }
        let added = merged.values.filter { !$0.deleted && !keys.contains($0.text) }
            .sorted { ($0.modifiedAt, $0.text) < ($1.modifiedAt, $1.text) }.compactMap(\.term)
        return kept + added
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
