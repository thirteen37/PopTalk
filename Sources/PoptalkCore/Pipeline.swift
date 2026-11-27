import Foundation

public struct Request: Sendable {
    public var transcript: String
    public var selection: String?
    public var context: ScreenSnapshot
    /// The press's resolved cleanup level (#96); dictations only, and only for `Pipeline.levels` models.
    public var cleanup: CleanupLevel

    public init(transcript: String, selection: String?, context: ScreenSnapshot, cleanup: CleanupLevel = .clean) {
        self.transcript = transcript
        self.selection = selection
        self.context = context
        self.cleanup = cleanup
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
    /// The skip gate inserted the dictation without the cleanup model (#75).
    public var skippedLLM: Bool
    /// Screen or learned terms (not saved vocabulary) whose spelling the casing fix wrote (#87).
    public var recased: [String] = []
    /// Shift was held (#131, `Pipeline.asHeard`): inserted as heard, so nothing is learned from it.
    public var asHeard = false
    /// The guard that turned a dictation reply into a raw fallback: empty, echoesContext, length, dropsContent
    /// or dropsProtected (replay counts); nil when there was no reply or it was used.
    public var rejectedBy: String?
    /// The `Pipeline.repairs` that changed a dictation reply beyond surrounding whitespace, in order (replay counts).
    public var repaired: [String] = []
    /// With the skip gate on: the check that kept the model (`skipGateStop`, nil if it skipped) and the gate's
    /// own seconds (#122, replay counts).
    public var skipGateStop: String?
    public var skipGateSeconds: Double?
    /// The fidelity probe's score of the repaired reply and its own seconds (#75 step 2), when it ran; replay counts.
    public var fidelityScore: Double?
    public var fidelitySeconds: Double?

    public init(outcome: Outcome, vocabularyOffer: VocabTerm? = nil, remembered: VocabTerm? = nil, degraded: Bool = false,
                modelAction: String? = nil, skippedLLM: Bool = false) {
        self.outcome = outcome
        self.skippedLLM = skippedLLM
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
    /// Learned screen terms (#87), boosted and recased like saved vocabulary; empty with the setting off.
    let learned: [VocabTerm]
    let cleanupModel: String, editModel: String
    let cleanupTimeout: TimeInterval, editTimeout: TimeInterval
    /// Term recasing and the skip gate (#75); the app reads them from Settings on each press.
    let features: DictationFeatures
    /// False for speculative runs (#43): a "remember" edit reports `remembered` without saving it.
    public var remembers = true
    /// The yes/no term check for `DictationFeatures.soundAlikeTerms` (#75 step 2): MLX only; nil skips it.
    public var termScore: TermScore?
    /// The fidelity probe (#75 step 2, `DictationFeatures.fidelityProbe`): MLX only; nil skips it.
    public var fidelityScore: YesNoScore?
    /// The cleanup model was trained on the level tag (#96): `ModelSettings.levelModels`, or PoptalkBench `--levels`.
    /// Otherwise every dictation is sent and checked as Clean.
    public var levels: Bool

    public init(complete: @escaping Complete, vocabulary: VocabularyStore, learned: [VocabTerm] = [], cleanupModel: String, editModel: String,
                cleanupTimeout: TimeInterval = 4, editTimeout: TimeInterval = 20, features: DictationFeatures = DictationFeatures()) {
        self.features = features
        self.complete = complete
        self.vocabulary = vocabulary
        self.learned = learned
        self.cleanupModel = cleanupModel
        self.editModel = editModel
        self.cleanupTimeout = cleanupTimeout
        self.editTimeout = editTimeout
        self.levels = ModelSettings.levelModels.contains(cleanupModel)
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
            let screen = r.context.titleAndDomain + "\n" + Prompts.trimmedContext(r.context)
            let saved = vocabulary.terms.map(\.text)
            let terms = Self.boostTerms(saved: vocabulary.terms, learned: learned, context: r.context).map(\.text)
            let recase = Self.recaseOverride ?? (features.recaseTerms && Self.recasesTerms(cleanupModel))
            let recaseWith = features.screenTerms ? terms : saved + learned.map(\.text)
            var recased = !recase ? transcript : Self.recaseTerms(transcript, terms: recaseWith, screen: screen)
            if recase, features.soundAlikeTerms, let termScore {
                recased = await Self.soundAlikeTerms(recased, terms: Self.recaseCandidates(recaseWith)) {
                    try await termScore(cleanupModel, $0, $1)
                }
            }
            let fixed = !recase ? [] : Self.termsWritten(from: transcript, to: recased, terms: Self.recaseCandidates(recaseWith),
                                                         saved: saved + Self.recaseCandidates(saved))
            let off = features.guardsOff
            let level = levels ? r.cleanup : .clean
            let transcript = Self.dictationPrepass(recased, off: off, cleanup: level)
            // Everything said was cancelled ("… Scratch that.", #98).
            guard !transcript.isEmpty else { return PipelineResult(outcome: .nothing) }
            let space = Self.leadingSpace(r.context)
            // Near misses count screen terms either way: the model still sees the screen.
            let gateStart = Date()
            let gate = !features.skipGate ? nil
                : (stop: Self.skipGateStop(said: r.transcript, transcript: transcript, terms: Self.recaseCandidates(terms)),
                   seconds: Date().timeIntervalSince(gateStart))
            func result(_ outcome: Outcome, degraded: Bool = false, skippedLLM: Bool = false) -> PipelineResult {
                var res = PipelineResult(outcome: outcome, degraded: degraded, skippedLLM: skippedLLM)
                res.recased = fixed
                (res.skipGateStop, res.skipGateSeconds) = (gate?.stop, gate?.seconds)
                return res
            }
            if let gate, gate.stop == nil { return result(.insert(space + transcript, label: "Dictated"), skippedLLM: true) }
            // Base covers cold starts; 20 ms per word covers long dictations.
            let words = transcript.split(whereSeparator: \.isWhitespace).count
            let messages = Self.dictationMessages(model: cleanupModel, transcript: transcript, context: r.context,
                                                  vocabulary: vocabulary.terms, cleanup: level)
            // Model chatter guard: a cleanup far longer than what was said is the model answering, not cleaning.
            // Providers stop generating once a reply is certainly past it (#100), unless `length` is off (#118).
            let limit = Self.maxCleanupLength(transcript)
            let reply: String?
            do {
                reply = try await Self.$replyLimit.withValue(off.contains("length") ? nil : limit) {
                    try await complete(cleanupModel, messages, false, cleanupTimeout + 0.02 * Double(words))
                }
            }
            catch is ModelLoading {
                return result(.insert(space + transcript, label: "Dictated (raw) · model loading"), degraded: true)
            }
            catch { reply = nil }
            guard let reply else { return result(.insert(space + transcript, label: "Dictated (raw)")) }
            var repaired: [String] = []
            let cleaned = Self.repairs.filter { !off.contains($0.name) }.reduce(reply) { out, step in
                let next = step.run(out, transcript)
                if next.trimmingCharacters(in: .whitespacesAndNewlines) != out.trimmingCharacters(in: .whitespacesAndNewlines) {
                    repaired.append(step.name)
                }
                return next
            }
            var rejectedBy = Self.rejectedBy(reply: cleaned, transcript: transcript,
                                             screen: r.context.titleAndDomain + " " + Prompts.trimmedContext(r.context), level: level, off: off)
            // Scored even after a deterministic reject, so the replay can count the overlap.
            var fidelity: (score: Double?, seconds: Double)?
            if let fidelityScore, features.fidelityProbe || features.fidelityShadow, !cleaned.isEmpty {
                let start = Date()
                let score = try? await fidelityScore(cleanupModel, Self.fidelityCheck(transcript: transcript, reply: cleaned, level: level))
                fidelity = (score, Date().timeIntervalSince(start))
                if rejectedBy == nil, features.fidelityProbe, let score, score < Self.fidelityProbeThreshold { rejectedBy = "fidelityProbe" }
            }
            var res = result(rejectedBy == nil ? .insert(space + cleaned, label: "Dictated") : .insert(space + transcript, label: "Dictated (raw)"))
            res.rejectedBy = rejectedBy
            res.repaired = repaired
            (res.fidelityScore, res.fidelitySeconds) = (fidelity?.score, fidelity?.seconds)
            return res
        }

        let ns = transcript as NSString
        if let m = Self.literally.firstMatch(in: transcript, range: NSRange(location: 0, length: ns.length)) {
            let text = ns.substring(from: m.range.length)
            return PipelineResult(outcome: Self.isBlank(text) ? .nothing : .replaceSelection(text, label: "Replaced"))
        }
        // #50: a trailing spelling ("… A J A Y") is a correction to that word; before #53, which would paste the letters.
        if let word = Self.spelledWord(transcript, selection: selection) {
            let offer = word.caseInsensitiveCompare(selection) == .orderedSame ? nil : VocabTerm(text: word, aliases: [selection.lowercased()])
            return PipelineResult(outcome: .replaceSelection(word, label: "Corrected"), vocabularyOffer: offer)
        }
        // #53: "replace this with X" is a whole replacement; the model tends to paste the utterance.
        if let m = Self.replaceWith.firstMatch(in: transcript, range: NSRange(location: 0, length: ns.length)) {
            var text = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            if text.hasSuffix("."), !selection.hasSuffix(".") { text.removeLast() }
            if !Self.isBlank(text) { return PipelineResult(outcome: .replaceSelection(text, label: "Replaced")) }
        }

        let messages = Prompts.edit(instruction: transcript, selection: selection, context: r.context, vocabulary: vocabulary.terms, model: editModel)
        let raw: String
        do { raw = try await complete(editModel, messages, true, editTimeout) }
        // Nothing sensible to do raw with a selection: say so and leave it untouched.
        catch is ModelLoading { return PipelineResult(outcome: .error("Model still loading — selection unchanged")) }
        catch {
            let timedOut = (error as? URLError)?.code == .timedOut
            return PipelineResult(outcome: .error(timedOut ? "Model took too long" : "Couldn't reach the language model"))
        }
        guard var edit = try? LLMClient.parseEditResult(raw) else {
            return PipelineResult(outcome: .error("Didn't understand the model's reply"))
        }
        edit.text = Self.unescape(edit.text)  // #145: the selection went in escaped

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
        if edit.remember, !remembers { return PipelineResult(outcome: outcome, remembered: term, modelAction: edit.action.rawValue) }
        if edit.remember, (try? vocabulary.add(term)) != nil {
            return PipelineResult(outcome: outcome, remembered: term, modelAction: edit.action.rawValue)
        }
        return PipelineResult(outcome: outcome, vocabularyOffer: term, modelAction: edit.action.rawValue)
    }
}

extension Pipeline {
    /// The longest dictation, in words after the prepass, whose prompt gets no screen text (#116).
    public static let shortDictationWords = 5

