import Foundation

/// One hotkey request in the opt-in usage history (#38): what was heard, what the model saw and said, what happened.
public struct HistoryRequest: Codable, Equatable, Sendable {
    public var type = "request"
    public var id: UUID
    public var at: Date
    public var app: String
    public var bundleID: String?
    /// Parakeet's unboosted text, then the boosted transcript the pipeline got.
    public var rawTranscript: String
    public var transcript: String
    public var boost: [String]
    public var selection: String?
    public var provider: String
    /// The model last called and the messages it was sent (selection and screen context as sent); nil when none was called.
    public var model: String?
    public var messages: [ChatMessage]?
    public var reply: String?
    /// insert, replace, insertBefore, insertAfter, nothing or error.
    public var action: String
    /// The text the outcome inserts or replaces with.
    public var text: String?
    /// The label shown, e.g. "Dictated (raw)", or the error.
    public var outcome: String
    public var vocabularyOffer: String?
    public var remembered: String?
    /// Seconds from hotkey release to the outcome being applied.
    public var latency: Double
    /// Saved audio file name in the history directory.
    public var audio: String?
    /// Machine conditions at release and the request's CPU time (#58); absent in older lines.
    public var system: SystemSample?
    /// From `ModelCallRecorder.Call` (#42): dictation or edit, prompt tokens, and the lead tokens shared with the
    /// previous prompt to the same model in this process (warm-ups included); absent in older lines and non-MLX calls.
    public var kind: String?
    public var promptTokens: Int?
    public var sharedPrefix: Int?
    /// The speech model id (`ModelSettings.speechModels`) loaded when this was recorded (#73); absent in older lines.
    public var speechModel: String?

    public init(id: UUID, at: Date, app: String, bundleID: String? = nil, rawTranscript: String, transcript: String,
                boost: [String] = [], selection: String? = nil, provider: String, model: String? = nil,
                messages: [ChatMessage]? = nil, reply: String? = nil, outcome: Outcome, vocabularyOffer: String? = nil,
                remembered: String? = nil, latency: Double, audio: String? = nil) {
        (self.id, self.at, self.app, self.bundleID) = (id, at, app, bundleID)
        (self.rawTranscript, self.transcript, self.boost, self.selection) = (rawTranscript, transcript, boost, selection)
        (self.provider, self.model, self.messages, self.reply) = (provider, model, messages, reply)
        (self.vocabularyOffer, self.remembered, self.latency, self.audio) = (vocabularyOffer, remembered, latency, audio)
        switch outcome {
        case .nothing: (action, text, self.outcome) = ("nothing", nil, "Nothing")
        case .error(let m): (action, text, self.outcome) = ("error", nil, m)
        case .insert(let s, let l): (action, text, self.outcome) = ("insert", s, l)
        case .replaceSelection(let s, let l): (action, text, self.outcome) = ("replace", s, l)
        case .insertBefore(let s): (action, text, self.outcome) = ("insertBefore", s, "Inserted")
        case .insertAfter(let s): (action, text, self.outcome) = ("insertAfter", s, "Inserted")
        }
    }
}

/// A later signal about request `id`.
public struct HistoryEvent: Codable, Equatable, Sendable {
    /// `typedCorrection` (#86): the user fixed the dictation by typing. `redictation` (#95): the user said it again
    /// (`LastInsert.redictated`). `HistoryStore` merges lines by their `type` string, so an older version (another Mac)
    /// keeps the line without decoding it.
    public enum Kind: String, Codable, Sendable { case undo, correction, vocabularyAccepted, vocabularyDeclined, typedCorrection, redictation }
    public var type: Kind
    public var id: UUID
    public var at: Date
    /// For a correction or redictation: the request that corrected or repeated it.
    public var by: UUID?
    /// For a typed correction: the user's version of the dictated text (`TypedCorrection.text`).
    public var text: String?

    public init(_ type: Kind, id: UUID, at: Date = Date(), by: UUID? = nil, text: String? = nil) {
        (self.type, self.id, self.at, self.by, self.text) = (type, id, at, by, text)
    }
}

