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
    /// Inserted raw because the language model was still loading: can be cleaned up once it's ready.
    public var degraded: Bool
    /// The edit model's parsed action (`EditAction` raw value) before code guards; nil without an edit model reply (#54).
    public var modelAction: String?

    public init(outcome: Outcome, vocabularyOffer: VocabTerm? = nil, remembered: VocabTerm? = nil, degraded: Bool = false,
                modelAction: String? = nil) {
        self.outcome = outcome
        self.vocabularyOffer = vocabularyOffer
        self.remembered = remembered
        self.degraded = degraded
        self.modelAction = modelAction
    }
}

/// Decides what a hotkey press does. All side effects are injected.
public struct Pipeline: Sendable {
    public typealias Complete = @Sendable (_ model: String, _ messages: [ChatMessage], _ json: Bool, _ timeout: TimeInterval) async throws -> String

    /// Thrown by a `Complete` whose model isn't loaded yet: dictation falls back to the raw transcript.
    public struct ModelLoading: Error { public init() {} }

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
    // Object must be the selection itself (or absent): "replace the commas with …" is an edit.
    // "change this to French / bullet points" is usually a transform, so change/changed stay with the model.
    // The lookahead keeps "replace this with something shorter / a more formal one" with the model too.
    private static let replaceWith = try! NSRegularExpression(
        pattern: #"^\s*(?:replace|replaced|replacing|swap|swapped)(?:\s+(?:this|that|it|the\s+selection))?\s+(?:with|to|for)\s+(?!(?:be|more|less|something|a\s+(?:more|less))\b)([\s\S]+)$"#,
        options: .caseInsensitive)

    public func run(_ r: Request) async -> PipelineResult {
        let transcript = Self.stripHesitations(r.transcript)
        guard !transcript.isEmpty else { return PipelineResult(outcome: .nothing) }

        guard let selection = r.selection, !selection.isEmpty else {
            let transcript = Self.spokenNumbers(Self.spokenFormatting(transcript))
            let messages = Prompts.dictation(transcript: transcript, context: r.context, vocabulary: vocabulary.terms)
            let space = Self.leadingSpace(r.context)
            // Base covers cold starts; 20 ms per word covers long dictations.
            let words = transcript.split(whereSeparator: \.isWhitespace).count
            // Model chatter guard: a cleanup far longer than what was said is the model answering, not cleaning.
            let reply: String?
            do { reply = try await complete(cleanupModel, messages, false, cleanupTimeout + 0.02 * Double(words)) }
            catch is ModelLoading {
                return PipelineResult(outcome: .insert(space + transcript, label: "Dictated (raw) · model loading"), degraded: true)
            }
            catch { reply = nil }
            if let reply, case let cleaned = Self.stripChatter(reply), !cleaned.isEmpty,
               Double(cleaned.count) <= Double(transcript.count) * 1.5 + 40,
               !Self.dropsContent(cleaned, transcript: transcript),
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
        // #53: "replace this with X" is a whole replacement; the model tends to paste the utterance.
        if let m = Self.replaceWith.firstMatch(in: transcript, range: NSRange(location: 0, length: ns.length)) {
            var text = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            if text.hasSuffix("."), !selection.hasSuffix(".") { text.removeLast() }
            if !Self.isBlank(text) { return PipelineResult(outcome: .replaceSelection(text, label: "Replaced")) }
        }

        let messages = Prompts.edit(instruction: transcript, selection: selection, context: r.context, vocabulary: vocabulary.terms)
        let raw: String
        do { raw = try await complete(editModel, messages, true, editTimeout) }
        // Nothing sensible to do raw with a selection: say so and leave it untouched.
        catch is ModelLoading { return PipelineResult(outcome: .error("Model still loading — selection unchanged")) }
        catch {
            let timedOut = (error as? URLError)?.code == .timedOut
            return PipelineResult(outcome: .error(timedOut ? "Model took too long" : "Couldn't reach the language model"))
        }
        guard let edit = try? LLMClient.parseEditResult(raw) else {
            return PipelineResult(outcome: .error("Didn't understand the model's reply"))
        }

        // A bare phrase over a selection replaces it; models sometimes pick insert anyway.
        var action = edit.action
        if action == .insertBefore || action == .insertAfter, !Self.asksToInsert(transcript) { action = .replace }
        // An empty replacement would silently delete the selection.
        if action != .insertBefore, action != .insertAfter, Self.isBlank(edit.text) {
            return PipelineResult(outcome: .nothing, modelAction: edit.action.rawValue)
        }
        let outcome: Outcome = switch action {
        case .replace: .replaceSelection(edit.text.trimmingCharacters(in: .whitespaces), label: "Replaced")
        case .correct: .replaceSelection(edit.text, label: "Corrected")
        case .edit: .replaceSelection(edit.text, label: "Edited")
        // Models sometimes repeat the selection in an insert; drop it so it isn't duplicated.
        case .insertBefore: .insertBefore(edit.text.hasSuffix(selection) ? String(edit.text.dropLast(selection.count)) : edit.text)
        case .insertAfter: .insertAfter(edit.text.hasPrefix(selection) ? String(edit.text.dropFirst(selection.count)) : edit.text)
        }
        // Only a term the edit actually produced, and not just the selection, is worth saving.
        guard let term = edit.vocabulary,
              edit.text.localizedCaseInsensitiveContains(term.text),
              term.text.caseInsensitiveCompare(selection) != .orderedSame
        else { return PipelineResult(outcome: outcome, modelAction: edit.action.rawValue) }
        if edit.remember, (try? vocabulary.add(term)) != nil {
            return PipelineResult(outcome: outcome, remembered: term, modelAction: edit.action.rawValue)
        }
        return PipelineResult(outcome: outcome, vocabularyOffer: term, modelAction: edit.action.rawValue)
    }
}

extension Pipeline {
    /// Saved vocabulary, then up to 60 screen terms ranked by closeness to the cursor in the
    /// window the LLM sees, for speech-recognition boosting. Each gets its `boostAliases`.
    /// `fromScreen` false (#40): saved terms only.
    public static func boostTerms(saved: [VocabTerm], context: ScreenSnapshot, fromScreen: Bool = true) -> [VocabTerm] {
        let known = Set(saved.map { $0.text.lowercased() })
        let w = Prompts.window(context)
        let screen = fromScreen ? TermExtractor.terms(from: w.text, cursor: w.cursor, title: context.windowTitle) : []
        return (saved + screen.filter { !known.contains($0.text.lowercased()) })
            .map { t in
                var t = t
                t.aliases += boostAliases(t.text).filter { a in !t.aliases.contains { $0.lowercased() == a } }
                return t
            }
    }