    /// The screen the cleanup model sees for a dictation of `words` words. Up to `shortDictationWords`, no screen
    /// text: over long screens E2B v6 copied the screen instead of cleaning so short a dictation (#116). App, title,
    /// domain and vocabulary stay. Only the prompt: the casing fix, boost terms and `echoesContext` see it all.
    static func cleanupContext(_ c: ScreenSnapshot, words: Int) -> ScreenSnapshot {
        guard words <= shortDictationWords else { return c }
        var c = c
        (c.text, c.ocrText, c.cursorOffset) = ("", "", nil)
        return c
    }

    /// The cleanup chat for `transcript` (after `dictationPrepass`), with `cleanupContext`'s screen. `PoptalkDatagen
    /// render` builds training prompts with it too, so they match the app's (#124).
    public static func dictationMessages(model: String, transcript: String, context: ScreenSnapshot,
                                         vocabulary: [VocabTerm], cleanup: CleanupLevel = .clean) -> [ChatMessage] {
        let words = transcript.split(whereSeparator: \.isWhitespace).count
        return Prompts.dictation(model: model, transcript: transcript, context: cleanupContext(context, words: words),
                                 vocabulary: vocabulary, cleanup: cleanup)
    }

    /// Saved vocabulary, then learned screen terms (#87), then up to 60 screen terms ranked by closeness to the cursor
    /// in the window the LLM sees, for speech-recognition boosting. Each gets its `boostAliases`.
    /// `fromScreen` false (#40): saved and learned terms only. A single dictionary word ("Install", "Setup") from the
    /// screen or the learned list is left out, as `recaseCandidates` leaves it: boosted, it swapped real words ("installed"
    /// → "Install", #130). Saved terms always stay.
    public static func boostTerms(saved: [VocabTerm], learned: [VocabTerm] = [], context: ScreenSnapshot,
                                  fromScreen: Bool = true) -> [VocabTerm] {
        var known = Set<String>()
        let w = Prompts.window(context)
        let screen = fromScreen ? TermExtractor.terms(from: w.text, cursor: w.cursor, title: context.titleAndDomain) : []
        let guessed = (learned + screen).filter { $0.text.contains(" ") || !isCommonWord($0.text) }
        return (saved + guessed).filter { known.insert($0.text.lowercased()).inserted }
            .map { t in
                var t = t
                t.aliases += boostAliases(t.text).filter { a in !t.aliases.contains { $0.lowercased() == a } }
                return t
            }
    }

