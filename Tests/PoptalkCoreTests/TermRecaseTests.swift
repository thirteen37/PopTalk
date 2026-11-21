import Foundation
import Testing
@testable import PoptalkCore

// #75: on-screen terms recased in the transcript before the LLM, up to case and spacing.
private func recase(_ t: String, screen: String, saved: [String] = []) -> String {
    let terms = Pipeline.boostTerms(saved: saved.map { VocabTerm(text: $0) }, context: ScreenSnapshot(text: screen)).map(\.text)
    return Pipeline.recaseTerms(t, terms: terms, screen: screen)
}

private let todoist = "Todoist — Projects: Inbox, Meal Prep, Work. Today: Buy oat milk, Call Priya re: Q3 OKRs"

@Test func recasesScreenTermsUpToCaseAndSpacing() {
    #expect(recase("refer to my meal prep project on todoist", screen: todoist) == "refer to my Meal Prep project on Todoist")
    #expect(recase("I will ping Marcus about the fluid audio release.", screen: "Priya Raman: can someone review the PR for FluidAudio?")
        == "I will ping Marcus about the FluidAudio release.")
    #expect(recase("I uploaded the build to test flight.", screen: "App Store Connect — TestFlight: build 42") == "I uploaded the build to TestFlight.")
    #expect(recase("the email should say quill mate everywhere", screen: "Quillmate notes. We went over it.")
        == "the email should say Quillmate everywhere")
    #expect(recase("Switch to GPT-4o before Friday.", screen: "moving the summarizer to gpt-4o next sprint") == "Switch to gpt-4o before Friday.")
    // A phrase loses only its leading common words ("Call"); its names also count alone.
    #expect(recase("did yarrowly freight renew? ask yarrowly", screen: "Tags: Yarrowly Freight, backlog")
        == "did Yarrowly Freight renew? ask Yarrowly")
    // Terms of 5+ letters join any pieces; shorter ones only single letters.
    #expect(recase("keep rabbit m q and auth 0, drop d b t", screen: "Re: RabbitMQ, Auth0 and DBT")
        == "keep RabbitMQ and Auth0, drop DBT")
    // Saved vocabulary too, with no screen.
    #expect(recase("ask about poptalk", screen: "", saved: ["PopTalk"]) == "ask about PopTalk")
}

// Precision: without labels, a wrong recase is worse than none.
@Test func recaseLeavesCommonWordsAndPartialWords() {
    // Title Case UI labels that are plain words.
    #expect(recase("today I work from my inbox", screen: todoist) == "today I work from my inbox")
    // Whole words only.
    #expect(recase("the poptalks and priyanka", screen: "PopTalk, Priya") == "the poptalks and priyanka")
    // A phrase of a common word and a name: only the name.
    #expect(recase("I will call priya about it", screen: todoist) == "I will call Priya about it")
    // A lowercase hyphenated word on screen is still a common word.
    #expect(recase("Follow-up tomorrow.", screen: "the follow-up is due") == "Follow-up tomorrow.")
    // Short pieces don't join into a name ("an a" → "Ana").
    #expect(recase("he got an a grade", screen: "Ask Ana Lima") == "he got an a grade")
}

@Test func recaseSkipsTermsShownInSeveralCasings() {
    #expect(recase("ship poptalk today", screen: "PopTalk release notes. Poptalk 1.2") == "ship poptalk today")
    #expect(recase("start the meal prep", screen: "Meal Prep. I need to meal prep tonight") == "start the meal prep")
}

// Settings, read per press: each request's pipeline gets `DictationFeatures(defaults)` as the app builds it.
@Test func dictationFeaturesFollowSettingsPerRequest() async {
    final class Seen: @unchecked Sendable { var prompt = ""; var calls = 0 }
    let d = UserDefaults(suiteName: "poptalk-test-\(UUID())")!
    let store = VocabularyStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    try? store.add(VocabTerm(text: "PopTalk"))
    let screen = ScreenSnapshot(text: "Todoist — Projects: Inbox, Meal Prep, Work.")
    func dictate(_ t: String) async -> (prompt: String, calls: Int) {
        let seen = Seen()
        let p = Pipeline(complete: { _, m, _, _ in seen.calls += 1; seen.prompt = m.last!.content; return "Ok." },
                         vocabulary: store, cleanupModel: ModelSettings.fineTune, editModel: ModelSettings.fineTune,
                         features: DictationFeatures(d, environment: [:]))
        _ = await p.run(Request(transcript: t, selection: nil, context: screen))
        return (seen.prompt, seen.calls)
    }
    let said = "ship poptalk to meal prep."
    #expect(await dictate(said).prompt.contains("<transcript>ship PopTalk to Meal Prep.</transcript>"))
    d.set(false, forKey: ContextSources.Key.screenVocabulary)  // screen terms off: saved vocabulary only
    #expect(await dictate(said).prompt.contains("<transcript>ship PopTalk to meal prep.</transcript>"))
    d.set(false, forKey: DictationFeatures.Key.recaseTerms)  // recasing off: untouched
    #expect(await dictate(said).prompt.contains("<transcript>ship poptalk to meal prep.</transcript>"))
    // Gate off by default: the model is always called; on, a clean dictation skips it.
    #expect(await dictate("Can you send me the report by Friday?").calls == 1)
    d.set(true, forKey: DictationFeatures.Key.skipGate)
    #expect(await dictate("Can you send me the report by Friday?").calls == 0)
    #expect(DictationFeatures(d, environment: ["POPTALK_SKIP_LLM": "0"]).skipGate == false)
    #expect(DictationFeatures(UserDefaults(suiteName: "poptalk-test-\(UUID())")!, environment: ["POPTALK_SKIP_LLM": "1"]).skipGate)
}

// Gated per model: E4B fixes screen terms itself and regressed when they were pre-fixed (#75).
@Test func recaseIsOnForE2BAdaptersOnly() async {
    final class Seen: @unchecked Sendable { var prompt = "" }
    for (model, recased) in [(ModelSettings.fineTune, true), (ModelSettings.fineTuneV2, true), (ModelSettings.e4b, false)] {
        let seen = Seen()
        let p = Pipeline(complete: { _, m, _, _ in seen.prompt = m.last!.content; return "ok" },
                         vocabulary: VocabularyStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
                         cleanupModel: model, editModel: model)
        _ = await p.run(Request(transcript: "refer to my meal prep project", selection: nil, context: ScreenSnapshot(text: todoist)))
        #expect(seen.prompt.contains("<transcript>refer to my Meal Prep project</transcript>") == recased, "\(model)")
    }
}