extension LastInsert {
    /// The request whose text a voice edit of `selection` in `target` is correcting: same field, within
    /// `window` seconds, and the selection lies within the inserted text or contains all of it.
    /// ponytail: a selection straddling the insert's edge, or a case change, isn't a correction; add a
    /// shared-substring rule if those turn out common.
    public func corrected(by selection: String?, in target: Target?, now: Date = Date(), window: TimeInterval = 180) -> UUID? {
        let sel = selection?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let ins = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let requestID, target == self.target, now.timeIntervalSince(at) < window, !sel.isEmpty, !ins.isEmpty,
              ins.contains(sel) || sel.contains(ins) else { return nil }
        return requestID
    }

    /// The request a dictation of `raw` is saying again (#95): no selection (that's `corrected`), same field,
    /// within `window` seconds of the insert or `deletionWindow` of its `deletedAt`, and `raw` at least
    /// `minSimilarity` like the previous take's raw transcript. A field emptied by a send sets `deletedAt` too:
    /// the similarity tells a repeat from the next message.
    public func redictated(raw: String, selection: String?, in target: Target?, now: Date = Date(),
                           window: TimeInterval = Redictation.window, deletionWindow: TimeInterval = Redictation.deletionWindow,
                           minSimilarity: Double = Redictation.minSimilarity) -> UUID? {
        guard let requestID, let rawTranscript, target == self.target,
              now.timeIntervalSince(at) < window || deletedAt.map({ now.timeIntervalSince($0) < deletionWindow }) == true,
              selection?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true,
              Redictation.similarity(raw, rawTranscript) >= minSimilarity else { return nil }
        return requestID
    }
}

/// Thresholds for `LastInsert.redictated`, from the #95 analysis: pair counts were flat from 30 s to 120 s and
/// sensitive to the cutoff (19 pairs at ≥ 0.5, 4 at ≥ 0.9).
public enum Redictation {
    public static let window: TimeInterval = 30
    /// After a deletion or undo of the insert, which is strong evidence on its own.
    public static let deletionWindow: TimeInterval = 120
    public static let minSimilarity = 0.6

    /// 2 × matched words / total words, matching in order (longest common subsequence via `difference`), over
    /// `SpeechMetrics.words`; 0 when either is empty.
    public static func similarity(_ a: String, _ b: String) -> Double {
        let (x, y) = (SpeechMetrics.words(a), SpeechMetrics.words(b))
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        let matched = x.count - y.difference(from: x).removals.count
        return 2 * Double(matched) / Double(x.count + y.count)
    }
}

