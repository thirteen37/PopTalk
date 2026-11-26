import Foundation
import Testing
@testable import PoptalkCore

// #120: `termShortlist` before its length prefilter and per-call term strings, kept here only to check the
// prefilter changes no output.
private func oldTermShortlist(_ transcript: String, terms: [String]) -> [Pipeline.TermCandidate] {
    let token = try! NSRegularExpression(pattern: #"[\p{L}\p{N}][\p{L}\p{N}'’\-]*"#)
    func squash(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
    let forms = terms.flatMap { t in [t] + (t.contains(" ") ? t.split(separator: " ").map(String.init).filter { !Pipeline.isCommonWord($0) } : []) }
        .filter { squash($0).count >= 4 }
    let ns = transcript as NSString
    let tokens = token.matches(in: transcript, range: NSRange(location: 0, length: ns.length)).map(\.range)
    let words = tokens.map { ns.substring(with: $0).replacing(/['’]s$/, with: "") }
    let runs = (1...3).flatMap { n in words.count < n ? [] : (0...(words.count - n)).map { $0..<$0 + n } }
    let exact = runs.filter { r in forms.contains(words[r].joined(separator: " ")) }
    let all = runs.filter { r in !exact.contains { $0.overlaps(r) } }.flatMap { r -> [Pipeline.TermCandidate] in
        let heard = squash(words[r].joined(separator: " "))
        let range = NSUnionRange(tokens[r.lowerBound], tokens[r.upperBound - 1])
        return forms.compactMap { f in
            let score = max(Pipeline.similarity(heard, squash(f)), Pipeline.similarity(Pipeline.soundFold(heard), Pipeline.soundFold(squash(f))))
            return score >= 0.75 ? Pipeline.TermCandidate(range: range, heard: ns.substring(with: range), term: f, score: score) : nil
        }
    }
    func raw(_ c: Pipeline.TermCandidate) -> Int { -Pipeline.levenshtein(Array(squash(c.heard)), Array(squash(c.term))) }
    var kept: [Pipeline.TermCandidate] = []
    for c in all.sorted(by: { ($1.score, raw($1), $0.range.location) < ($0.score, raw($0), $1.range.location) })
    where !kept.contains(where: { $0.term == c.term && NSIntersectionRange($0.range, c.range).length > 0 }) { kept.append(c) }
    return kept.sorted { $0.range.location < $1.range.location }
}

@Test func shortlistPrefilterKeepsTheOutput() {
    // Invented names. Skeleton matches across very different lengths ("baaat" vs "bat") are where a raw-only
    // length window would go wrong.
    let terms = ["Mahina", "Paavo Toivonen", "Gravlynx", "Corvelle", "Kasia", "Peltrix", "Quorbit", "Acme Corp",
                 "FluidAudio", "Xyphos", "Brisolt", "Korvanta", "Zentaxa", "Aaaabt", "Term7Name", "Q3 OKRs", "Ceyx"]
    var transcripts = [
        "Ask Maheena about it.", "Ping toy vonen when the build lands.", "Open grav links now.",
        "Check the core vell build.", "Ask kas ia now.", "Ask pel tricks.", "The cue orbit app crashed.",
        "Send it to ack me corp by Friday.", "The fluid audio model is loaded.", "Call zif oss and bris salt today.",
        "Meet core vanta at noon, then zen tax a.", "A bt and abate, a bat.", "Term seven name and term 7 name.",
        "Q three okay rs are due.", "Seeks and sea x and kicks.", "Can you send me the report by Friday?",
        "Ask Mahina about the Corvelle build.", "Tell Paavo Toivonen.", "Mahin, Mahinaa, Mahiina and Mmahina.",
        "Gravlinks, gravlynks, grav lynx and gravel inks.",
    ]
    // Near misses at every length around each term: one letter dropped, doubled or changed.
    for t in terms {
        let s = t.lowercased().filter(\.isLetter)
        for i in s.indices {
            var dropped = s, doubled = s, changed = s
            dropped.remove(at: dropped.index(dropped.startIndex, offsetBy: s.distance(from: s.startIndex, to: i)))
            doubled.insert(s[i], at: i)
            changed.replaceSubrange(i...i, with: "o")
            transcripts.append("Ask \(dropped) and \(doubled), then \(changed).")
        }
    }
    for s in transcripts {
        #expect(Pipeline.termShortlist(s, terms: terms) == oldTermShortlist(s, terms: terms), "\(s)")
    }
    #expect(transcripts.contains { !oldTermShortlist($0, terms: terms).isEmpty })
}