    /// How many of `boost` (from `boostTerms`) came from saved vocabulary, learned terms and the screen, for the log (#88).
    public static func boostSources(_ boost: [VocabTerm], saved: [VocabTerm], learned: [VocabTerm]) -> (saved: Int, learned: Int, screen: Int) {
        let s = Set(saved.map { $0.text.lowercased() }), l = Set(learned.map { $0.text.lowercased() })
        let fromSaved = boost.filter { s.contains($0.text.lowercased()) }.count
        let fromLearned = boost.filter { !s.contains($0.text.lowercased()) && l.contains($0.text.lowercased()) }.count
        return (fromSaved, fromLearned, boost.count - fromSaved - fromLearned)
    }

    /// The longest dictation cleanup the chatter guard accepts, in characters after `stripChatter` and `restoreMarks`.
    public static func maxCleanupLength(_ transcript: String) -> Int { Int(Double(transcript.count) * 1.5 + 40) }

    /// `maxCleanupLength` during a dictation cleanup's `complete`, nil otherwise (edits can legitimately grow, and
    /// with the `length` guard off the whole reply is wanted):
    /// providers stop generating once `pastReplyLimit` holds, since that reply falls back to raw anyway (#100).
    @TaskLocal public static var replyLimit: Int?

    /// True once `partial`, the start of a reply, is past `limit` however the reply goes on. What the guard measures
    /// can't drop below `partial`'s non-space characters after `stripChatter`, less 20: a tag cut mid-way (≤ 13),
    /// one list marker `restoreMarks` removes (≤ 3) and a grapheme joined across chunks. An open <think> may still
    /// close and be stripped, so it never stops. ponytail: spaces never count, so a reply padded with them runs on.
    public static func pastReplyLimit(_ partial: String, limit: Int) -> Bool {
        guard partial.count > limit + 20 else { return false }
        let s = stripChatter(partial)
        return !s.contains("<think>") && s.count(where: { !$0.isWhitespace }) > limit + 20
    }

