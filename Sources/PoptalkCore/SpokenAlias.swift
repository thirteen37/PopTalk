import Foundation

extension Pipeline {
    // NumberFormatter is thread-safe once configured.
    nonisolated(unsafe) private static let spell: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .spellOut
        f.locale = Locale(identifier: "en_US")
        return f
    }()

    /// How a term is likely heard, for a boost alias: camelCase split, `-`, `_` and `.` as spaces, digits
    /// spelled out, lowercased (`FluidAudio` → "fluid audio", `gpt-4o` → "gpt four o"). nil when that's
    /// just the term lowercased.
    /// ponytail: digits read as one number ("2026" → "two thousand twenty six"); add year/digit-by-digit
    /// readings if version or year terms need them.
    public static func spokenAlias(_ text: String) -> String? {
        let split = text
            .replacingOccurrences(of: #"(?<=\p{Ll})(?=\p{Lu})|(?<=\p{L})(?=\p{N})|(?<=\p{N})(?=\p{L})|[_.\-]"#, with: " ", options: .regularExpression)
            .replacing(/\d+/) { m in Int(m.output).flatMap { spell.string(from: $0 as NSNumber) } ?? String(m.output) }
        let alias = split.lowercased().replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return alias == text.lowercased() ? nil : alias
    }

    /// CTC boosting thresholds (FluidAudio's `cbw` and `minSimilarity`; `applyBoosts` reuses the similarity), tuned on
    /// the real-voice and synthetic s-* benches (#99): cbw 1 lets a term win on near-equal acoustics, while ≥ 1.5 broke
    /// correctly heard words.
    public static let boostCbw: Float = 1
    public static let boostMinSimilarity: Float = 0.7

    /// `spokenAlias`, plus a phrase's fused form ("Q3 OKRs" → "q3okrs"). FluidAudio leaves alone a span that
    /// equals a term or alias, so a fused recognition isn't cut down to a shorter term ("Q3OKRs" → "OKRs", #30).
    public static func boostAliases(_ text: String) -> [String] {
        let fused = text.contains(" ") ? text.lowercased().replacingOccurrences(of: " ", with: "") : nil
        return [spokenAlias(text), fused].compactMap { $0 }
    }

    /// The rescorer's replacements (each the words it replaced and the term), redone on `raw`, keeping only
    /// plausible ones (#70). FluidAudio's spotter rescue ignores minSimilarity and takes every word under a
    /// detection, so it swapped "Pop Talk build" and "3.30pm" for "PopTalk". Each term goes only onto the run
    /// of its span's words most like the term or an alias (`similarity`), if that reaches `minSimilarity` and has
    /// no digits the term lacks; the span's other words stay. One per span, so at most once per place it was heard.
    /// The run may take in up to one word fewer than the longest form's on either side, when nothing but a space
    /// separates them and they complete the term (#99: with cbw > 0 the rescorer proposes "fluid" for FluidAudio,
    /// which left "FluidAudio audio"). Equal scores go to the closer spelling, then to the earlier, shorter run.
    /// A term made only of dictionary words never replaces correctly spelled words that spell something else (#132).
    public static func applyBoosts(_ raw: String, _ replacements: [(span: String, term: String)], terms: [VocabTerm],
                                   minSimilarity: Double = 0.7) -> String {
        func squash(_ s: some StringProtocol) -> String { SpeechMetrics.words(String(s)).joined() }
        func alnum(_ c: Character?) -> Bool { c.map { $0.isLetter || $0.isNumber } ?? false }
        return replacements.reduce(raw) { text, r in
            let names = [r.term] + (terms.first { $0.text.lowercased() == r.term.lowercased() }?.aliases ?? [])
            let forms = names.map(squash)
            let span = r.span.split(separator: " ")
            guard !span.isEmpty,
                  let at = text.range(of: #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: r.span) + #"(?![\p{L}\p{N}])"#,
                                      options: [.regularExpression, .caseInsensitive])
            else { return text }
            let n = (names.map { $0.split(separator: " ").count }.max() ?? 1) - 1
            var pre: [Substring] = [], post: [Substring] = []
            if n > 0, alnum(span.first!.first), text[..<at.lowerBound].hasSuffix(" ") {
                for w in text[..<at.lowerBound].dropLast().split(separator: " ", omittingEmptySubsequences: false).reversed().prefix(n) {
                    guard alnum(w.first), alnum(w.last) else { break }
                    pre.insert(w, at: 0)
                }
            }
            if n > 0, alnum(span.last!.last), text[at.upperBound...].hasPrefix(" ") {
                for w in text[at.upperBound...].dropFirst().split(separator: " ", omittingEmptySubsequences: false).prefix(n) {
                    guard alnum(w.first) else { break }
                    post.append(w)
                    if !alnum(w.last) { break }
                }
            }
            let words = pre + span + post, core = pre.count..<(pre.count + span.count)
            var best: (run: Range<Int>, score: Double, exact: Double) = (0..<0, 0, 0)
            for i in words.indices where i < core.upperBound {
                for j in max(i + 1, core.lowerBound + 1)...words.count {
                    let heard = squash(words[i..<j].joined(separator: " "))
                    if heard.contains(where: \.isNumber), !r.term.contains(where: \.isNumber) { continue }
                    let score = forms.map { similarity(heard, $0) }.max() ?? 0
                    let exact = forms.map { 1 - Double(levenshtein(Array(heard), Array($0))) / Double(max(heard.count, $0.count, 1)) }.max() ?? 0
                    if (score, exact) > (best.score, best.exact) { best = (i..<j, score, exact) }
                }
            }
            guard best.score >= minSimilarity else { return text }
            // #132: a term of only dictionary words ("Install", "Projects", "Pull Requests") doesn't replace correctly
            // spelled words ("installed", "the requests") unless they spell the term or a "heard as" form ("in box" → "Inbox").
            let run = words[best.run]
            if !forms.contains(squash(run.joined(separator: " "))), run.allSatisfy({ isCommonWord(squash($0)) }),
               isDictionaryPhrase(r.term) { return text }
            func edge(_ w: Substring, _ end: Bool) -> String {
                let p = { (c: Character) in !c.isLetter && !c.isNumber }
                return end ? String(w.reversed().prefix(while: p).reversed()) : String(w.prefix(while: p))
            }
            let (lo, hi) = (min(best.run.lowerBound, core.lowerBound), max(best.run.upperBound, core.upperBound))
            let start = text.index(at.lowerBound, offsetBy: -words[lo..<core.lowerBound].reduce(0) { $0 + $1.count + 1 })
            let end = text.index(at.upperBound, offsetBy: words[core.upperBound..<hi].reduce(0) { $0 + $1.count + 1 })
            let term = edge(words[best.run.first!], false) + r.term + edge(words[best.run.last!], true)
            let respelled = words[lo..<best.run.lowerBound].map(String.init) + [term] + words[best.run.upperBound..<hi].map(String.init)
            return text.replacingCharacters(in: start..<end, with: respelled.joined(separator: " "))
        }
    }

    /// Respaces phrase terms heard as one word ("Q3OKRs" → "Q3 OKRs"). Their fused alias stops the rescorer
    /// cutting the word down, but it won't respace it when the acoustic scores tie.
    public static func splitFused(_ text: String, terms: [VocabTerm]) -> String {
        terms.filter { $0.text.contains(" ") }.reduce(text) { s, t in
            let fused = NSRegularExpression.escapedPattern(for: t.text.replacingOccurrences(of: " ", with: ""))
            return s.replacingOccurrences(of: #"(?<![\p{L}\p{N}])"# + fused + #"(?![\p{L}\p{N}])"#,
                                          with: NSRegularExpression.escapedTemplate(for: t.text),
                                          options: [.regularExpression, .caseInsensitive])
        }
    }
}
