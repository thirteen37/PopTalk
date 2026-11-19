import Foundation

public struct Request: Sendable {
    public var transcript: String
    public var selection: String?
    public var context: ScreenSnapshot

    public init(transcript: String, selection: String?, context: ScreenSnapshot) {
        self.transcript = transcript
        self.selection = selection
        self.context = context
    }
}

public enum Outcome: Equatable, Sendable {
    case nothing
    case insert(String, label: String)
    case replaceSelection(String, label: String)
    case insertBefore(String)
    case insertAfter(String)
    case error(String)
}

public struct PipelineResult: Equatable, Sendable {
    public var outcome: Outcome
    public var vocabularyOffer: VocabTerm?
    public var remembered: VocabTerm?

    public init(outcome: Outcome, vocabularyOffer: VocabTerm? = nil, remembered: VocabTerm? = nil) {
        self.outcome = outcome
        self.vocabularyOffer = vocabularyOffer
        self.remembered = remembered
    }
}

/// Decides what a hotkey press does. All side effects are injected.
public struct Pipeline: Sendable {
    public typealias Complete = @Sendable (_ model: String, _ messages: [ChatMessage], _ json: Bool, _ timeout: TimeInterval) async throws -> String

    let complete: Complete
    let vocabulary: VocabularyStore
    let cleanupModel: String, editModel: String
    let cleanupTimeout: TimeInterval, editTimeout: TimeInterval

    public init(complete: @escaping Complete, vocabulary: VocabularyStore, cleanupModel: String, editModel: String,
                cleanupTimeout: TimeInterval = 3, editTimeout: TimeInterval = 20) {
        self.complete = complete
        self.vocabulary = vocabulary
        self.cleanupModel = cleanupModel
        self.editModel = editModel
        self.cleanupTimeout = cleanupTimeout
        self.editTimeout = editTimeout
    }

    private static let literally = try! NSRegularExpression(pattern: #"^\s*literally\s*[:,]?\s*"#, options: .caseInsensitive)

    public func run(_ r: Request) async -> PipelineResult {
        let transcript = r.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { return PipelineResult(outcome: .nothing) }

        guard let selection = r.selection, !selection.isEmpty else {
            let messages = Prompts.dictation(transcript: transcript, context: r.context, vocabulary: vocabulary.terms)
            if let cleaned = try? await complete(cleanupModel, messages, false, cleanupTimeout)
                .trimmingCharacters(in: .whitespacesAndNewlines), !cleaned.isEmpty {
                return PipelineResult(outcome: .insert(cleaned, label: "Dictated"))
            }
            return PipelineResult(outcome: .insert(transcript, label: "Dictated (raw)"))
        }

        let ns = transcript as NSString
        if let m = Self.literally.firstMatch(in: transcript, range: NSRange(location: 0, length: ns.length)) {
            return PipelineResult(outcome: .replaceSelection(ns.substring(from: m.range.length), label: "Replaced"))
        }

        let messages = Prompts.edit(instruction: transcript, selection: selection, context: r.context, vocabulary: vocabulary.terms)
        let raw: String
        do { raw = try await complete(editModel, messages, true, editTimeout) } catch {
            return PipelineResult(outcome: .error("Couldn't reach the language model"))
        }
        guard let edit = try? LLMClient.parseEditResult(raw) else {
            return PipelineResult(outcome: .error("Didn't understand the model's reply"))
        }

        let outcome: Outcome = switch edit.action {
        case .replace: .replaceSelection(edit.text, label: "Replaced")
        case .correct: .replaceSelection(edit.text, label: "Corrected")
        case .edit: .replaceSelection(edit.text, label: "Edited")
        case .insertBefore: .insertBefore(edit.text)
        case .insertAfter: .insertAfter(edit.text)
        }
        guard let term = edit.vocabulary else { return PipelineResult(outcome: outcome) }
        if edit.remember, (try? vocabulary.add(term)) != nil {
            return PipelineResult(outcome: outcome, remembered: term)
        }
        return PipelineResult(outcome: outcome, vocabularyOffer: term)
    }
}
