/// What a hotkey press can do while models load (#39).
public enum RunMode: Equatable, Sendable {
    /// No speech model: don't record; the overlay shows the message.
    case noSpeech(String)
    /// Speech ready, language model not: dictation inserts the raw transcript, edits can't run. The overlay shows the note.
    case raw(String)
    case full

    /// `llm` is the cleanup model's status; `.ready` for providers that don't load in-process.
    public init(speech: ModelStatus, llm: ModelStatus) {
        switch speech {
        case .ready:
            switch llm {
            case .ready: self = .full
            case .downloading(let f): self = .raw("raw — downloading model \(Int(f * 100))%")
            default: self = .raw("raw — model loading")
            }
        case .failed(let m): self = .noSpeech("Speech model failed to load (retrying): \(m)")
        case .downloading(let f): self = .noSpeech("Downloading speech model \(Int(f * 100))%")
        case .loading: self = .noSpeech("Speech model loading…")
        }
    }
}

/// A dictation inserted raw because the language model was loading, kept to clean up in place once it's ready.
public struct RawInsert: Sendable {
    public var request: Request
    /// For history: the unboosted transcript and the boost terms of the original request.
    public var rawTranscript: String
    public var boost: [String]
    /// Spacing PopTalk added before the paste, and the field's text right after it (nil: unreadable).
    public var prefix: String
    public var fieldValue: String?
    /// The press's resolved sources (#96), for learning from it and for its cleanup.
    public var sources: ContextSources

    public init(request: Request, rawTranscript: String, boost: [String], prefix: String = "", fieldValue: String? = nil,
                sources: ContextSources = ContextSources()) {
        (self.request, self.rawTranscript, self.boost) = (request, rawTranscript, boost)
        (self.prefix, self.fieldValue, self.sources) = (prefix, fieldValue, sources)
    }
}

extension LastInsert {
    /// A raw insert may be cleaned up only while its field is focused and its text is exactly as PopTalk left it.
    public func canReprocess(focused: Target?, value: String?) -> Bool {
        guard let fieldValue = reprocess?.fieldValue, focused == target else { return false }
        return value == fieldValue
    }
}
