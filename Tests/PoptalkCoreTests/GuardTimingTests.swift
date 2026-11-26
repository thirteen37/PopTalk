import Foundation
import Testing
@testable import PoptalkCore

// #117: per-step cost of the dictation string code, on invented text, for docs/guards.md. Opt-in, since it times
// (its one check is the skip gate's budget): `POPTALK_GUARD_TIMING=1 swift test --filter guardTiming` (debug). The doc's numbers are
// -O: this body without the Testing lines, compiled with Sources/PoptalkCore/*.swift (docs/guards.md, Performance).
@Test(.enabled(if: ProcessInfo.processInfo.environment["POPTALK_GUARD_TIMING"] == "1"))
func guardTiming() {
    let sentence = "so the quarterly report for Acme Corp is due on Friday and we need twenty five percent more data from the "
        + "FluidAudio team, sorry, the speech team, before we send it out quote final draft unquote new line "
    let screen = (0..<40).map { "Line \($0) of the Northwind ticket NW-\($0 * 7) mentions Acme Corp, Toivonen and the Q3 OKRs." }
        .joined(separator: "\n")
    let terms = (0..<60).map { "Term\($0)Name" } + ["Acme Corp", "FluidAudio", "Toivonen", "Q3 OKRs"]
    func median(_ n: Int, _ f: () -> Void) -> Double {
        (0..<n).map { _ in
            let t = DispatchTime.now().uptimeNanoseconds
            f()
            return Double(DispatchTime.now().uptimeNanoseconds - t) / 1000
        }.sorted()[n / 2]
    }
    for (label, words) in [("38 words", 1), ("190 words", 5)] {
        let said = String(repeating: sentence, count: words)
        let clean = String(repeating: "The quarterly report for Acme Corp is due on Friday, and the speech team sends the data before then. ",
                           count: 2 * words).trimmingCharacters(in: .whitespaces)
        let transcript = Pipeline.dictationPrepass(said)
        let reply = "<think></think>" + transcript.replacingOccurrences(of: "sorry, the speech team, ", with: "")
        let check = Pipeline.ReplyCheck(limit: Pipeline.maxCleanupLength(transcript), screen: screen)
        var rows: [(String, Double)] = [
            ("stripHesitations", median(200) { _ = Pipeline.stripHesitations(said) }),
            ("recaseTerms", median(200) { _ = Pipeline.recaseTerms(said, terms: terms, screen: screen) }),
            // On a clean dictation: a cue ("sorry") would return before the term shortlist.
            ("skipsLLM", median(9) { _ = Pipeline.skipsLLM(said: clean, transcript: clean, terms: terms) }),
            // Past the 40-word cap too (#120), which skipsLLM stops at.
            ("termShortlist", median(9) { _ = Pipeline.termShortlist(clean, terms: terms) }),
        ]
        rows += Pipeline.prepass.map { s in (s.name, median(200) { _ = s.run(said) }) }
        rows += Pipeline.repairs.map { s in (s.name, median(200) { _ = s.run(reply, transcript) }) }
        let cleaned = Pipeline.repairs.reduce(reply) { $1.run($0, transcript) }
        rows += Pipeline.rejects.map { s in (s.name, median(200) { _ = s.test(cleaned, transcript, check) }) }
        print("guardTiming \(label) (\(said.count) chars): " + rows.map { "\($0.0) \(String(format: "%.0f", $0.1)) µs" }.joined(separator: ", "))
        // #120 budget, debug: 104 ms measured at 38 words (-O: 4.8 ms, and 170 ms before the prefilter).
        #expect(rows.first { $0.0 == "skipsLLM" }!.1 < 400_000, "skipsLLM over budget at \(label)")
    }
}