/// Append-only JSONL history in Application Support, written on a background queue. Writes are
/// dropped on error, and nothing is written while `enabled` returns false.
///
/// With `sync` on (#76), each line also goes to this Mac's own file in an iCloud Drive folder, and reads merge
/// every Mac's file. Audio side files stay local. Nothing touches the folder while sync is off, except
/// `deleteSyncedCopy`.
public final class HistoryStore: Sendable {
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Poptalk/history")
    }

    /// Where the Macs' history files meet: a folder in iCloud Drive, so no entitlement is needed.
    public static var iCloudDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/PopTalk/history")
    }

    /// This Mac's id for its synced file, made on first use.
    public static func deviceID(_ defaults: UserDefaults) -> String {
        if let id = defaults.string(forKey: "historyDeviceID") { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: "historyDeviceID")
        return id
    }

    public struct Sync: Sendable {
        public let root: URL
        public let deviceID: String
        /// Read per write and per read, so toggling takes effect at once.
        public let enabled: @Sendable () -> Bool
        nonisolated(unsafe) let defaults: UserDefaults  // thread-safe; also keeps the newest wipe honored
        /// This Mac's file: only this Mac writes it, so iCloud never sees conflicting edits.
        public var file: URL { root.appendingPathComponent("history-\(deviceID).jsonl") }

        public init(root: URL = HistoryStore.iCloudDirectory, defaults: UserDefaults, enabled: @escaping @Sendable () -> Bool) {
            (self.root, self.deviceID, self.enabled, self.defaults) = (root, HistoryStore.deviceID(defaults), enabled, defaults)
        }

        /// Milliseconds since 1970 of the newest wipe this Mac has honored, made, or started syncing after.
        var wipeSeen: Int {
            get { defaults.integer(forKey: "historyWipeSeen") }
            nonmutating set { defaults.set(newValue, forKey: "historyWipeSeen") }
        }
    }

    public struct Stats: Equatable, Sendable {
        /// Requests across every Mac when syncing; bytes of this Mac's history directory.
        public var requests: Int
        public var bytes: Int
        /// Macs with a synced file (this one included once it has written), and when this Mac's last changed.
        public var devices = 0
        public var lastSync: Date?

        public init(requests: Int, bytes: Int, devices: Int = 0, lastSync: Date? = nil) {
            (self.requests, self.bytes, self.devices, self.lastSync) = (requests, bytes, devices, lastSync)
        }
    }

    public let directory: URL
    public var file: URL { directory.appendingPathComponent("history.jsonl") }
    public let sync: Sync?
    private let enabled: @Sendable () -> Bool
    private let queue = DispatchQueue(label: "io.lyx.poptalk.history", qos: .utility)

    public init(directory: URL = HistoryStore.defaultDirectory, sync: Sync? = nil, enabled: @escaping @Sendable () -> Bool) {
        self.directory = directory
        self.sync = sync
        self.enabled = enabled
    }

    /// `sync` when it's on.
    private var syncing: Sync? { sync.flatMap { $0.enabled() ? $0 : nil } }

    private static func append(_ line: Data, to file: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: file.path) {
            fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let h = try? FileHandle(forWritingTo: file) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: line)
    }

    public var isEnabled: Bool { enabled() }

    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public func append(_ record: some Encodable & Sendable) {
        queue.async { [self] in
            guard enabled(), var line = try? Self.encoder.encode(record) else { return }
            line.append(0x0A)
            Self.append(line, to: file)
            if let syncing { Self.append(line, to: syncing.file) }
        }
    }

    /// Runs `write` with the URL of `name` in the history directory, e.g. to save audio.
    public func saveFile(_ name: String, _ write: @escaping @Sendable (URL) throws -> Void) {
        queue.async { [self] in
            guard enabled() else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? write(directory.appendingPathComponent(name))
        }
    }

    /// Deletes the whole history directory, after any pending writes, and when syncing this Mac's synced file.
    /// `allMacs` (syncing only) deletes the synced folder instead and leaves a `wiped-<ms>` tombstone that the
    /// other Macs honor at their next `checkSync`.
    public func wipe(allMacs: Bool = false, now: Date = Date()) {
        queue.async { [self] in
            let fm = FileManager.default
            try? fm.removeItem(at: directory)
            guard let syncing else { return }
            guard allMacs else { try? fm.removeItem(at: syncing.file); return }
            let t = Int(now.timeIntervalSince1970 * 1000)
            try? fm.removeItem(at: syncing.root)
            try? fm.createDirectory(at: syncing.root, withIntermediateDirectories: true)
            fm.createFile(atPath: syncing.root.appendingPathComponent("wiped-\(t)").path, contents: nil)
            syncing.wipeSeen = t
        }
    }

    /// Call when the user turns sync on: wipes made before `now` are not this Mac's to honor, and
    /// `copyExisting` (after the user confirms) replaces this Mac's synced file with all of its local history.
    public func startSync(copyExisting: Bool, now: Date = Date()) {
        queue.async { [self] in
            guard let sync else { return }
            sync.wipeSeen = max(sync.wipeSeen, Int(now.timeIntervalSince1970 * 1000))
            guard copyExisting, let data = try? Data(contentsOf: file) else { return }
            try? FileManager.default.removeItem(at: sync.file)
            Self.append(data, to: sync.file)
        }
    }

    /// Deletes this Mac's synced file, e.g. after the user turns sync off. Other Macs' files stay.
    public func deleteSyncedCopy() {
        queue.async { [self] in if let sync { try? FileManager.default.removeItem(at: sync.file) } }
    }

    /// Honors another Mac's "wipe all Macs" (at launch, and before each stats read).
    public func checkSync() { queue.async { [self] in honorWipe() } }

    private func honorWipe() {
        guard let syncing, let names = try? FileManager.default.contentsOfDirectory(atPath: syncing.root.path),
              let t = names.compactMap({ $0.hasPrefix("wiped-") ? Int($0.dropFirst(6)) : nil }).max(),
              t > syncing.wipeSeen else { return }
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: syncing.file)
        syncing.wipeSeen = t
    }

    /// The files to merge: this Mac's, then when syncing every downloaded Mac's synced file (including this
    /// Mac's own, whose lines repeat local ones), and how many Macs have one. Evicted files are asked to
    /// download and skipped until they have.
    private func sources() -> (files: [URL], devices: Int) {
        guard let syncing, let names = try? FileManager.default.contentsOfDirectory(atPath: syncing.root.path) else { return ([file], 0) }
        var files = [file], devices = 0
        for name in names where name.hasSuffix(".jsonl") || name.hasSuffix(".jsonl.icloud") {
            // An evicted file shows as ".history-<id>.jsonl.icloud" (or dataless, with its own name, on newer macOS).
            let real = name.hasPrefix(".") && name.hasSuffix(".icloud") ? String(name.dropFirst().dropLast(7)) : name
            guard real.hasPrefix("history-"), real.hasSuffix(".jsonl") else { continue }
            devices += 1
            let url = syncing.root.appendingPathComponent(real)
            let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus
            if real != name || status == .notDownloaded {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            } else {
                files.append(url)
            }
        }
        return (files, devices)
    }

    private struct Key: Decodable { var type: String; var id: UUID; var at: Date }

    private func merged(_ files: [URL]) -> [(key: Key, line: Data)] {
        var seen = Set<String>(), out: [(key: Key, line: Data)] = []
        for f in files {
            guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
            for l in text.split(separator: "\n") {
                let line = Data(l.utf8)
                guard let k = try? Self.decoder.decode(Key.self, from: line),  // a malformed line is skipped
                      seen.insert(k.type == "request" ? k.id.uuidString : String(l)).inserted else { continue }
                out.append((k, line))
            }
        }
        return out.sorted { $0.key.at < $1.key.at }  // stable: same-time lines keep file order
    }

    /// Every JSONL line in time order: this Mac's, plus when syncing every Mac's, with each request once.
    /// Reads every file: call it off the hotkey path.
    public func records() -> [Data] {
        queue.sync { honorWipe(); return merged(sources().files).map(\.line) }
    }

    /// Request count (merged as in `records`), size on disk and sync status, after any pending writes.
    /// Reads every file: call it off the hotkey path.
    public func stats() -> Stats {
        queue.sync {
            honorWipe()
            let fm = FileManager.default
            let (files, devices) = sources()
            let requests = merged(files).count { $0.key.type == "request" }
            let bytes = ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
                .reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            let last = syncing.flatMap { try? $0.file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            return Stats(requests: requests, bytes: bytes, devices: devices, lastSync: last)
        }
    }

    func flush() { queue.sync {} }
}