    private static let think = try! NSRegularExpression(pattern: #"<think>[\s\S]*?</think>|</?transcript>"#)

    private static let hesitation = try! NSRegularExpression(
        pattern: #"(?<![\w-])(?:u+m+|u+h+|e+r+m*|h+m+)(?![\w-])[,.!?]?"#, options: .caseInsensitive)

    /// The dictation guards (#108), in order. `prepass`: what the cleanup model sees of a dictation after
    /// `stripHesitations` and the casing fix. `repairs`: applied to its reply. `rejects`: the first that holds makes
    /// the reply a raw fallback, its name the `rejectedBy`. `DictationFeatures.guardsOff` turns steps off by name.
    public static let prepass: [(name: String, run: @Sendable (String) -> String)] = [
        ("spokenFormatting", spokenFormatting),  // #48
        ("spokenCancel", spokenCancel),  // #98
        ("spokenNumbers", spokenNumbers),  // #59
    ]
    public static let repairs: [(name: String, run: @Sendable (_ out: String, _ said: String) -> String)] = [
        ("stripChatter", { out, _ in stripChatter(out) }),
        ("restoreMarks", { restoreMarks($0, transcript: $1) }),
        ("openingCue", { restoreOpeningCue($0, transcript: $1) }),  // #105
    ]
    /// What a reject sees besides the reply and the transcript: `maxCleanupLength`, the screen the model saw, and the
    /// level it was sent (#96: Clean unless the model takes levels).
    public struct ReplyCheck: Sendable { var limit: Int, screen: String, cleanup = CleanupLevel.clean }
    public static let rejects: [(name: String, test: @Sendable (_ out: String, _ said: String, _ check: ReplyCheck) -> Bool)] = [
        ("empty", { out, _, _ in out.isEmpty }),
        // Before length, so a long screen echo is named an echo (#116).
        ("echoesContext", { out, said, c in echoesContext(out, transcript: said, context: c.screen) }),
        ("length", { out, _, c in out.count > c.limit }),
        // ponytail: the same at every level. Polished fixes grammar and homophones (#96), so its rewording will need a
        // looser `lost` share (or synonym-tolerant matching) when c.cleanup == .polished, once a level-trained model is benched.
        ("dropsContent", { out, said, _ in dropsContent(out, transcript: said) }),
        ("dropsProtected", { out, said, _ in dropsProtected(out, transcript: said) }),
    ]
    public static var guardNames: [String] { prepass.map(\.name) + repairs.map(\.name) + rejects.map(\.name) }

    /// The first of `rejects` not in `off` that holds for a repaired `reply` to the pre-passed `transcript`, with
    /// `screen` what the model saw; nil: the reply is used. PoptalkBench `--fidelity-pairs` scores invented pairs with it.
    public static func rejectedBy(reply: String, transcript: String, screen: String = "", level: CleanupLevel = .clean,
                                  off: Set<String> = []) -> String? {
        let check = ReplyCheck(limit: maxCleanupLength(transcript), screen: screen, cleanup: level)
        return rejects.first { !off.contains($0.name) && $0.test(reply, transcript, check) }?.name
    }

    /// The `prepass` steps not in `off`. PoptalkDatagen render uses it too, so training transcripts match production.
    /// Verbatim (#96) skips spokenCancel: the cue and what it cancels stay, like a self-correction.
    public static func dictationPrepass(_ s: String, off: Set<String> = [], cleanup: CleanupLevel = .clean) -> String {
        prepass.filter { !off.contains($0.name) && !(cleanup == .verbatim && $0.name == "spokenCancel") }.reduce(s) { $1.run($0) }
    }

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

    /// Shift held while dictating (#131): the transcript as heard (boosted, nothing else), spaced like a dictation; a
    /// selection is replaced by it. No prepass, model, casing fix or learning (`asHeard`).
    public static func asHeard(_ r: Request) -> PipelineResult {
        guard !isBlank(r.transcript) else { return PipelineResult(outcome: .nothing) }
        let selected = !(r.selection ?? "").isEmpty
        var res = PipelineResult(outcome: selected ? .replaceSelection(r.transcript, label: "Raw")
                                 : .insert(leadingSpace(r.context) + r.transcript, label: "Raw"))
        res.asHeard = true
        return res
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

    /// Cancellation cues the e4b prompt names. "forget that/it/the" only opens its own unit (#148): after the start, a
    /// . ! ? , ; : or newline, or a lead-in "actually"/"wait"/"no", like `spokenCancel`'s command. "I always forget the
    /// door code" and "don't forget the …" are dictation.
    private static let cancelCue = try! NSRegularExpression(
        pattern: #"\b(?:scratch that|never ?mind)\b|(?:^|[.!?,;:\n]|\b(?:actually|wait|no))[ \t]*[,;:]?[ \t]*forget (?:that|it|the)\b"#,
        options: .caseInsensitive)

    /// True when the cleanup lost more than 3 content words and over 40% of them (#47): the model kept
    /// only part of the dictation, e.g. its last sentence. Self-corrections and fillers lose 1–3.
    /// A word counts as kept if it appears anywhere in the output, so "fluid audio" → "FluidAudio" survives.
    /// ponytail: a dropped sentence under 40% of a long dictation passes; tighten if that shows up in history.
    /// #102: a spoken cancellation drops what it cancels, so only what follows the last cue must stay.
    static func dropsContent(_ output: String, transcript: String) -> Bool {
        let out = output.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" }
        let ns = transcript as NSString
        let said = cancelCue.matches(in: transcript, range: NSRange(location: 0, length: ns.length)).last
            .map { ns.substring(from: NSMaxRange($0.range)) } ?? transcript
        let content = said.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }
            .filter { $0.count >= 3 && !droppable.contains(String($0)) }
        let lost = content.filter { !out.contains($0) }.count
        return lost > 3 && Double(lost) > 0.4 * Double(content.count)
    }

    /// True when the cleanup lost a protected span (#61): the words of each ( … ), “ … ” or " … " in the
    /// transcript must appear in the output together and in order, ignoring case, punctuation and quote
    /// style. Also true when the output has fewer line breaks than the transcript ("new line", #48).
    static func dropsProtected(_ output: String, transcript: String) -> Bool {
        func words(_ s: some StringProtocol) -> String {
            " " + s.lowercased().replacing("’", with: "'").split { !$0.isLetter && !$0.isNumber && $0 != "'" }
                .map { $0.trimmingCharacters(in: ["'"]) }.filter { !$0.isEmpty }.joined(separator: " ") + " "
        }
        let out = words(output)
        if output.filter({ $0 == "\n" }).count < transcript.filter({ $0 == "\n" }).count { return true }
        return transcript.matches(of: /\(([^()]*)\)|“([^“”]*)”|"([^"]*)"/).contains { m in
            let span = words(m.1 ?? m.2 ?? m.3 ?? "")
            return span != "  " && !out.contains(span)
        }
    }

