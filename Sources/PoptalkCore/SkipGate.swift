import Foundation

/// The #75 dictation settings, read per press like `ContextSources` so a change applies to the next one.
public struct DictationFeatures: Sendable, Equatable {
    public enum Key {
        public static let recaseTerms = "recaseScreenTerms", skipGate = "skipLLMGate", soundAlikeTerms = "soundAlikeTerms"
        public static let fidelityProbe = "fidelityProbe"
    }
    /// "Fix screen-term casing before cleanup": still only for the models `Pipeline.recasesTerms` names.
    public var recaseTerms = true
    /// Screen terms for recasing too: on while any screen text is read, apart from screen-word boosting (#130:
    /// recasing can't swap words). Off ("Don't read the screen" in an app): saved and learned terms only.
    public var screenTerms = true
    /// "Skip cleanup for clean dictations (experimental)".
    public var skipGate = false
    /// Sound-alike terms (#75 step 2, experimental, no Settings UI yet): `termShortlist` runs the cleanup model
    /// confirms (`Pipeline.termScore`) become the term before cleanup. Only where `recaseTerms` runs.
    public var soundAlikeTerms = false
    /// The learned fidelity guard (#75 step 2, no Settings UI): a reply `Pipeline.fidelityScore` puts below
    /// `fidelityProbeThreshold` goes in raw, after the deterministic rejects. On by default since the owner's review
    /// of real history; only where `fidelityScore` is set (MLX).
    public var fidelityProbe = true
    /// Scores the probe and records it without acting: PoptalkBench `--replay --fidelity shadow` only.
    public var fidelityShadow = false
    /// `Pipeline.guardNames` steps turned off: PoptalkBench `--guards -name,…` only (#108).
    public var guardsOff: Set<String> = []

    public init() {}

    /// Unset keys take the defaults; `POPTALK_SKIP_LLM=1` or `0` overrides the skip gate. `sources`: the press's
    /// resolved sources (#96), else the global ones.
    public init(_ d: UserDefaults, sources: ContextSources? = nil,
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        recaseTerms = d.object(forKey: Key.recaseTerms) as? Bool ?? true
        let s = sources ?? ContextSources(d)
        screenTerms = s.focusedText || s.nearbyText || s.ocr || s.windowTitle || s.webDomain
        skipGate = environment["POPTALK_SKIP_LLM"].map { $0 == "1" } ?? d.bool(forKey: Key.skipGate)
        soundAlikeTerms = d.bool(forKey: Key.soundAlikeTerms)
        fidelityProbe = d.object(forKey: Key.fidelityProbe) as? Bool ?? true
    }
}

extension Pipeline {
    /// Fillers and self-corrections, which need the model (raw passes 1 of 10). Hesitations are matched in what
    /// was said, before `stripHesitations`: they often come with a correction.
    private static let cue = try! NSRegularExpression(pattern: """
        \\b(?:u+m+|u+h+|e+r+m*|h*m{2,}|like|basically|literally|you know|i mean|i meant|actually|sorry|scratch that\
        |make that|rather|wait|oops|correction)\\b|\\bno\\s*,|,\\s*no\\b|\\b(\\w+)\\s+\\1\\b
        """, options: .caseInsensitive)

    /// Spoken lists, punctuation, symbols and spellings (3+ single letters) the pre-pass leaves for the model.
    private static let command = try! NSRegularExpression(pattern: """
        \\b(?:bullet|new line|new paragraph|quote|unquote|paren|parenthesis|brackets?|comma|period|full stop\
        |question mark|exclamation (?:point|mark)|colon|semicolon|dash|hyphen|ellipsis|underscore|slash|backslash\
        |hashtag|asterisk|ampersand|at sign|dot|all caps|capital|emoji|smiley|number (?:one|two|three))\\b\
        |\\bfirst\\b.*\\bsecond\\b|(?<!\\p{L})(?:\\p{L}[\\s,-]+){2,}\\p{L}(?!\\p{L})
        """, options: .caseInsensitive)

