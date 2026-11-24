import Foundation

/// PoptalkBench --gate-eval (#75): how the skip gate would have done on history dictations.
public enum GateEval {
    /// How a cleanup reply differs from the transcript. `change` picks one: a line-break change is `formatting`
    /// whatever else changed, and a term recased or written in beats casing and word changes.
    public enum Change: String, CaseIterable, Sendable {
        case same, trimmed, formatting, term, casing, punctuation, casingAndPunctuation, removed, added, replaced
    }

    /// The gate on `said` (the boosted transcript the pipeline got) as `Pipeline.run` applies it, with history's
    /// `boost` list as the press's terms and `screen` (the prompt) for the recaser; and the text a skip inserts.
    /// ponytail: with screen vocabulary off, `run` still counts screen terms as near misses, which `boost` lacks.
    public static func gate(said: String, boost: [String], screen: String, model: String) -> (skips: Bool, transcript: String) {
        let stripped = Pipeline.stripHesitations(said)
        let recased = Pipeline.recasesTerms(model) ? Pipeline.recaseTerms(stripped, terms: boost, screen: screen) : stripped
        let transcript = Pipeline.dictationPrepass(recased)
        return (Pipeline.skipsLLM(said: said, transcript: transcript, terms: Pipeline.recaseCandidates(boost)), transcript)
    }

    /// Words are letter and digit runs, apostrophes kept; `terms` (saved and screen terms) mark a term applied.
    public static func change(from transcript: String, to reply: String, terms: [String]) -> Change {
        if reply == transcript { return .same }
        let ws = CharacterSet.whitespacesAndNewlines
        if reply.trimmingCharacters(in: ws) == transcript.trimmingCharacters(in: ws) { return .trimmed }
        func words(_ s: String) -> [String] {
            s.replacingOccurrences(of: "’", with: "'").split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init)
        }
        let termWords = Set(terms.flatMap { t in words(t).map { $0.lowercased() } + [words(t).joined().lowercased()] })
        let (a, b) = (words(transcript), words(reply))
        let (la, lb) = (a.map { $0.lowercased() }, b.map { $0.lowercased() })
        if reply.filter({ $0 == "\n" }).count != transcript.filter({ $0 == "\n" }).count { return .formatting }
        if la == lb {
            if a == b { return .punctuation }
            let recased = zip(a, b).filter { $0 != $1 }.map { $1.lowercased() }
            if recased.allSatisfy(termWords.contains) { return .term }
            return reply.lowercased() == transcript.lowercased() ? .casing : .casingAndPunctuation
        }
        let diff = lb.difference(from: la)
        let added = diff.insertions.compactMap { if case let .insert(_, w, _) = $0 { w } else { nil } }
        if !added.isEmpty, added.allSatisfy(termWords.contains) { return .term }
        return added.isEmpty ? .removed : diff.removals.isEmpty ? .added : .replaced
    }
}
