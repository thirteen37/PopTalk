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
    public static func applyBoosts(_ raw: String, _ replacements: [(span: String, term: String)], terms: [VocabTerm],
                                   minSimilarity: Double = 0.7) -> String {
        func squash(_ s: some StringProtocol) -> String { SpeechMetrics.words(String(s)).joined() }
        return replacements.reduce(raw) { text, r in
            let forms = ([r.term] + (terms.first { $0.text.lowercased() == r.term.lowercased() }?.aliases ?? [])).map(squash)
            let words = r.span.split(separator: " ")
            var best: (run: Range<Int>, score: Double) = (0..<0, 0)
            for i in words.indices {
                for j in i + 1...words.count {
                    let heard = squash(words[i..<j].joined(separator: " "))
                    if heard.contains(where: \.isNumber), !r.term.contains(where: \.isNumber) { continue }
                    let score = forms.map { similarity(heard, $0) }.max() ?? 0
                    if score > best.score { best = (i..<j, score) }  // ties: the earlier, shorter run
                }
            }
            guard best.score >= minSimilarity,
                  let at = text.range(of: #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: r.span) + #"(?![\p{L}\p{N}])"#,
                                      options: [.regularExpression, .caseInsensitive])
            else { return text }
            func edge(_ w: Substring, _ end: Bool) -> String {
                let p = { (c: Character) in !c.isLetter && !c.isNumber }
                return end ? String(w.reversed().prefix(while: p).reversed()) : String(w.prefix(while: p))
            }
            let term = edge(words[best.run.first!], false) + r.term + edge(words[best.run.last!], true)
            let respelled = (words[..<best.run.lowerBound].map(String.init) + [term] + words[best.run.upperBound...].map(String.init))
            return text.replacingCharacters(in: at, with: respelled.joined(separator: " "))
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