    private static let token = try! NSRegularExpression(pattern: #"[\p{L}\p{N}][\p{L}\p{N}'’\-]*"#)

    /// True when the cleanup model can be skipped and `transcript` (stripped, recased and pre-passed) inserted as
    /// is: no filler or correction cue in `said`, no spoken command the pre-pass left, at most `skipGateMaxWords`
    /// words, no near-miss of a term (`recaseCandidates`), and Parakeet's sentence casing and closing punctuation.
    /// A near miss is a run of 1–3 words, not spelled exactly like a term or one of its names, at least 0.75
    /// `similarity` to it ("Maheena" for "Mahina", "Toy Vonen" for "Toivonen", "fluid audio" left as heard).
    /// ponytail: keyword lists and string similarity; a decision model only if this skips wrongly too often.
    public static func skipsLLM(said: String, transcript: String, terms: [String]) -> Bool {
        skipGateStop(said: said, transcript: transcript, terms: terms) == nil
    }

    /// Longer dictations keep the model, which bounds the term shortlist's cost (#120). On real history every
    /// dictation over 40 words stopped at a cue first (#122).
    static let skipGateMaxWords = 40

    /// The first `skipsLLM` check that keeps the model, in order: "casing", "punctuation", "cue", "command",
    /// "length" (over `skipGateMaxWords`), "term" (a near miss); nil when the gate skips. Replay counts only (#122).
    public static func skipGateStop(said: String, transcript: String, terms: [String]) -> String? {
        func has(_ re: NSRegularExpression, _ s: String) -> Bool { re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
        let end = transcript.trimmingCharacters(in: CharacterSet(charactersIn: "\"”’')] \n"))
        if transcript.first(where: \.isLetter)?.isUppercase != true { return "casing" }
        guard let last = end.last, ".!?".contains(last) else { return "punctuation" }
        if has(cue, said) { return "cue" }
        if has(command, transcript) { return "command" }
        if transcript.split(whereSeparator: \.isWhitespace).count > skipGateMaxWords { return "length" }
        return termShortlist(transcript, terms: terms).isEmpty ? nil : "term"
    }

    /// A run of `transcript` that may be a misheard term (#75 step 2), for the yes/no term check to confirm.
    public struct TermCandidate: Equatable, Sendable {
        public var range: NSRange, heard: String, term: String, score: Double
    }

    /// The near misses `skipsLLM` looks for: runs of 1–3 words, not spelled exactly like a term or one of its names
    /// (a multi-word term's non-dictionary words, 4+ letters), at least 0.75 like it by `similarity` on the raw
    /// strings or on `soundFold`ed ones. Runs overlapping an exact term are left out ("to TestFlight").
    public static func termShortlist(_ transcript: String, terms: [String]) -> [TermCandidate] {
        func squash(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let forms = terms.flatMap { t in [t] + (t.contains(" ") ? t.split(separator: " ").map(String.init).filter { !isCommonWord($0) } : []) }
            .filter { squash($0).count >= 4 }
        let ns = transcript as NSString
        let tokens = token.matches(in: transcript, range: NSRange(location: 0, length: ns.length)).map(\.range)
        let words = tokens.map { ns.substring(with: $0).replacing(/['’]s$/, with: "") }
        let runs = (1...3).flatMap { n in words.count < n ? [] : (0...(words.count - n)).map { $0..<$0 + n } }
        let exact = runs.filter { r in forms.contains(words[r].joined(separator: " ")) }
        // The score is `max(similarity(heard, form), similarity(soundFold(heard), soundFold(form)))`, unrolled: the
        // best `1 − edit distance / longer length` of four pairs (the strings, their skeletons, the folded strings,
        // their skeletons), each term's computed once per call (#120). Edit distance is at least the length
        // difference, so a pair scores at most shorter / longer and can reach 0.75 only if 4 × shorter ≥ 3 × longer.
        // A pair that can't is skipped: it can't be the best of a kept score, and with none left the run is out.
        func key(_ s: String) -> [[Character]] {
            let fold = soundFold(s)
            return [s, skeleton(s), fold, skeleton(fold)].map(Array.init)
        }
        let keyed = forms.map { (form: $0, key: key(squash($0))) }
        let all = runs.filter { r in !exact.contains { $0.overlaps(r) } }.flatMap { r -> [TermCandidate] in
            let heard = key(squash(words[r].joined(separator: " ")))
            let range = NSUnionRange(tokens[r.lowerBound], tokens[r.upperBound - 1])
            return keyed.compactMap { f, k in
                let score = zip(heard, k).map { a, b in
                    let n = max(a.count, b.count)
                    return n == 0 || 4 * min(a.count, b.count) < 3 * n ? 0 : 1 - Double(levenshtein(a, b)) / Double(n)
                }.max()!
                return score >= 0.75 ? TermCandidate(range: range, heard: ns.substring(with: range), term: f, score: score) : nil
            }
        }
        // Per term, the best of overlapping runs ("grav links", not "grav links now"); ties: the closer spelling
        // ("kas ia", not "kas", for "Kasia"), then the earlier.
        func raw(_ c: TermCandidate) -> Int { -levenshtein(Array(squash(c.heard)), Array(squash(c.term))) }
        var kept: [TermCandidate] = []
        for c in all.sorted(by: { ($1.score, raw($1), $0.range.location) < ($0.score, raw($0), $1.range.location) })
        where !kept.contains(where: { $0.term == c.term && NSIntersectionRange($0.range, c.range).length > 0 }) { kept.append(c) }
        return kept.sorted { $0.range.location < $1.range.location }
    }

    /// log P(yes) − log P(no) at the first reply token to `termCheck(heard:term:)`, from `model`.
    public typealias TermScore = @Sendable (_ model: String, _ heard: String, _ term: String) async throws -> Double

    /// The lowest `MLXProvider.termScore` with no false yes on training/term_pairs.jsonl, on the v6 E2B LoRA
    /// (`PoptalkBench --term-shortlist … --score`): on term_pairs_heldout.jsonl with the shortlist in front,
    /// precision 0.96, recall 0.79. Fitted on v6 and not refitted for the default v7 (#123, #149). ponytail: one
    /// threshold for every E2B fine-tune; refit per adapter if another ships (base E2B fits about −12 in
    /// `training/term_probe.py`).
    public static let termScoreThreshold = -7.12

    /// The yes/no question `TermScore` asks, as `training/term_probe.py` does.
    public static func termCheck(heard: String, term: String) -> [ChatMessage] {
        [ChatMessage(role: "user", content: "A speech recognizer heard '\(heard)'. Is that the term '\(term)' (the same word or name, "
                     + "misheard or split up)? Answer yes or no.")]
    }

    /// `transcript` with each `termShortlist` run that `score` puts at or above `termScoreThreshold` written as its
    /// term; overlapping runs: the higher score. A failed check leaves its run as heard.
    static func soundAlikeTerms(_ transcript: String, terms: [String],
                                score: (String, String) async throws -> Double) async -> String {
        var yes: [(c: TermCandidate, s: Double)] = []
        for c in termShortlist(transcript, terms: terms) {
            if let s = try? await score(c.heard, c.term), s >= termScoreThreshold { yes.append((c, s)) }
        }
        var kept: [TermCandidate] = []
        for (c, _) in yes.sorted(by: { $0.s > $1.s }) where !kept.contains(where: { NSIntersectionRange($0.range, c.range).length > 0 }) {
            kept.append(c)
        }
        return kept.sorted { $0.range.location > $1.range.location }
            .reduce(transcript as NSString) { $0.replacingCharacters(in: $1.range, with: $1.term) as NSString } as String
    }

    /// Spellings English speech can't tell apart, folded together: "x" → "ks", soft "c" → "s", "c"/"q" → "k",
    /// "ph" → "f", "z" → "s" ("grav links" for "Gravlynx").
    static func soundFold(_ s: String) -> String {
        [("ph", "f"), ("x", "ks"), ("qu", "kw"), ("q", "k"), ("z", "s")].reduce(
            s.replacing(/c(?=[eiy])/, with: "s").replacing("ck", with: "k").replacing("c", with: "k")) { $0.replacing($1.0, with: $1.1) }
    }
}
