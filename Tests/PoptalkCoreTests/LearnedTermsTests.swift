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
                       cleanupModel: "adapters/gemma-4-e2b-poptalk-v4", editModel: "adapters/gemma-4-e2b-poptalk-v4")
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
    #expect(learned.record(["Priya", "PopTalk"], at: t0) == 2)  // the list's size after
    #expect(learned.record(["priya", "Priya"], at: t0 + 60) == 2)  // once per call
    #expect(learned.record([], at: t0 + 60) == 2)
    #expect(LearnedTerms(url: url).terms(at: t0 + 120) == [LearnedTerm(text: "priya", lastUsed: t0 + 60, count: 2),
                                                           LearnedTerm(text: "PopTalk", lastUsed: t0, count: 1)])
    learned.forget(["PRIYA"])
    #expect(LearnedTerms(url: url).terms(at: t0 + 120).map(\.text) == ["PopTalk"])
    learned.forgetAll()
    #expect(LearnedTerms(url: url).terms(at: t0 + 120).isEmpty)
}

// #130: undoing a dictation, or typing over a term it wrote, forgets the term outright, learned before or not.
@Test func forgettingTermsRemovesThemCaseInsensitively() {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let learned = LearnedTerms(url: tempURL())
    learned.record(["Priya", "PopTalk", "Quillmate"], at: t0)
    #expect(learned.forget(["priya", "Yarrowly", "QUILLMATE"]) == 2)  // how many it removed
    #expect(learned.terms(at: t0 + 60).map(\.text) == ["PopTalk"])
    #expect(learned.forget([]) == 0)
}

// #130: what a dictation's boost and casing fix wrote, learning on or off, so undo and typed fixes can unlearn it.
@Test func screenTermsWrittenIgnoresTheLearningSetting() {
    let raw = RawInsert(request: Request(transcript: "ask Zorblat and PopTalk", selection: nil, context: ScreenSnapshot()),
                        rawTranscript: "ask sorblat and pop talk", boost: ["Zorblat", "PopTalk"], sources: ContextSources())
    let w = Pipeline.screenTermsWritten(raw, recased: ["Quix", "Gone"], inserted: "Ask Zorblat and PopTalk about Quix.",
                                        saved: ["poptalk"])
    #expect(w.boost == ["Zorblat"] && w.casing == ["Quix"])
    #expect(Pipeline.termsToLearn(raw, recased: ["Quix"], inserted: "Ask Zorblat about Quix.", saved: []) == nil)
}

@Test func learnedTermsExpireAfter30DaysAndKeepTheNewest200() {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let learned = LearnedTerms(url: tempURL())
    learned.record(["Old"], at: t0)
    #expect(learned.terms(at: t0 + 29 * day).map(\.text) == ["Old"])
    #expect(learned.terms(at: t0 + 31 * day).isEmpty)
    for i in 0..<210 { learned.record(["term\(i)"], at: t0 + Double(i)) }
    let kept = learned.terms(at: t0 + 300)
    #expect(kept.count == LearnedTerms.cap)
    #expect(kept.first?.text == "term209" && kept.last?.text == "term10")
    #expect(learned.vocabTerms(at: t0 + 300).first == VocabTerm(text: "term209"))
}

@Test func rememberScreenTermsIsOffByDefaultAndNeedsScreenBoosting() {
    let d = UserDefaults(suiteName: "poptalk-test-\(UUID())")!
    #expect(!ContextSources(d).rememberScreenTerms)
    d.set(true, forKey: ContextSources.Key.rememberScreenTerms)
    #expect(!ContextSources(d).rememberScreenTerms)  // screen vocabulary is off by default (#130)
    d.set(true, forKey: ContextSources.Key.screenVocabulary)
    #expect(ContextSources(d).rememberScreenTerms)
    d.set(false, forKey: ContextSources.Key.screenVocabulary)
    #expect(!ContextSources(d).rememberScreenTerms)
}

// #96: where the app's profile turns learning off, `learn()` gets nothing to record.
@Test func learningOffForTheAppRecordsNothing() {
    var on = ContextSources()
    on.learnScreenTerms = true
    let profiles = [AppProfile(bundleID: "com.example.mail", off: [.learnScreenTerms])]
    func learn(_ bundleID: String) -> [String]? {
        let sources = AppProfiles.resolve(bundleID: bundleID, domain: nil, isPrivate: false, profiles: profiles, defaults: on).sources
        let raw = RawInsert(request: Request(transcript: "ask Zorblat", selection: nil, context: ScreenSnapshot()),
                            rawTranscript: "ask sorblat", boost: ["Zorblat"], sources: sources)
        return Pipeline.termsToLearn(raw, recased: ["Quix"], inserted: "Ask Zorblat about Quix.", saved: []).map { $0.boost + $0.casing }
    }
    #expect(learn("com.example.notes") == ["Zorblat", "Quix"])
    #expect(learn("com.example.mail") == nil)
}
