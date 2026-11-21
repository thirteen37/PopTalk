import Foundation
import Testing
@testable import PoptalkCore

private func one(_ json: String) throws -> BenchCase { try BenchCase.load(jsonl: json)[0] }

@Test func loadsJSONLSkippingBlankLinesAndKeepsNullVocabOffer() throws {
    let cases = try BenchCase.load(jsonl: """
        {"id":"a","kind":"dictation","transcript":"hi","context":"Todoist"}

        {"id":"b","kind":"edit","transcript":"fix","selection":"x","expectVocabOffer":null,"audio":"bench/audio/b.wav"}
        """)
    #expect(cases.map(\.id) == ["a", "b"])
    #expect(cases[0].request.context.text == "Todoist")
    #expect(cases[0].expectVocabOffer == nil)  // absent: not checked
    #expect(cases[1].expectVocabOffer == .some(nil))  // null: must not offer
    #expect(cases[1].request.selection == "x")
}

@Test func badLineReportsItsNumber() {
    #expect(throws: (any Error).self) { try BenchCase.load(jsonl: "{\"id\":\"a\",\"kind\":\"dictation\",\"transcript\":\"x\"}\n{oops") }
    do { _ = try BenchCase.load(jsonl: "\n{oops") } catch { #expect("\(error)".contains("line 2")) }
}

@Test func passingDictation() throws {
    let c = try one(#"{"id":"fri","kind":"dictation","transcript":"send it by friday","mustContain":["Friday"],"mustNotContain":["thursday"],"maxLengthRatio":2}"#)
    let run = c.score(PipelineResult(outcome: .insert("Send it by Friday.", label: "Dictated")), seconds: 0.5)
    #expect(run.failures == [])
    #expect(run.action == "insert")
    #expect(run.output == "Send it by Friday.")
    #expect(run.seconds == 0.5)
}

@Test func mustContainIsCaseSensitiveMustNotContainIsNot() throws {
    let c = try one(#"{"id":"x","kind":"dictation","transcript":"meal prep","mustContain":["Meal Prep"],"mustNotContain":["thursday"]}"#)
    let run = c.score(PipelineResult(outcome: .insert("meal prep, Thursday", label: "Dictated")), seconds: 1)
    #expect(run.failures == ["missing \"Meal Prep\"", "contains \"thursday\""])
}

@Test func rawFallbackAndErrorFail() throws {
    let c = try one(#"{"id":"x","kind":"dictation","transcript":"hello"}"#)
    #expect(c.score(PipelineResult(outcome: .insert("hello", label: "Dictated (raw)")), seconds: 3).failures == ["raw fallback"])
    let e = c.score(PipelineResult(outcome: .error("Couldn't reach the language model")), seconds: 1)
    #expect(e.action == "error")
    #expect(e.failures == ["error: Couldn't reach the language model"])
}

@Test func editChecks() throws {
    let c = try one(#"{"id":"t","kind":"edit","transcript":"Quarterly Review","selection":"Q3 Notes","expectAction":"replace","expectExact":"Quarterly Review","expectVocabOffer":null}"#)
    #expect(c.score(PipelineResult(outcome: .replaceSelection("Quarterly Review", label: "Replaced")), seconds: 1).failures == [])
    let bad = c.score(PipelineResult(outcome: .insertAfter("Quarterly Review."), vocabularyOffer: VocabTerm(text: "Quarterly")), seconds: 1)
    #expect(bad.action == "insertAfter")
    #expect(bad.vocabOffer == "Quarterly")
    #expect(bad.failures == ["action insertAfter, expected replace", "not exactly \"Quarterly Review\"", "offered \"Quarterly\", expected none"])
}

@Test func anyOfVocabOfferAndLengthRatio() throws {
    let c = try one(#"{"id":"v","kind":"edit","transcript":"T-O-D-O-I-S-T","selection":"todo list","expectAnyOf":["Todoist","Todoist."],"expectVocabOffer":"Todoist","maxLengthRatio":1.5}"#)
    #expect(c.score(PipelineResult(outcome: .replaceSelection("Todoist", label: "Corrected"), remembered: VocabTerm(text: "Todoist")), seconds: 1).failures == [])
    let bad = c.score(PipelineResult(outcome: .replaceSelection("Sure! Here is the corrected text: Todoist", label: "Corrected")), seconds: 1)
    #expect(bad.action == "correct")
    #expect(bad.failures == ["not any of [\"Todoist\", \"Todoist.\"]", "no vocabulary offer, expected \"Todoist\"", "length 41 > 1.5 × 9"])
}

private func report(_ runs: [String: [Bool]], variant: String = "AFM 3 Core Advanced") -> BenchReport {
    BenchReport(date: "2026-11-19", provider: ["provider": "apple", "variant": variant], cases: runs.keys.sorted().map { id in
        BenchCaseResult(id: id, kind: id.hasPrefix("d") ? .dictation : .edit, runs: runs[id]!.enumerated().map { i, ok in
            BenchRun(output: "o", action: "insert", vocabOffer: nil, seconds: Double(i + 1), failures: ok ? [] : ["bad"])
        })
    })
}

@Test func summaryPerKind() {
    let s = report(["d1": [true, false, true], "d2": [true], "e1": [false]]).summaries()
    #expect(s.map(\.kind) == [.dictation, .edit])
    #expect(s[0].runs == 4)
    #expect(s[0].passed == 3)
    #expect(s[0].median == 1.5)
    #expect(s[0].p90 == 3)
    #expect(s[0].max == 3)
    #expect(s[1].passed == 0)
}

@Test func compareFlagsRegressionsAndVariantMismatch() {
    let lines = BenchReport.compare(report(["d1": [true, true], "e1": [false, false], "e2": [true]]),
                                    report(["d1": [true, false], "e1": [true, true], "e3": [true]], variant: "AFM 3 Core"))
    #expect(lines.contains("warning: variant differs: AFM 3 Core Advanced vs AFM 3 Core"))
    #expect(lines.contains("regressed d1: 2/2 → 1/2"))
    #expect(lines.contains("improved  e1: 0/2 → 2/2"))
    #expect(lines.contains("only in a: e2"))
    #expect(lines.contains("only in b: e3"))
}

// replace / correct / edit all replace the selection; only the overlay label differs.
@Test func replaceFamilyActionsAreEquivalent() throws {
    let c = try one(#"{"id":"t","kind":"edit","transcript":"make it shorter","selection":"long text","expectAction":"edit"}"#)
    let r = c.score(PipelineResult(outcome: .replaceSelection("short", label: "Replaced")), seconds: 0.1)
    #expect(r.failures.isEmpty)
    let ins = c.score(PipelineResult(outcome: .insertAfter(" more")), seconds: 0.1)
    #expect(!ins.failures.isEmpty)
}

// #54: score the model's raw action separately from the guarded outcome.
@Test func scoresModelActionAndGuardOverride() throws {
    let c = try one(#"{"id":"t","kind":"edit","transcript":"Debounce period.","selection":"time limit","expectAction":"replace"}"#)
    let overridden = c.score(PipelineResult(outcome: .replaceSelection("Debounce period.", label: "Replaced"), modelAction: "insertAfter"), seconds: 1)
    #expect(overridden.passed)
    #expect(overridden.modelAction == "insertAfter")
    #expect(overridden.modelActionOK == false)
    #expect(overridden.overridden)
    let fine = c.score(PipelineResult(outcome: .replaceSelection("x", label: "Edited"), modelAction: "correct"), seconds: 1)
    #expect(fine.modelActionOK == true)
    #expect(!fine.overridden)
    // No model call (literally, fast path): nothing to score.
    let none = c.score(PipelineResult(outcome: .replaceSelection("x", label: "Replaced")), seconds: 1)
    #expect(none.modelActionOK == nil)
    #expect(!none.overridden)
    // No expectAction: overrides still count, accuracy doesn't.
    let free = try one(#"{"id":"u","kind":"edit","transcript":"x","selection":"y"}"#)
        .score(PipelineResult(outcome: .nothing, modelAction: "replace"), seconds: 1)
    #expect(free.modelActionOK == nil)
    #expect(free.overridden)
}

private func editReport(_ runs: [(String?, String, Bool?)]) -> BenchReport {
    BenchReport(date: "d", provider: [:], cases: [BenchCaseResult(id: "e1", kind: .edit, runs: runs.map { m, a, ok in
        var r = BenchRun(output: "o", action: a, vocabOffer: nil, seconds: 1, failures: [])
        r.modelAction = m
        r.modelActionOK = ok
        return r
    })])
}

@Test func summaryCountsModelActionAndOverrides() {
    let r = editReport([("insertAfter", "replace", false), ("replace", "replace", true), (nil, "replace", nil), ("edit", "correct", true)])
    let s = r.summaries()[0]
    #expect(s.modelActionRuns == 3)
    #expect(s.modelActionPassed == 2)
    #expect(s.overrides == 1)
    print(r.table())
    #expect(r.table().contains("  2/3 "))
}

@Test func compareShowsModelActionAndOverrides() {
    let a = editReport([("insertAfter", "replace", false), ("replace", "replace", true)])
    let b = editReport([("replace", "replace", true), ("replace", "replace", true)])
    let lines = BenchReport.compare(a, b)
    #expect(lines.contains("edit model action 1/2 → 2/2"))
    #expect(lines.contains("edit guard overrides 1 → 0"))
}

@Test func oldResultsWithoutModelActionDecode() throws {
    let json = #"{"date":"d","provider":{},"cases":[{"id":"e","kind":"edit","runs":[{"output":"o","action":"replace","seconds":1,"failures":[]}]}]}"#
    let r = try JSONDecoder().decode(BenchReport.self, from: Data(json.utf8))
    #expect(r.cases[0].runs[0].modelAction == nil)
    #expect(r.summaries()[0].modelActionRuns == 0)
}

@Test func oracleRecaseFixesOnScreenTermsOnly() throws {
    let c = try one(#"{"id":"x","kind":"dictation","transcript":"t","context":"Projects: Meal Prep. Docs: CloudFront","mustContain":["Meal Prep","CloudFront","Todoist"]}"#)
    #expect(c.oracleRecase("refer to my meal  prep project, restart cloud front, open todoist")
        == "refer to my Meal Prep project, restart CloudFront, open todoist")  // Todoist isn't on screen
    #expect(c.oracleRecase("mealprepper") == "mealprepper")  // whole words only
}
