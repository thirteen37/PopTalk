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

    public static func terms(from text: String, limit: Int = 200) -> [String] {
        var counts: [String: (term: String, count: Int, first: Int)] = [:]
        var order = 0
        func emit(_ term: String) {
            guard term.count >= 3, !stopwords.contains(term.lowercased()) else { return }
            let key = term.lowercased()
            if let e = counts[key] { counts[key]!.count = e.count + 1 } else {
                counts[key] = (term, 1, order); order += 1
            }
        }

        for line in text.split(whereSeparator: \.isNewline).map(String.init) {
            let ns = line as NSString
            var phrase: [String] = []
            var phraseEnd = -1
            func flush() { if !phrase.isEmpty { emit(phrase.joined(separator: " ")) }; phrase = [] }

            for (i, m) in token.matches(in: line, range: NSRange(location: 0, length: ns.length)).enumerated() {
                let word = ns.substring(with: m.range)
                let before = ns.substring(to: m.range.location).trimmingCharacters(in: .whitespaces)
                // Line starts count as labels (UI text), not sentence starts.
                let sentenceStart = i > 0 && (before.last.map { ".!?".contains($0) } ?? false)
                let isIdentifier = word.contains { $0.isNumber || $0 == "_" || $0 == "-" }
                let isCamel = zip(word, word.dropFirst()).contains { $0.isLowercase && $1.isUppercase }
                let isAllCaps = word.count >= 2 && word.allSatisfy { $0.isUppercase }
                let isCapitalized = word.first!.isUppercase && !sentenceStart

                if isIdentifier || isCamel || isAllCaps {
                    flush(); emit(word)
                } else if isCapitalized {
                    let adjacent = !phrase.isEmpty && ns.substring(with: NSRange(location: phraseEnd, length: m.range.location - phraseEnd)) == " "
                    if !adjacent { flush() }
                    phrase.append(word)
                    phraseEnd = m.range.location + m.range.length
                } else {
                    flush()
                }
            }
            flush()
        }
        return counts.values
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.first < $1.first }
            .prefix(limit)
            .map(\.term)
    }
}
