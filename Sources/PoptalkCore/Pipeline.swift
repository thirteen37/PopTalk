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
        let transcript = Self.stripHesitations(r.transcript)
        guard !transcript.isEmpty else { return PipelineResult(outcome: .nothing) }

        guard let selection = r.selection, !selection.isEmpty else {
            let messages = Prompts.dictation(transcript: transcript, context: r.context, vocabulary: vocabulary.terms)
            let space = Self.leadingSpace(r.context)
            // Model chatter guard: a cleanup far longer than what was said is the model answering, not cleaning.
            if let reply = try? await complete(cleanupModel, messages, false, cleanupTimeout),
               case let cleaned = Self.stripChatter(reply), !cleaned.isEmpty,
               Double(cleaned.count) <= Double(transcript.count) * 1.5 + 40 {
                return PipelineResult(outcome: .insert(space + cleaned, label: "Dictated"))
            }
            return PipelineResult(outcome: .insert(space + transcript, label: "Dictated (raw)"))
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

extension Pipeline {
    /// Saved vocabulary plus terms from the capped on-screen context, for speech-recognition boosting.
    public static func boostTerms(saved: [VocabTerm], context: ScreenSnapshot) -> [VocabTerm] {
        let known = Set(saved.map { $0.text.lowercased() })
        return saved + TermExtractor.terms(from: Prompts.trimmedContext(context))
            .filter { !known.contains($0.lowercased()) }
            .map { VocabTerm(text: $0) }
    }

    private static let think = try! NSRegularExpression(pattern: #"<think>[\s\S]*?</think>|</?transcript>"#)

    private static let hesitation = try! NSRegularExpression(
        pattern: #"\b(?:u+m+|u+h+|e+r+m*|h+m+)\b[,.!?]?"#, options: .caseInsensitive)

    /// Drops pure hesitation sounds (um, uh, er, erm, hmm). Context-dependent fillers
    /// ("like", "basically", "you know") are left to the LLM, since they can be real words.
    static func stripHesitations(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        var out = hesitation.stringByReplacingMatches(
            in: trimmed, range: NSRange(location: 0, length: (trimmed as NSString).length), withTemplate: "")
        out = out.replacingOccurrences(of: #"\s+([,.!?])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters).subtracting(CharacterSet(charactersIn: ".!?\"')")))
        if trimmed.first?.isUppercase == true, let f = out.first { out = f.uppercased() + out.dropFirst() }
        return out
    }

    /// Removes reasoning blocks and echoed tags from a model reply.
    static func stripChatter(_ s: String) -> String {
        think.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A space before inserted text when the cursor follows a non-space, non-opening character.
    static func leadingSpace(_ c: ScreenSnapshot) -> String {
        let ns = c.text as NSString  // AX offsets are UTF-16
        guard let at = c.cursorOffset, at > 0, at <= ns.length,
              let prev = Character(ns.substring(with: NSRange(location: at - 1, length: 1))) as Character?
        else { return "" }
        return prev.isWhitespace || "([{\"'“‘".contains(prev) ? "" : " "
    }
}
