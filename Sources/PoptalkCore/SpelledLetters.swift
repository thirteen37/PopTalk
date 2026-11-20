import Foundation

extension Pipeline {
    /// How each letter's name sounds, so letters Parakeet heard for a spoken name ("Ajay" → "R J") can be
    /// compared with the spelling after them ("ar"+"jay" ≈ "ajay").
    private static let letterNames: [Character: String] = [
        "a": "ay", "b": "bee", "c": "see", "d": "dee", "e": "ee", "f": "ef", "g": "gee", "h": "aitch", "i": "eye",
        "j": "jay", "k": "kay", "l": "el", "m": "em", "n": "en", "o": "oh", "p": "pee", "q": "cue", "r": "ar",
        "s": "es", "t": "tee", "u": "you", "v": "vee", "w": "doubleyou", "x": "ex", "y": "why", "z": "zee"]

    /// The word spelled by single letters at the end of an edit utterance (#50), or nil to leave it to the model.
    /// Letters may be spaced, hyphenated or comma-separated: "A J A Y", "capital T-O-D-O-I-S-T".
    /// The run can start with letters heard for the spoken name ("R J A J A Y"), so each suffix of 3+ letters
    /// is scored by its best similarity (edit distance, raw or on a consonant skeleton) to the selection, to the
    /// words just before the run, or to how the letters before it sound. The best suffix wins (ties: the longest)
    /// if it scores at least 0.6. "capital" uppercases the next letter (the rest lowercase); "all caps" uppercases
    /// all; otherwise the word is capitalized ("Ajay").
    /// ponytail: string similarity, not phonetics; a misheard name that sounds alike but spells differently
    /// (e.g. "Kate" before "C A I T") still falls to the model. Use a phonetic key (Metaphone) if history shows it.
    public static func spelledWord(_ utterance: String, selection: String) -> String? {
        let tokens = utterance.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "'") }.map(String.init)
        var letters: [Character] = [], capital: [Bool] = []
        var i = tokens.count - 1
        while i >= 0, tokens[i].count == 1, let c = tokens[i].first, c.isLetter {
            letters.insert(c, at: 0)
            let marked = i > 0 && tokens[i - 1] == "capital"
            capital.insert(marked, at: 0)
            i -= marked ? 2 : 1
        }
        guard letters.count >= 3 else { return nil }
        let head = tokens[..<(i + 1)]
        let allCaps = head.suffix(2) == ["all", "caps"]
        let words = head.suffix(3).filter { !["all", "caps", "capital"].contains($0) }.map { $0.filter(\.isLetter) }
        let refs = [selection.lowercased().filter(\.isLetter)] + words
            + zip(words, words.dropFirst()).map { $0 + $1 }

        var best: (k: Int, score: Double)?
        for k in 0...(letters.count - 3) {
            let word = String(letters[k...])
            let spoken = letters[..<k].compactMap { letterNames[$0] }.joined()
            let score = (refs + (k > 0 ? [spoken] : [])).map { similarity(word, $0) }.max() ?? 0
            if score > (best?.score ?? 0) { best = (k, score) }
        }
        guard let best, best.score >= 0.6 else { return nil }
        let word = String(letters[best.k...])
        if allCaps { return word.uppercased() }
        let marks = capital[best.k...]
        guard marks.contains(true) else { return word.prefix(1).uppercased() + word.dropFirst() }
        return String(zip(word, marks).map { $1 ? Character($0.uppercased()) : $0 })
    }

    /// 1 − edit distance / longer length, the better of the raw strings and their consonant skeletons.
    static func similarity(_ a: String, _ b: String) -> Double {
        func sim(_ a: String, _ b: String) -> Double {
            let n = max(a.count, b.count)
            return n == 0 ? 0 : 1 - Double(levenshtein(Array(a), Array(b))) / Double(n)
        }
        return max(sim(a, b), sim(skeleton(a), skeleton(b)))
    }

    /// First letter, then consonants other than h/w/y, repeats collapsed: "todoist" → "tdst", "arjee" → "arj".
    static func skeleton(_ s: String) -> String {
        var out = ""
        for (n, c) in s.enumerated() where n == 0 || (!"aeiouyhw".contains(c) && out.last != c) { out.append(c) }
        return out
    }

    static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        var row = Array(0...b.count)
        for (i, ca) in a.enumerated() {
            var prev = row[0]
            row[0] = i + 1
            for (j, cb) in b.enumerated() {
                let cur = row[j + 1]
                row[j + 1] = min(row[j + 1] + 1, row[j] + 1, prev + (ca == cb ? 0 : 1))
                prev = cur
            }
        }
        return row[b.count]
    }
}
