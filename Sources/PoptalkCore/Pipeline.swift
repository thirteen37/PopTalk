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
                cleanupTimeout: TimeInterval = 4, editTimeout: TimeInterval = 20) {
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
            // Base covers cold starts; 20 ms per word covers long dictations.
            let words = transcript.split(whereSeparator: \.isWhitespace).count
            // Model chatter guard: a cleanup far longer than what was said is the model answering, not cleaning.
            if let reply = try? await complete(cleanupModel, messages, false, cleanupTimeout + 0.02 * Double(words)),
               case let cleaned = Self.stripChatter(reply), !cleaned.isEmpty,
               Double(cleaned.count) <= Double(transcript.count) * 1.5 + 40,
               !Self.echoesContext(cleaned, transcript: transcript,
                                   context: r.context.windowTitle + " " + Prompts.trimmedContext(r.context)) {
                return PipelineResult(outcome: .insert(space + cleaned, label: "Dictated"))
            }
            return PipelineResult(outcome: .insert(space + transcript, label: "Dictated (raw)"))
        }

        let ns = transcript as NSString
        if let m = Self.literally.firstMatch(in: transcript, range: NSRange(location: 0, length: ns.length)) {
            let text = ns.substring(from: m.range.length)
            return PipelineResult(outcome: Self.isBlank(text) ? .nothing : .replaceSelection(text, label: "Replaced"))
        }

        let messages = Prompts.edit(instruction: transcript, selection: selection, context: r.context, vocabulary: vocabulary.terms)
        let raw: String
        do { raw = try await complete(editModel, messages, true, editTimeout) } catch {
            let timedOut = (error as? URLError)?.code == .timedOut
            return PipelineResult(outcome: .error(timedOut ? "Model took too long" : "Couldn't reach the language model"))
        }
        guard let edit = try? LLMClient.parseEditResult(raw) else {
            return PipelineResult(outcome: .error("Didn't understand the model's reply"))
        }

        // An empty replacement would silently delete the selection.
        if edit.action != .insertBefore, edit.action != .insertAfter, Self.isBlank(edit.text) {
            return PipelineResult(outcome: .nothing)
        }
        let outcome: Outcome = switch edit.action {
        case .replace: .replaceSelection(edit.text, label: "Replaced")
        case .correct: .replaceSelection(edit.text, label: "Corrected")
        case .edit: .replaceSelection(edit.text, label: "Edited")
        // Models sometimes repeat the selection in an insert; drop it so it isn't duplicated.
        case .insertBefore: .insertBefore(edit.text.hasSuffix(selection) ? String(edit.text.dropLast(selection.count)) : edit.text)
        case .insertAfter: .insertAfter(edit.text.hasPrefix(selection) ? String(edit.text.dropFirst(selection.count)) : edit.text)
        }
        guard let term = edit.vocabulary else { return PipelineResult(outcome: outcome) }
        if edit.remember, (try? vocabulary.add(term)) != nil {
            return PipelineResult(outcome: outcome, remembered: term)
        }
        return PipelineResult(outcome: outcome, vocabularyOffer: term)
    }
}

extension Pipeline {
    /// Saved vocabulary, then up to 60 screen terms ranked by closeness to the cursor in the
    /// window the LLM sees, for speech-recognition boosting.
    public static func boostTerms(saved: [VocabTerm], context: ScreenSnapshot) -> [VocabTerm] {
        let known = Set(saved.map { $0.text.lowercased() })
        let w = Prompts.window(context)
        return saved + TermExtractor.terms(from: w.text, cursor: w.cursor, title: context.windowTitle)
            .filter { !known.contains($0.text.lowercased()) }
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

    static func isBlank(_ s: String) -> Bool {
        s.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)).isEmpty
    }

    /// True when most of `output`'s words (and at least 3) weren't said but are on screen:
    /// the model echoed `<screen>` instead of cleaning the transcript (#29).
    static func echoesContext(_ output: String, transcript: String, context: String) -> Bool {
        func words(_ s: String) -> [Substring] { s.lowercased().split { !$0.isLetter && !$0.isNumber } }
        let said = Set(words(transcript)), shown = Set(words(context)), out = words(output)
        let echoed = out.filter { !said.contains($0) && shown.contains($0) }.count
        return echoed >= 3 && echoed * 2 > out.count
    }

    /// Removes reasoning blocks and echoed tags from a model reply.
    static func stripChatter(_ s: String) -> String {
        think.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A space before inserted text when the cursor follows a non-space, non-opening character.
    static func leadingSpace(_ c: ScreenSnapshot) -> String {
        let ns = c.text as NSString  // AX offsets are UTF-16
        guard let at = c.cursorOffset, at > 0, at <= ns.length else { return "" }
        return leadingSpace(after: Character(ns.substring(with: NSRange(location: at - 1, length: 1))))
    }

    /// A space unless `prev` is missing, whitespace, or an opening bracket/quote.
    static func leadingSpace(after prev: Character?) -> String {
        guard let prev else { return "" }
        return prev.isWhitespace || "([{\"'“‘".contains(prev) ? "" : " "
    }
}
