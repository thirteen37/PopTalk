import AppKit

extension Pipeline {
    /// #75: whether `recaseTerms` runs before the cleanup model: the E2B fine-tunes, which keep the transcript's
    /// casing and spacing as given. E4B fixes screen terms itself and regressed when some were pre-fixed.
    public static func recasesTerms(_ model: String) -> Bool { recaseOverride ?? model.lowercased().contains("gemma-4-e2b-poptalk") }
    /// PoptalkBench `--recase-terms on|off`; the app never sets it.
    public nonisolated(unsafe) static var recaseOverride: Bool?

    /// Rewrites each span of `transcript` that equals one of `terms` (saved vocabulary and screen terms, as
    /// `boostTerms` lists them) up to case and whitespace to the term's spelling: "meal prep" → "Meal Prep",
    /// "fluid audio" → "FluidAudio". There are no labels, so it holds back:
    /// - whole words only; a term under 5 characters joins only pieces of 3+ characters or single letters
    ///   ("d b t" → "DBT", but not "an a" → "Ana");
    /// - a single-word term made of dictionary words ("Inbox", "Work", "follow-up") is skipped, and a phrase
    ///   mixing dictionary words and names ("Call Priya") gives only its names;
    /// - a term `screen` shows in more than one spelling ("PopTalk" and "Poptalk", "Meal Prep" and "meal prep").
    public static func recaseTerms(_ transcript: String, terms: [String], screen: String) -> String {
        recaseCandidates(terms).reduce(transcript) { text, term in
            // ponytail: a Title Case UI label made of common words ("Recent Files") is recased like "Meal Prep";
            // drop all-dictionary phrases too if history shows wrong ones.
            let chars = term.filter { !$0.isWhitespace }.map { NSRegularExpression.escapedPattern(for: String($0)) }
            guard !chars.isEmpty, let re = try? NSRegularExpression(
                pattern: #"(?<![\p{L}\p{N}])"# + chars.joined(separator: #"\s*"#) + #"(?![\p{L}\p{N}])"#, options: .caseInsensitive)
            else { return text }
            func spans(_ s: String) -> [NSRange] { re.matches(in: s, range: NSRange(s.startIndex..., in: s)).map(\.range) }
            let shown = Set(spans(screen).map { (screen as NSString).substring(with: $0).split(whereSeparator: \.isWhitespace).joined(separator: " ") })
            guard shown.count <= 1 else { return text }
            let own = term.lowercased().split(separator: " ")
            var out = text as NSString
            for r in spans(text).reversed() {
                let pieces = out.substring(with: r).lowercased().split(whereSeparator: \.isWhitespace)
                guard chars.count >= 5 || pieces.count == 1 || pieces == own || pieces.allSatisfy({ $0.count >= 3 })
                        || pieces.allSatisfy({ $0.count == 1 }) else { continue }
                out = out.replacingCharacters(in: r, with: term) as NSString
            }
            return out as String
        }
    }

    /// The terms worth recasing, longest first: no single dictionary words; a phrase of only dictionary words
    /// ("Meal Prep") as is; any other phrase without its leading dictionary words ("Call Priya" → "Priya",
    /// "Yarrowly Freight" stays) and each of its other words alone.
    static func recaseCandidates(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        return terms.flatMap { t -> [String] in
            let words = t.split(separator: " ").map(String.init)
            let common = words.map(isCommonWord)
            if !common.contains(false) { return words.count > 1 ? [t] : [] }
            let names = zip(words, common).filter { !$1 }.map(\.0)
            return [words.drop { isCommonWord($0) }.joined(separator: " ")] + (words.count > 1 ? names : [])
        }
        .filter { seen.insert($0.lowercased()).inserted }
        .sorted { $0.count > $1.count }
    }

    nonisolated(unsafe) private static var common: [String: Bool] = [:]
    private static let commonLock = NSLock()

    /// No digits, and every run of letters is spelled right in English, lowercased ("inbox", "follow-up").
    /// NSSpellChecker isn't documented as thread-safe: calls are serialized and cached.
    static func isCommonWord(_ word: String) -> Bool {
        guard !word.contains(where: \.isNumber) else { return false }
        let runs = word.lowercased().split { !$0.isLetter }.map(String.init)
        return !runs.isEmpty && commonLock.withLock {
            runs.allSatisfy { run in
                if let known = common[run] { return known }
                let miss = NSSpellChecker.shared.checkSpelling(of: run, startingAt: 0, language: "en", wrap: false,
                                                               inSpellDocumentWithTag: 0, wordCount: nil)
                common[run] = miss.location == NSNotFound
                return common[run]!
            }
        }
    }
}
