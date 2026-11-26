import Foundation
import Testing
@testable import PoptalkCore

// #117: per-step cost of the dictation string code, on invented text, for docs/guards.md. Opt-in, since it
// times rather than checks: POPTALK_GUARD_TIMING=1 swift test -c release -Xswiftc -enable-testing --filter guardTiming
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
    for (label, words) in [("30 words", 1), ("150 words", 5)] {
        let said = String(repeating: sentence, count: words)
        let transcript = Pipeline.dictationPrepass(said)
        let reply = "<think></think>" + transcript.replacingOccurrences(of: "sorry, the speech team, ", with: "")
        let check = Pipeline.ReplyCheck(limit: Pipeline.maxCleanupLength(transcript), screen: screen)
        var rows: [(String, Double)] = [
            ("stripHesitations", median(200) { _ = Pipeline.stripHesitations(said) }),
            ("recaseTerms", median(200) { _ = Pipeline.recaseTerms(said, terms: terms, screen: screen) }),
            ("skipsLLM", median(200) { _ = Pipeline.skipsLLM(said: said, transcript: transcript, terms: terms) }),
        ]
        rows += Pipeline.prepass.map { s in (s.name, median(200) { _ = s.run(said) }) }
        rows += Pipeline.repairs.map { s in (s.name, median(200) { _ = s.run(reply, transcript) }) }
        let cleaned = Pipeline.repairs.reduce(reply) { $1.run($0, transcript) }
        rows += Pipeline.rejects.map { s in (s.name, median(200) { _ = s.test(cleaned, transcript, check) }) }
        print("guardTiming \(label) (\(said.count) chars): " + rows.map { "\($0.0) \(String(format: "%.0f", $0.1)) µs" }.joined(separator: ", "))
    }
}
