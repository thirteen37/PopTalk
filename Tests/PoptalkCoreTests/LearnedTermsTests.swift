import Foundation
import Testing
@testable import PoptalkCore

// #87: screen terms that changed a dictation, remembered (opt-in) to boost and recase later presses.
private func tempURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("learned-terms.json")
}

private let day: TimeInterval = 86_400

@Test func termsWrittenAreTheOnesTheTextGainedExceptSaved() {
    let terms = ["Priya", "PopTalk", "Kubernetes", "Todoist", "Q3 OKRs"]
    #expect(Pipeline.termsWritten(from: "call pria about pop talk and todo list, Kubernetes too",
                                  to: "call Priya about PopTalk and Todoist, Kubernetes too",
                                  terms: terms, saved: ["todoist"]) == ["Priya", "PopTalk"])
    #expect(Pipeline.termsWritten(from: "PopTalk and pop talk", to: "PopTalk and PopTalk", terms: terms, saved: []) == ["PopTalk"])
    #expect(Pipeline.termsWritten(from: "about the Q3OKRs", to: "about the Q3 OKRs", terms: terms, saved: []) == ["Q3 OKRs"])
    #expect(Pipeline.termsWritten(from: "PopTalkers", to: "PopTalkers", terms: terms, saved: []).isEmpty)
}

@Test func pipelineReportsScreenAndLearnedTermsItRecased() async {
    let store = VocabularyStore(url: tempURL())
    try? store.add(VocabTerm(text: "PopTalk"))
    func run(_ t: String, screen: String, learned: [VocabTerm] = []) async -> PipelineResult {
        await Pipeline(complete: { _, _, _, _ in "Ok." }, vocabulary: store, learned: learned,
                       cleanupModel: ModelSettings.fineTune, editModel: ModelSettings.fineTune)
            .run(Request(transcript: t, selection: nil, context: ScreenSnapshot(text: screen)))
    }
    #expect(await run("ship poptalk to meal prep.", screen: "Projects: Inbox, Meal Prep, Work.").recased == ["Meal Prep"])
    #expect(await run("ship it to meal prep.", screen: "").recased.isEmpty)
    #expect(await run("ship it to meal prep.", screen: "", learned: [VocabTerm(text: "Meal Prep")]).recased == ["Meal Prep"])
    // Saved vocabulary wins over a learned duplicate, and a learned term boosts like saved ones.
    let boost = Pipeline.boostTerms(saved: store.terms, learned: [VocabTerm(text: "poptalk"), VocabTerm(text: "Quillmate")],
                                    context: ScreenSnapshot(), fromScreen: false).map(\.text)
    #expect(boost == ["PopTalk", "Quillmate"])
}

@Test func boostSourcesSplitsTheBoostBySavedLearnedAndScreen() {
    let saved = [VocabTerm(text: "PopTalk")], learned = [VocabTerm(text: "poptalk"), VocabTerm(text: "Quillmate")]
    let boost = Pipeline.boostTerms(saved: saved, learned: learned, context: ScreenSnapshot(text: "Ask Priya Raman about Kubernetes."))
    let split = Pipeline.boostSources(boost, saved: saved, learned: learned)
    #expect(split.saved == 1 && split.learned == 1 && split.screen == boost.count - 2 && split.screen > 0)
}

@Test func learnedTermsCountPersistAndMergeCaseInsensitively() {
    let url = tempURL(), t0 = Date(timeIntervalSince1970: 1_000_000)
    let learned = LearnedTerms(url: url)
    #expect(learned.record(["Priya", "PopTalk"], request: UUID(), at: t0) == 2)  // the list's size after
    #expect(learned.record(["priya", "Priya"], request: UUID(), at: t0 + 60) == 2)  // once per request
    #expect(learned.record([], request: UUID(), at: t0 + 60) == 2)
    #expect(LearnedTerms(url: url).terms(at: t0 + 120) == [LearnedTerm(text: "priya", lastUsed: t0 + 60, count: 2),
                                                           LearnedTerm(text: "PopTalk", lastUsed: t0, count: 1)])
    learned.forget("PRIYA")
    #expect(LearnedTerms(url: url).terms(at: t0 + 120).map(\.text) == ["PopTalk"])
    learned.forgetAll()
    #expect(LearnedTerms(url: url).terms(at: t0 + 120).isEmpty)
}

@Test func forgettingARequestPutsBackWhatItChanged() {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let learned = LearnedTerms(url: tempURL())
    let first = UUID(), second = UUID()
    learned.record(["Priya"], request: first, at: t0)
    learned.record(["Priya", "PopTalk"], request: second, at: t0 + 60)
    #expect(learned.forget(request: first) == 0)  // not the latest: nothing to undo
    #expect(learned.forget(request: second) == 2)  // the terms it put back or dropped
    #expect(learned.terms(at: t0 + 120) == [LearnedTerm(text: "Priya", lastUsed: t0, count: 1)])
    #expect(learned.forget(request: second) == 0)  // once only
    #expect(learned.terms(at: t0 + 120).count == 1)
}

@Test func learnedTermsExpireAfter30DaysAndKeepTheNewest200() {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let learned = LearnedTerms(url: tempURL())
    learned.record(["Old"], request: UUID(), at: t0)
    #expect(learned.terms(at: t0 + 29 * day).map(\.text) == ["Old"])
    #expect(learned.terms(at: t0 + 31 * day).isEmpty)
    for i in 0..<210 { learned.record(["term\(i)"], request: UUID(), at: t0 + Double(i)) }
    let kept = learned.terms(at: t0 + 300)
    #expect(kept.count == LearnedTerms.cap)
    #expect(kept.first?.text == "term209" && kept.last?.text == "term10")
    #expect(learned.vocabTerms(at: t0 + 300).first == VocabTerm(text: "term209"))
}

@Test func rememberScreenTermsIsOffByDefaultAndNeedsScreenBoosting() {
    let d = UserDefaults(suiteName: "poptalk-test-\(UUID())")!
    #expect(!ContextSources(d).rememberScreenTerms)
    d.set(true, forKey: ContextSources.Key.rememberScreenTerms)
    #expect(ContextSources(d).rememberScreenTerms)
    d.set(false, forKey: ContextSources.Key.screenVocabulary)
    #expect(!ContextSources(d).rememberScreenTerms)
}