    private static let think = try! NSRegularExpression(pattern: #"<think>[\s\S]*?</think>|</?transcript>"#)

    private static let hesitation = try! NSRegularExpression(
        pattern: #"(?<![\w-])(?:u+m+|u+h+|e+r+m*|h+m+)(?![\w-])[,.!?]?"#, options: .caseInsensitive)

    /// The utterance explicitly asks to add text rather than replace the selection.
    /// English-only, like the speech model (Parakeet v2 transcribes English only): revisit the
    /// keywords if v3 or another multilingual model is enabled.
    /// ponytail: English keyword list; extend if users phrase inserts differently.
    public static func asksToInsert(_ utterance: String) -> Bool {
        utterance.range(of: #"\b(add|append|prepend|insert|before|after|at the (start|end|beginning|top|bottom))\b"#,
                        options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Drops pure hesitation sounds (um, uh, er, erm, hmm). Context-dependent fillers
    /// ("like", "basically", "you know") are left to the LLM, since they can be real words.
    public static func stripHesitations(_ s: String) -> String {
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

    /// Words a faithful cleanup may drop: function words, fillers and self-correction markers.
    private static let droppable: Set<String> = [
        "the", "and", "but", "for", "that", "this", "those", "these", "was", "were", "are", "had", "have", "has",
        "with", "from", "our", "your", "you", "they", "them", "she", "his", "her", "its", "can", "will", "would",
        "should", "could", "about", "into", "than", "then", "there", "what", "also", "just", "like", "basically",
        "know", "mean", "really", "okay", "well", "sorry", "actually", "scratch", "wait", "thing", "kind", "sort"]

    /// True when the cleanup lost more than 3 content words and over 40% of them (#47): the model kept
    /// only part of the dictation, e.g. its last sentence. Self-corrections and fillers lose 1–3.
    /// A word counts as kept if it appears anywhere in the output, so "fluid audio" → "FluidAudio" survives.
    /// ponytail: a dropped sentence under 40% of a long dictation passes; tighten if that shows up in history.
    static func dropsContent(_ output: String, transcript: String) -> Bool {
        let out = output.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" }
        let content = transcript.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }
            .filter { $0.count >= 3 && !droppable.contains(String($0)) }
        let lost = content.filter { !out.contains($0) }.count
        return lost > 3 && Double(lost) > 0.4 * Double(content.count)
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
