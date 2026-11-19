import Foundation
import Testing
@testable import PoptalkCore

@Test func wordsNormalizeCasePunctuationAndHyphens() {
    #expect(SpeechMetrics.words("Refer to my to-do list, OK? I’ll go.") == ["refer", "to", "my", "to", "do", "list", "ok", "i'll", "go"])
}

@Test func werCountsSubstitutionsDeletionsInsertions() {
    #expect(SpeechMetrics.wer(reference: "Refer to my Meal Prep project on Todoist.", hypothesis: "refer to my meal prep project on todoist") == 0)
    // "todoist" → "to do list": 1 substitution + 2 insertions over 8 words.
    #expect(SpeechMetrics.wer(reference: "refer to my meal prep project on todoist", hypothesis: "refer to my meal prep project on to-do list") == 3.0 / 8)
    #expect(SpeechMetrics.wer(reference: "a b c", hypothesis: "a c") == 1.0 / 3)
    #expect(SpeechMetrics.wer(reference: "", hypothesis: "") == 0)
}

@Test func termRecallMatchesWordSequencesIgnoringCase() {
    #expect(SpeechMetrics.termRecall(["Meal Prep", "Todoist"], in: "refer to my meal prep on to-do list") == 0.5)
    #expect(SpeechMetrics.termRecall(["FluidAudio"], in: "the Fluid Audio PR") == 0)
    #expect(SpeechMetrics.termRecall(["FluidAudio"], in: "the FluidAudio PR.") == 1)
    #expect(SpeechMetrics.termRecall([], in: "anything") == nil)
}

@Test func speakCasesDefaultTranscriptToSpokenText() throws {
    let c = try BenchCase.load(jsonl: #"{"id":"s","kind":"dictation","speak":"Call Priya.","voice":"Daniel","rate":200}"#)[0]
    #expect(c.transcript == "Call Priya." && c.voice == "Daniel" && c.rate == 200 && c.hasAudio)
    #expect(throws: (any Error).self) { try BenchCase.load(jsonl: #"{"id":"x","kind":"dictation"}"#) }
}

@Test func boostChangesCountFixedAndBrokenReferenceWords() {
    let ref = "call priya about the launch"
    // Boosting fixed "priya" but broke "launch".
    let c = SpeechMetrics.boostChanges(reference: ref, raw: "call pria about the launch", boosted: "call priya about the lunch")
    #expect(c.fixed == 1)
    #expect(c.broken == 1)
    let none = SpeechMetrics.boostChanges(reference: ref, raw: "call pria about the launch", boosted: "call pria about the launch")
    #expect(none.fixed == 0 && none.broken == 0)
}

private func speechRun(raw: Double, boosted: Double, final: Double, recall: Double?, fixed: Int, broken: Int, asr: Double, passed: Bool = true) -> BenchRun {
    var r = BenchRun(output: "o", action: "insert", vocabOffer: nil, seconds: 0.5, failures: passed ? [] : ["bad"])
    r.speech = SpeechRun(raw: "r", boosted: "b", boostTerms: 2, asrSeconds: asr, rescoreSeconds: 0.1,
                         werRaw: raw, werBoosted: boosted, werFinal: final,
                         recallRaw: recall.map { $0 / 2 }, recallBoosted: recall, recallFinal: recall,
                         boostFixed: fixed, boostBroken: broken)
    return r
}

@Test func speechSummaryAveragesAndSeparatesFromLMRows() throws {
    let report = BenchReport(date: "d", provider: [:], cases: [
        BenchCaseResult(id: "d1", kind: .dictation, runs: [BenchRun(output: "o", action: "insert", vocabOffer: nil, seconds: 1, failures: [])]),
        BenchCaseResult(id: "s1", kind: .dictation, runs: [speechRun(raw: 0.4, boosted: 0.2, final: 0.1, recall: 1, fixed: 2, broken: 1, asr: 0.3)]),
        BenchCaseResult(id: "s2", kind: .dictation, runs: [speechRun(raw: 0, boosted: 0, final: 0.3, recall: nil, fixed: 0, broken: 1, asr: 0.1, passed: false)]),
    ])
    #expect(report.summaries().map(\.runs) == [1])  // LM-only rows exclude speech cases
    let s = try #require(report.speechSummary())
    #expect(s.runs == 2 && s.passed == 1)
    #expect(abs(s.werRaw - 0.2) < 1e-9 && abs(s.werBoosted - 0.1) < 1e-9 && abs(s.werFinal - 0.2) < 1e-9)
    #expect(s.recallRaw == 0.5 && s.recallBoosted == 1)  // runs without terms don't count
    #expect(s.boostFixed == 2 && s.boostBroken == 2)
    #expect(s.boostPrecision == 0.5)
    #expect(abs(s.asrMedian - 0.2) < 1e-9 && s.llmMedian == 0.5)
    #expect(report.table().contains("speech"))
}

@Test func compareReportsSpeechChanges() {
    func rep(_ boosted: String, wer: Double, model: String) -> BenchReport {
        var r = speechRun(raw: 0.2, boosted: wer, final: wer, recall: 1, fixed: 0, broken: 0, asr: 0.1)
        r.speech!.boosted = boosted
        return BenchReport(date: "d", provider: ["speechModel": model], cases: [BenchCaseResult(id: "s1", kind: .dictation, runs: [r])])
    }
    let lines = BenchReport.compare(rep("on to-do list", wer: 0.25, model: "v2"), rep("on Todoist", wer: 0, model: "v3"))
    #expect(lines.contains("warning: speechModel differs: v2 vs v3"))
    #expect(lines.contains("changed   s1 boosted: \"on to-do list\" → \"on Todoist\""))
    #expect(lines.contains("speech werBoosted 0.250 → 0.000"))
}
