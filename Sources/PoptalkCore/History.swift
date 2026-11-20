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
    public enum Kind: String, Codable, Sendable { case undo, correction, vocabularyAccepted, vocabularyDeclined }
    public var type: Kind
    public var id: UUID
    public var at: Date
    /// For a correction: the request that corrected it.
    public var by: UUID?

    public init(_ type: Kind, id: UUID, at: Date = Date(), by: UUID? = nil) {
        (self.type, self.id, self.at, self.by) = (type, id, at, by)
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
}

/// Append-only JSONL history in Application Support, written on a background queue. Writes are
/// dropped on error, and nothing is written while `enabled` returns false.
public final class HistoryStore: Sendable {
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Poptalk/history")
    }

    public struct Stats: Equatable, Sendable {
        public var requests: Int
        public var bytes: Int
    }

    public let directory: URL
    public var file: URL { directory.appendingPathComponent("history.jsonl") }
    private let enabled: @Sendable () -> Bool
    private let queue = DispatchQueue(label: "io.lyx.poptalk.history", qos: .utility)

    public init(directory: URL = HistoryStore.defaultDirectory, enabled: @escaping @Sendable () -> Bool) {
        self.directory = directory
        self.enabled = enabled
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
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            guard let h = try? FileHandle(forWritingTo: file) else { return }
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: line)
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

    /// Deletes the whole history directory, after any pending writes.
    public func wipe() {
        queue.async { [self] in try? FileManager.default.removeItem(at: directory) }
    }

    /// Request count and total size on disk, after any pending writes. Reads the whole file: call it off the hotkey path.
    public func stats() -> Stats {
        queue.sync {
            let fm = FileManager.default
            let requests = (try? String(contentsOf: file, encoding: .utf8))
                .map { $0.components(separatedBy: #""type":"request""#).count - 1 } ?? 0
            let bytes = ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
                .reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            return Stats(requests: requests, bytes: bytes)
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
