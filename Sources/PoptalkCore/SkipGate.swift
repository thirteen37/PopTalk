import Foundation

/// The #75 dictation settings, read per press like `ContextSources` so a change applies to the next one.
public struct DictationFeatures: Sendable, Equatable {
    public enum Key { public static let recaseTerms = "recaseScreenTerms", skipGate = "skipLLMGate" }
    /// "Fix screen-term casing before cleanup": still only for the models `Pipeline.recasesTerms` names.
    public var recaseTerms = true
    /// Screen terms for recasing too (#40 "Boost recognition with words on screen"); off: saved vocabulary only.
    public var screenTerms = true
    /// "Skip cleanup for clean dictations (experimental)".
    public var skipGate = false

    public init() {}

    /// Unset keys take the defaults; `POPTALK_SKIP_LLM=1` or `0` overrides the skip gate. `sources`: the press's
    /// resolved sources (#96), else the global ones.
    public init(_ d: UserDefaults, sources: ContextSources? = nil,
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        recaseTerms = d.object(forKey: Key.recaseTerms) as? Bool ?? true
        screenTerms = (sources ?? ContextSources(d)).screenVocabulary
        skipGate = environment["POPTALK_SKIP_LLM"].map { $0 == "1" } ?? d.bool(forKey: Key.skipGate)
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
    /// is: no filler or correction cue in `said`, no spoken command the pre-pass left, no near-miss of a term
    /// (`recaseCandidates`), and Parakeet's sentence casing and closing punctuation.
    /// A near miss is a run of 1–3 words, not spelled exactly like a term or one of its names, at least 0.75
    /// `similarity` to it ("Maheena" for "Mahina", "Toy Vonen" for "Toivonen", "fluid audio" left as heard).
    /// ponytail: keyword lists and string similarity; a decision model only if this skips wrongly too often.
    public static func skipsLLM(said: String, transcript: String, terms: [String]) -> Bool {
        func has(_ re: NSRegularExpression, _ s: String) -> Bool { re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
        let end = transcript.trimmingCharacters(in: CharacterSet(charactersIn: "\"”’')] \n"))
        guard transcript.first(where: \.isLetter)?.isUppercase == true, let last = end.last, ".!?".contains(last),
              !has(cue, said), !has(command, transcript) else { return false }

        func squash(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let forms = terms.flatMap { t in [t] + (t.contains(" ") ? t.split(separator: " ").map(String.init).filter { !isCommonWord($0) } : []) }
            .filter { squash($0).count >= 4 }
        let ns = transcript as NSString
        let words = token.matches(in: transcript, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range).replacing(/['’]s$/, with: "")
        }
        // Runs of 1–3 words; those overlapping an exact term are left out ("to TestFlight" isn't a near miss).
        let runs = (1...3).flatMap { n in words.count < n ? [] : (0...(words.count - n)).map { $0..<$0 + n } }
        let exact = runs.filter { r in forms.contains(words[r].joined(separator: " ")) }
        return !runs.contains { r in
            let run = words[r].joined(separator: " ")
            return !exact.contains { $0.overlaps(r) } && forms.contains { similarity(squash(run), squash($0)) >= 0.75 }
        }
    }
}
