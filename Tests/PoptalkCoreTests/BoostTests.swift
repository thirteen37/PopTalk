import Foundation
import Testing
@testable import PoptalkCore

// Separate runs in the same minute (e.g. `--filter 'd-*'` then `'e-*'`) overwrote each other.
@Test func resultFileNamesHaveSecondsAndFilterSlug() {
    #expect(BenchReport.fileName(date: "2026-11-19-230801", provider: "lmstudio", model: "google/gemma-4-e4b-audio", filter: "s-*")
        == "2026-11-19-230801-lmstudio-google_gemma-4-e4b-audio-s.json")
    #expect(BenchReport.fileName(date: "d", provider: "apple", model: "core3", filter: "s-fluid*") == "d-apple-core3-s-fluid.json")
    #expect(BenchReport.fileName(date: "d", provider: "apple", model: "core3", filter: nil) == "d-apple-core3.json")
    #expect(BenchReport.fileName(date: "d", provider: "apple", model: "core3", filter: "*") == "d-apple-core3.json")
    #expect(BenchReport.dateFormat.hasSuffix("HHmmss"))
}

// #30: Parakeet hears "fluid audio" for FluidAudio and "Q3" as "q three"; aliases give the rescorer that form.
@Test func spokenAliasSplitsCamelCaseAndSpellsDigits() {
    #expect(Pipeline.spokenAlias("FluidAudio") == "fluid audio")
    #expect(Pipeline.spokenAlias("TestFlight") == "test flight")
    #expect(Pipeline.spokenAlias("Q3") == "q three")
    #expect(Pipeline.spokenAlias("Q3 OKRs") == "q three okrs")
    #expect(Pipeline.spokenAlias("gpt-4o") == "gpt four o")
    #expect(Pipeline.spokenAlias("iOS 27") == "i os twenty seven")
    #expect(Pipeline.spokenAlias("snake_case") == "snake case")
    for plain in ["Kubernetes", "Meal Prep", "OKRs", "PR"] { #expect(Pipeline.spokenAlias(plain) == nil) }
}

// #30: Parakeet heard "Q3OKRs"; the rescorer's spotter rescue then swapped the whole word for "OKRs".
// A span equal to another term's alias is left alone, so multi-word terms get their fused form too.
@Test func boostAliasesAddFusedFormOfPhrases() {
    #expect(Pipeline.boostAliases("Q3 OKRs") == ["q three okrs", "q3okrs"])
    #expect(Pipeline.boostAliases("Meal Prep") == ["mealprep"])
    #expect(Pipeline.boostAliases("FluidAudio") == ["fluid audio"])
    #expect(Pipeline.boostAliases("Kubernetes") == [])
}

// The fused alias keeps "Q3OKRs" whole, but the rescorer won't respace it when the acoustic scores tie.
@Test func splitFusedRespacesPhraseTermsHeardAsOneWord() {
    let terms = [VocabTerm(text: "Q3 OKRs"), VocabTerm(text: "OKRs"), VocabTerm(text: "Meal Prep")]
    #expect(Pipeline.splitFused("about the Q3OKRs.", terms: terms) == "about the Q3 OKRs.")
    #expect(Pipeline.splitFused("my mealprep and xq3okrs", terms: terms) == "my Meal Prep and xq3okrs")
}

@Test func boostTermsGetSpokenAliases() {
    let terms = Pipeline.boostTerms(saved: [VocabTerm(text: "FluidVoice", aliases: ["fluid voice"]), VocabTerm(text: "TestFlight", weight: 7)],
                                    context: ScreenSnapshot(text: "the Kubernetes PR for FluidAudio"))
    #expect(terms[0] == VocabTerm(text: "FluidVoice", aliases: ["fluid voice"]))  // no duplicate alias
    #expect(terms[1] == VocabTerm(text: "TestFlight", aliases: ["test flight"], weight: 7))
    #expect(terms.first { $0.text == "FluidAudio" }?.aliases == ["fluid audio"])
    #expect(terms.first { $0.text == "Kubernetes" }?.aliases == [])
}

// #30: "Q3" is too short to boost alone (FluidAudio skips terms under 3 characters), so
// "Q3OKRs" was rescored to the only nearby term, "OKRs". Short numbers join their neighbour.
@Test func shortNumbersJoinAdjacentTerms() {
    let terms = TermExtractor.terms(from: "Call Priya re: Q3 OKRs. Update to iOS 27 and gpt-4o").map(\.text)
    #expect(terms.contains("Q3 OKRs"))
    #expect(terms.contains("OKRs"))
    #expect(terms.contains("iOS 27"))
    #expect(terms.contains("gpt-4o"))
    #expect(!terms.contains { $0.hasPrefix("re") || $0.hasPrefix("to ") })
}

@Test func termsLostAreHeardRawButGoneAfterBoosting() {
    // Raw "Q3OKRs" holds "Q3"; boosting to "OKRs" lost it. "Priya" was only gained, never lost.
    #expect(SpeechMetrics.termsLost(["Priya", "Q3", "OKRs"], raw: "call Pria about the Q3OKRs.", boosted: "call Priya about the OKRs.") == ["Q3"])
    #expect(SpeechMetrics.termsLost(["FluidAudio"], raw: "the fluid audio PR", boosted: "the FluidAudio PR") == [])
    let run = SpeechRun(reference: "about the Q3 OKRs", terms: ["Q3", "OKRs"], raw: "about the Q3OKRs", boosted: "about the OKRs",
                        final: "about the OKRs", boostTerms: 2, asrSeconds: 0, rescoreSeconds: 0)
    #expect(run.termsLost == ["Q3"])
}

@Test func termsLostShowInTableAndCompare() throws {
    func rep(lost: [String]?) -> BenchReport {
        var r = BenchRun(output: "o", action: "insert", vocabOffer: nil, seconds: 0.5, failures: [])
        r.speech = SpeechRun(raw: "r", boosted: "b", boostTerms: 2, asrSeconds: 0, rescoreSeconds: 0, werRaw: 0, werBoosted: 0, werFinal: 0,
                             recallRaw: nil, recallBoosted: nil, recallFinal: nil, boostFixed: 0, boostBroken: 0)
        r.speech!.termsLost = lost
        return BenchReport(date: "d", provider: [:], cases: [BenchCaseResult(id: "s1", kind: .dictation, runs: [r])])
    }
    #expect(rep(lost: ["Q3"]).speechSummary()?.termsLost == 1)
    #expect(rep(lost: ["Q3"]).table().contains("lost 1"))
    #expect(rep(lost: nil).speechSummary()?.termsLost == nil)  // results from before the metric
    #expect(BenchReport.compare(rep(lost: ["Q3"]), rep(lost: [])).contains("speech termsLost 1 → 0"))
    #expect(BenchReport.compare(rep(lost: nil), rep(lost: [])).contains("speech termsLost - → 0"))
    // Old results files decode without the field.
    let old = try JSONEncoder().encode(rep(lost: nil))
    #expect(try JSONDecoder().decode(BenchReport.self, from: old).cases[0].runs[0].speech?.termsLost == nil)
}
