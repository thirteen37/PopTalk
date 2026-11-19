import Foundation

/// Word-level scoring of recognized text against what was said.
public enum SpeechMetrics {
    /// Lowercased words; anything but letters, digits and apostrophes separates words ("to-do" → "to", "do").
    public static func words(_ s: String) -> [String] {
        s.lowercased().replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
    }

    /// Levenshtein alignment over words: edit count and the reference positions matched exactly.
    static func align(_ ref: [String], _ hyp: [String]) -> (errors: Int, matched: Set<Int>) {
        var d = [[Int]](repeating: [Int](repeating: 0, count: hyp.count + 1), count: ref.count + 1)
        for i in 0...ref.count { d[i][0] = i }
        for j in 0...hyp.count { d[0][j] = j }
        for i in stride(from: 1, through: ref.count, by: 1) {
            for j in stride(from: 1, through: hyp.count, by: 1) {
                d[i][j] = min(d[i - 1][j - 1] + (ref[i - 1] == hyp[j - 1] ? 0 : 1), d[i - 1][j] + 1, d[i][j - 1] + 1)
            }
        }
        var matched = Set<Int>(), (i, j) = (ref.count, hyp.count)
        while i > 0, j > 0 {
            let same = ref[i - 1] == hyp[j - 1]
            if d[i][j] == d[i - 1][j - 1] + (same ? 0 : 1) {
                if same { matched.insert(i - 1) }
                (i, j) = (i - 1, j - 1)
            } else if d[i][j] == d[i - 1][j] + 1 { i -= 1 } else { j -= 1 }
        }
        return (d[ref.count][hyp.count], matched)
    }

    /// (substitutions + deletions + insertions) / reference words.
    public static func wer(reference: String, hypothesis: String) -> Double {
        let ref = words(reference)
        let errors = align(ref, words(hypothesis)).errors
        return ref.isEmpty ? Double(errors) : Double(errors) / Double(ref.count)
    }

    /// Fraction of `terms` present as whole-word sequences, ignoring case and punctuation. `nil` without terms.
    public static func termRecall(_ terms: [String], in text: String) -> Double? {
        guard !terms.isEmpty else { return nil }
        let hyp = " " + words(text).joined(separator: " ") + " "
        return Double(terms.filter { hyp.contains(" " + words($0).joined(separator: " ") + " ") }.count) / Double(terms.count)
    }

    /// Reference words boosting got right that raw recognition missed (`fixed`), and ones raw recognition
    /// heard correctly that boosting replaced (`broken`).
    public static func boostChanges(reference: String, raw: String, boosted: String) -> (fixed: Int, broken: Int) {
        let ref = words(reference)
        let (r, b) = (align(ref, words(raw)).matched, align(ref, words(boosted)).matched)
        return (b.subtracting(r).count, r.subtracting(b).count)
    }
}

/// Speech-stage results for one run of an audio case.
public struct SpeechRun: Codable, Sendable {
    public var raw: String, boosted: String
    public var boostTerms: Int
    public var asrSeconds: Double, rescoreSeconds: Double
    public var werRaw: Double, werBoosted: Double, werFinal: Double
    public var recallRaw: Double?, recallBoosted: Double?, recallFinal: Double?
    public var boostFixed: Int, boostBroken: Int

    public init(raw: String, boosted: String, boostTerms: Int, asrSeconds: Double, rescoreSeconds: Double,
                werRaw: Double, werBoosted: Double, werFinal: Double,
                recallRaw: Double?, recallBoosted: Double?, recallFinal: Double?, boostFixed: Int, boostBroken: Int) {
        self.raw = raw
        self.boosted = boosted
        self.boostTerms = boostTerms
        self.asrSeconds = asrSeconds
        self.rescoreSeconds = rescoreSeconds
        self.werRaw = werRaw
        self.werBoosted = werBoosted
        self.werFinal = werFinal
        self.recallRaw = recallRaw
        self.recallBoosted = recallBoosted
        self.recallFinal = recallFinal
        self.boostFixed = boostFixed
        self.boostBroken = boostBroken
    }

    /// Scores raw and boosted recognition and the pipeline's `final` text against `reference`.
    public init(reference: String, terms: [String], raw: String, boosted: String, final: String,
                boostTerms: Int, asrSeconds: Double, rescoreSeconds: Double) {
        let changes = SpeechMetrics.boostChanges(reference: reference, raw: raw, boosted: boosted)
        self.init(raw: raw, boosted: boosted, boostTerms: boostTerms, asrSeconds: asrSeconds, rescoreSeconds: rescoreSeconds,
                  werRaw: SpeechMetrics.wer(reference: reference, hypothesis: raw),
                  werBoosted: SpeechMetrics.wer(reference: reference, hypothesis: boosted),
                  werFinal: SpeechMetrics.wer(reference: reference, hypothesis: final),
                  recallRaw: SpeechMetrics.termRecall(terms, in: raw),
                  recallBoosted: SpeechMetrics.termRecall(terms, in: boosted),
                  recallFinal: SpeechMetrics.termRecall(terms, in: final),
                  boostFixed: changes.fixed, boostBroken: changes.broken)
    }
}