    /// Puts back marks the pre-pass made that the model changed (#75), before the fidelity guards:
    /// - straight quotes around a “ … ” span's words become curly again, and a , or . the model moved inside
    ///   goes back out (`"replace this with,"` → `“replace this with”,`);
    /// - a line break the model flattened goes back between the same two words, when the reply has them
    ///   next to each other. A break with no such place stays lost, so `dropsProtected` still falls back.
    /// - a list marker the model added to a single item goes (#77: v3 adds `- ` to some to-do-like sentences), unless the
    ///   transcript is a list: it says "bullet" or "first … second", has a line break, or starts with a marker.
    static func restoreMarks(_ output: String, transcript: String) -> String {
        func words(_ s: some StringProtocol) -> [String] { SpeechMetrics.words(String(s)) }
        var out = output
        if out.split(separator: "\n").filter({ $0.firstMatch(of: listMarker) != nil }).count == 1, let m = out.firstMatch(of: listMarker),
           !transcript.contains("\n"), transcript.firstMatch(of: listMarker) == nil,
           transcript.firstMatch(of: /(?i)\bbullet|\bfirst\b[\s\S]*\bsecond\b/) == nil {
            out.removeSubrange(m.range)
        }
        for m in transcript.matches(of: /“([^“”]*)”/) {
            let span = words(m.1)
            guard !span.isEmpty, let q = out.matches(of: /"([^"]*)"/).first(where: { words($0.1) == span }) else { continue }
            let inner = String(q.1).replacing(/[,.]+$/, with: "")
            out.replaceSubrange(q.range, with: "“\(inner)”" + q.1.dropFirst(inner.count))
        }
        guard out.filter({ $0 == "\n" }).count < transcript.filter({ $0 == "\n" }).count else { return out }
        let ns = transcript as NSString
        var from = 0  // UTF-16 offset into `out`: each break goes after the previous one
        for m in lineBreak.matches(in: transcript, range: NSRange(location: 0, length: ns.length)) {
            let (before, br, after) = (ns.substring(with: m.range(at: 1)), ns.substring(with: m.range(at: 2)), ns.substring(with: m.range(at: 3)))
            let o = out as NSString
            guard let gap = try? NSRegularExpression(
                pattern: #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: before) + #"[^\p{L}\p{N}\s]*(\h+)"#
                    + NSRegularExpression.escapedPattern(for: after) + #"(?![\p{L}\p{N}])"#, options: .caseInsensitive),
                let g = gap.firstMatch(in: out, range: NSRange(location: from, length: o.length - from))
            else { continue }
            out = o.replacingCharacters(in: g.range(at: 1), with: br)
            from = g.range(at: 1).location + (br as NSString).length
        }
        return out
    }