/// Wraps a `Pipeline.Complete` to keep its last call, so history can record what the model was sent and replied.
public final class ModelCallRecorder: @unchecked Sendable {
    public struct Call: Equatable, Sendable {
        public var model: String
        public var messages: [ChatMessage]
        public var reply: String?
        /// "edit" for a JSON call (Pipeline asks for JSON only on edits), else "dictation".
        public var kind: String?
        /// Prompt tokens, and how many lead tokens match the previous prompt to the same model (#42); set by
        /// providers that report them (MLX).
        public var promptTokens: Int?
        public var sharedPrefix: Int?
    }

    /// The recorder of the call in progress, for the provider to report prompt stats to; nil outside `wrap`.
    @TaskLocal public static var current: ModelCallRecorder?

    private let lock = NSLock()
    private var _call: Call?
    public var call: Call? { lock.withLock { _call } }

    public init() {}

    public func prompt(tokens: Int, shared: Int) {
        lock.withLock { _call?.promptTokens = tokens; _call?.sharedPrefix = shared }
    }

    public func wrap(_ complete: @escaping Pipeline.Complete) -> Pipeline.Complete {
        { [self] model, messages, json, timeout in
            lock.withLock { _call = Call(model: model, messages: messages, kind: json ? "edit" : "dictation") }
            let reply = try await Self.$current.withValue(self) { try await complete(model, messages, json, timeout) }
            lock.withLock { _call?.reply = reply }
            return reply
        }
    }
}