public struct SpeechSummary: Sendable {
    public var runs: Int, passed: Int
    /// Mean per-utterance WER. ponytail: not corpus WER; fine while utterances are similar in length.
    public var werRaw: Double, werBoosted: Double, werFinal: Double
    public var recallRaw: Double?, recallBoosted: Double?, recallFinal: Double?
    public var boostFixed: Int, boostBroken: Int
    /// fixed / (fixed + broken): of the words boosting changed, how many it changed for the better.
    public var boostPrecision: Double? { boostFixed + boostBroken == 0 ? nil : Double(boostFixed) / Double(boostFixed + boostBroken) }
    public var asrMedian: Double, rescoreMedian: Double, llmMedian: Double
}

func median(_ xs: [Double]) -> Double {
    let t = xs.sorted(), mid = t.count / 2
    return t.isEmpty ? 0 : t.count % 2 == 1 ? t[mid] : (t[mid - 1] + t[mid]) / 2
}

extension BenchReport {
    public func speechSummary() -> SpeechSummary? {
        let runs = cases.flatMap(\.runs).filter { $0.speech != nil }
        let s = runs.map { $0.speech! }
        guard !s.isEmpty else { return nil }
        func mean(_ xs: [Double]) -> Double { xs.reduce(0, +) / Double(xs.count) }
        func meanOpt(_ xs: [Double?]) -> Double? { let v = xs.compactMap { $0 }; return v.isEmpty ? nil : mean(v) }
        return SpeechSummary(
            runs: runs.count, passed: runs.filter(\.passed).count,
            werRaw: mean(s.map(\.werRaw)), werBoosted: mean(s.map(\.werBoosted)), werFinal: mean(s.map(\.werFinal)),
            recallRaw: meanOpt(s.map(\.recallRaw)), recallBoosted: meanOpt(s.map(\.recallBoosted)), recallFinal: meanOpt(s.map(\.recallFinal)),
            boostFixed: s.map(\.boostFixed).reduce(0, +), boostBroken: s.map(\.boostBroken).reduce(0, +),
            asrMedian: median(s.map(\.asrSeconds)), rescoreMedian: median(s.map(\.rescoreSeconds)), llmMedian: median(runs.map(\.seconds)))
    }

    func speechTable() -> String? {
        guard let s = speechSummary() else { return nil }
        func pct(_ x: Double?) -> String { x.map { String(format: "%5.1f%%", 100 * $0) } ?? "     -" }
        return """
            speech     pass \(s.passed)/\(s.runs)   boost fixed \(s.boostFixed) broken \(s.boostBroken) precision \(pct(s.boostPrecision))
                         raw   boosted    final
            WER       \(pct(s.werRaw))    \(pct(s.werBoosted))   \(pct(s.werFinal))
            recall    \(pct(s.recallRaw))    \(pct(s.recallBoosted))   \(pct(s.recallFinal))
            \(String(format: "median    asr %.2fs  rescore %.3fs  llm %.2fs", s.asrMedian, s.rescoreMedian, s.llmMedian))
            """
    }

    /// Per-case changes in boosted recognition, and changed speech summary metrics.
    static func compareSpeech(_ a: BenchReport, _ b: BenchReport) -> [String] {
        let bByID = Dictionary(b.cases.map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x })
        var lines = a.cases.compactMap { ca -> String? in
            guard let x = ca.runs.first?.speech?.boosted, let y = bByID[ca.id]?.runs.first?.speech?.boosted, x != y else { return nil }
            return "changed   \(ca.id) boosted: \"\(x)\" → \"\(y)\""
        }
        guard let sa = a.speechSummary(), let sb = b.speechSummary() else { return lines }
        let metrics: [(String, Double?, Double?)] = [
            ("werRaw", sa.werRaw, sb.werRaw), ("werBoosted", sa.werBoosted, sb.werBoosted), ("werFinal", sa.werFinal, sb.werFinal),
            ("recallRaw", sa.recallRaw, sb.recallRaw), ("recallBoosted", sa.recallBoosted, sb.recallBoosted),
            ("recallFinal", sa.recallFinal, sb.recallFinal), ("boostPrecision", sa.boostPrecision, sb.boostPrecision),
        ]
        func f(_ x: Double?) -> String { x.map { String(format: "%.3f", $0) } ?? "-" }
        lines += metrics.filter { f($0.1) != f($0.2) }.map { "speech \($0.0) \(f($0.1)) → \(f($0.2))" }
        return lines
    }
}
