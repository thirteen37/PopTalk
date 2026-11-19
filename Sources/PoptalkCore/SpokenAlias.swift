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