    /// A cue word opening the transcript, after any hesitation.
    nonisolated(unsafe) private static let openingCue = /^\W*(?:(?:u+m+|u+h+)\b\W*)?(no|sorry|wait|actually)\b/.ignoresCase()

    /// Puts back a cue word that opens the transcript when an accepted cleanup lost it (#105): E2B v6 takes an opening
    /// "no" or "sorry" for a self-correction with nothing before it. It goes back capitalized with ", ", and the output's
    /// first word is lowercased unless it is "I" or an "I'" contraction, has more capitals (an acronym), or the transcript
    /// capitalizes it mid-sentence (a name). Not after a spoken cancel ("never mind"), which can take the opener with it.
    static func restoreOpeningCue(_ output: String, transcript: String) -> String {
        let ns = transcript as NSString
        guard let cue = transcript.firstMatch(of: openingCue)?.1, !isBlank(output),
              cancelCue.firstMatch(in: transcript, range: NSRange(location: 0, length: ns.length)) == nil
        else { return output }
        let out = output.drop(while: \.isWhitespace)
        let word = out.prefix(while: { $0.isLetter || "'’".contains($0) })
        guard word.lowercased() != cue.lowercased() else { return output }
        func named() -> Bool {
            transcript.ranges(of: word).contains { r in
                let before = transcript[..<r.lowerBound]
                guard transcript[r.upperBound...].first?.isLetter != true, before.last?.isLetter != true,
                      let p = before.last(where: { !$0.isWhitespace }) else { return false }
                return !".!?\n".contains(p)
            }
        }
        let keep = word.isEmpty || word == "I" || word.hasPrefix("I'") || word.hasPrefix("I’")
            || word.dropFirst().contains(where: \.isUppercase) || named()
        return cue.prefix(1).uppercased() + cue.dropFirst().lowercased() + ", " + (keep ? String(out) : out.prefix(1).lowercased() + out.dropFirst())
    }

    /// `- `, `* `, `• `, `– ` or `1. ` / `1) ` at the start of a line.
    nonisolated(unsafe) private static let listMarker = /^\h*(?:[-*•–]|\d{1,2}[.)])\h+/

    /// A word, then a line break (and anything but words around it), then the next word (looked ahead, so it
    /// can also start the next break).
    private static let lineBreak = try! NSRegularExpression(pattern: #"([\p{L}\p{N}]+)[^\p{L}\p{N}\n]*(\n+)[^\p{L}\p{N}\n]*(?=([\p{L}\p{N}]+))"#)

    /// Removes reasoning blocks and echoed tags from a model reply, then undoes `Prompts.attr`'s escaping (#145).
    static func stripChatter(_ s: String) -> String {
        unescape(think.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The inverse of `Prompts.attr` (#145): the prompt shows "R&D" as "R&amp;D", and the model can copy that.
    /// &amp; goes last, so "&amp;lt;" stays a literal "&lt;".
    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&amp;", with: "&")
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
