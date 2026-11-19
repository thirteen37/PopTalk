import Foundation

/// Pulls likely-misheard names out of on-screen text: proper nouns and capitalized
/// phrases, camelCase, ALLCAPS, and identifiers with digits, `_` or `-`.
public enum TermExtractor {
    // ponytail: tiny stopword list, swap for NLTagger if common words leak through.
    private static let stopwords: Set<String> = [
        "the", "and", "for", "but", "not", "you", "your", "this", "that", "with", "from",
        "are", "was", "has", "have", "will", "can", "all", "our", "new", "now", "here", "there",
    ]
    private static let token = try! NSRegularExpression(pattern: #"[\p{L}\p{N}](?:[\p{L}\p{N}_\-']*[\p{L}\p{N}])?"#)

    /// Terms ranked by distance from `cursor` (UTF-16 offset into `text`; nil = end), presence in
    /// the window title, and frequency. `weight` is the score, at most 10 (a saved term's default).
    public static func terms(from text: String, cursor: Int? = nil, title: String = "", limit: Int = 60) -> [VocabTerm] {
        let cursor = cursor ?? text.utf16.count
        var seen: [String: (term: String, count: Int, first: Int, dist: Int, title: Bool)] = [:]
        var order = 0
        /// `at` is a UTF-16 offset into `text`, or nil for the title.
        func emit(_ term: String, at: Int?) {
            guard term.count >= 3, !stopwords.contains(term.lowercased()) else { return }
            let key = term.lowercased(), dist = at.map { abs($0 - cursor) } ?? 0
            if let e = seen[key] { seen[key] = (e.term, e.count + 1, e.first, min(e.dist, dist), e.title || at == nil) } else {
                seen[key] = (term, 1, order, dist, at == nil); order += 1
            }
        }

        func scan(_ s: String, isTitle: Bool) {
            var base = 0
            for line in s.components(separatedBy: .newlines) {
                defer { base += line.utf16.count + 1 }
                let ns = line as NSString
                var phrase: [String] = []
                var phraseStart = 0, phraseEnd = -1
                func at(_ loc: Int) -> Int? { isTitle ? nil : base + loc }
                func flush() { if !phrase.isEmpty { emit(phrase.joined(separator: " "), at: at(phraseStart)) }; phrase = [] }

                for (i, m) in token.matches(in: line, range: NSRange(location: 0, length: ns.length)).enumerated() {
                    let word = ns.substring(with: m.range)
                    // Line starts count as labels (UI text), not sentence starts.
                    // O(1) look-back: previous non-space UTF-16 unit before the token.
                    var j = m.range.location - 1
                    while j >= 0, ns.character(at: j) == 0x20 || ns.character(at: j) == 0x09 { j -= 1 }
                    let sentenceStart = i > 0 && j >= 0 && [0x2E, 0x21, 0x3F].contains(ns.character(at: j))
                    let isIdentifier = word.contains { $0.isNumber || $0 == "_" || $0 == "-" }
                    let isCamel = zip(word, word.dropFirst()).contains { $0.isLowercase && $1.isUppercase }
                    let isAllCaps = word.count >= 2 && word.allSatisfy { $0.isUppercase }
                    let isCapitalized = word.first!.isUppercase && !sentenceStart

                    if isIdentifier || isCamel || isAllCaps {
                        flush(); emit(word, at: at(m.range.location))
                    } else if isCapitalized {
                        let adjacent = !phrase.isEmpty && ns.substring(with: NSRange(location: phraseEnd, length: m.range.location - phraseEnd)) == " "
                        if !adjacent { flush() }
                        if phrase.isEmpty { phraseStart = m.range.location }
                        phrase.append(word)
                        phraseEnd = m.range.location + m.range.length
                    } else {
                        flush()
                    }
                }
                flush()
            }
        }
        scan(title, isTitle: true)
        scan(text, isTitle: false)

        // ponytail: hand-tuned score (proximity halves at 500 chars); tune on #23 term recall/precision.
        let scored = seen.values.map { e -> (term: String, first: Int, score: Float) in
            let near: Float = 6 / (1 + Float(e.dist) / 500)
            return (e.term, e.first, near + (e.title ? 2 : 0) + 0.4 * Float(min(e.count, 5)))
        }
        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.first < $1.first }
            .prefix(limit)
            .map { VocabTerm(text: $0.term, weight: $0.score) }
    }
}
