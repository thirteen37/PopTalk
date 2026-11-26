import AppKit

extension Pipeline {
    /// #75: whether `recaseTerms` runs before the cleanup model: E2B fine-tunes (the default v6, #103, and local
    /// adapter folders from `training/`), which keep the transcript's casing and spacing as given.
    /// E4B fixes screen terms itself and regressed when some were pre-fixed.
    public static func recasesTerms(_ model: String) -> Bool { model.lowercased().contains("gemma-4-e2b-poptalk") }
    /// PoptalkBench `--recase-terms on|off`, over the setting and the model check; the app never sets it.
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
        let onScreen = Folded(screen)
        var text = Folded(transcript)
        for term in recaseCandidates(terms) {
            // ponytail: a Title Case UI label made of common words ("Recent Files") is recased like "Meal Prep";
            // drop all-dictionary phrases too if history shows wrong ones.
            let key = Folded.fold(term), hits = text.spans(key)
            guard !hits.isEmpty else { continue }
            let shown = Set(onScreen.spans(key).map { screen[$0].split(whereSeparator: \.isWhitespace).joined(separator: " ") })
            guard shown.count <= 1 else { continue }
            let length = term.count { !$0.isWhitespace }, own = term.lowercased().split(separator: " ")
            var out = "", from = text.source.startIndex
            for r in hits {
                let pieces = text.source[r].lowercased().split(whereSeparator: \.isWhitespace)
                guard length >= 5 || pieces.count == 1 || pieces == own || pieces.allSatisfy({ $0.count >= 3 })
                        || pieces.allSatisfy({ $0.count == 1 }) else { continue }
                out += text.source[from..<r.lowerBound] + term
                from = r.upperBound
            }
            if from > text.source.startIndex { text = Folded(out + text.source[from...]) }
        }
        return text.source
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

    /// `source` case-folded per Character, without whitespace, with each folded Character's range in `source`: the
    /// casing fix's matching, once per string (#121). Per Character, since a folded form can be longer ("İ", "ß" → "ss").
    struct Folded {
        let source: String
        private(set) var chars: [Character] = [], ranges: [Range<String.Index>] = []

        init(_ s: String) {
            source = s
            for i in s.indices where !s[i].isWhitespace {
                let r = i..<s.index(after: i)
                for c in Self.fold(s[i]) { chars.append(c); ranges.append(r) }
            }
        }

        static func fold(_ c: Character) -> [Character] {
            Array(c.isASCII ? c.lowercased() : String(c).folding(options: .caseInsensitive, locale: nil))
        }
        static func fold(_ s: String) -> [Character] { s.filter { !$0.isWhitespace }.flatMap(fold) }

        /// The ranges of `source` that fold to `key`, whole Characters, with no letter or digit right before or after,
        /// left to right without overlaps.
        func spans(_ key: [Character]) -> [Range<String.Index>] {
            guard let first = key.first else { return [] }
            func wordy(_ c: Character) -> Bool { c.isLetter || c.isNumber }
            var out: [Range<String.Index>] = [], i = 0
            while i + key.count <= chars.count {
                let j = i + key.count - 1
                if chars[i] == first, chars[i...j].elementsEqual(key),
                   i == 0 || ranges[i - 1] != ranges[i], j + 1 == chars.count || ranges[j + 1] != ranges[j] {
                    let r = ranges[i].lowerBound..<ranges[j].upperBound
                    if !(r.lowerBound > source.startIndex && wordy(source[source.index(before: r.lowerBound)]))
                        && !(r.upperBound < source.endIndex && wordy(source[r.upperBound])) {
                        out.append(r)
                        i = j + 1
                        continue
                    }
                }
                i += 1
            }
            return out
        }
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
