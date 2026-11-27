import Foundation
import Testing
@testable import PoptalkCore

/// A local E2B fine-tune adapter (#101: no longer bundled), the kind of model the recaser is for.
private let fineTune = "adapters/gemma-4-e2b-poptalk-v4"

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

// #121: the matching itself, with the terms given (invented names): up to case and whitespace, whole words.
private func fix(_ t: String, _ terms: [String], screen: String = "") -> String { Pipeline.recaseTerms(t, terms: terms, screen: screen) }

@Test func recaseMatchesUpToCaseAndWhitespace() {
    #expect(fix("ping the fluid audio team", ["FluidAudio"]) == "ping the FluidAudio team")
    #expect(fix("the mealprep list", ["Meal Prep"]) == "the Meal Prep list")
    #expect(fix("ask ko rvan ta, or KOR  VANTA, or kor\nvanta", ["Korvanta"]) == "ask Korvanta, or Korvanta, or Korvanta")
    // Several terms and hits: a replacement that changes the length doesn't shift the next ones.
    #expect(fix("fluid audio, korvanta and fluidaudio", ["Korvanta", "FluidAudio"]) == "FluidAudio, Korvanta and FluidAudio")
    #expect(fix("did yarrowly freight renew? ask yarrowly", ["Yarrowly", "Yarrowly Freight"])
        == "did Yarrowly Freight renew? ask Yarrowly")
}

@Test func recaseMatchesWholeWordsOnly() {
    #expect(fix("korvantas, xkorvanta, 2korvanta, korvanta2, éclatkorvanta", ["Korvanta"])
        == "korvantas, xkorvanta, 2korvanta, korvanta2, éclatkorvanta")
    #expect(fix("korvanta's, korvanta-based, (korvanta)", ["Korvanta"]) == "Korvanta's, Korvanta-based, (Korvanta)")
    #expect(fix("korvanta", ["Korvanta"]) == "Korvanta")
    #expect(fix("fluid audiophile", ["FluidAudio"]) == "fluid audiophile")
}

@Test func recaseSkipsATermTheScreenSpellsTwoWays() {
    #expect(fix("ask korvanta", ["Korvanta"], screen: "Korvanta notes. KORVANTA 2") == "ask korvanta")
    #expect(fix("ask korvanta", ["Korvanta"], screen: "Korvanta notes. Kor vanta 2") == "ask korvanta")
    // Whitespace runs count as one space: one spelling.
    #expect(fix("ask korvanta", ["Kor Vanta"], screen: "Kor Vanta notes. Kor\n  Vanta 2") == "ask Kor Vanta")
    // On screen only: nothing to do. In the transcript only (saved or learned): recased.
    #expect(fix("ask them", ["Korvanta"], screen: "Korvanta notes") == "ask them")
    #expect(fix("ask korvanta", ["Korvanta"], screen: "nothing here") == "ask Korvanta")
}

@Test func recaseHandlesUnicode() {
    #expect(fix("ask jÜRGEN and ÅSVIK", ["Jürgen", "Åsvik"]) == "ask Jürgen and Åsvik")
    // "İ" lowercases to two code points, so offsets after it differ between the original and its lowercase form.
    #expect(fix("İSTANBUL Ölçek and korvanta", ["Korvanta"]) == "İSTANBUL Ölçek and Korvanta")
    #expect(fix("İZMIRLY and izmirly", ["İzmirly"]) == "İzmirly and izmirly")
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
                         vocabulary: store, cleanupModel: fineTune, editModel: fineTune,
                         features: DictationFeatures(d, environment: [:]))
        _ = await p.run(Request(transcript: t, selection: nil, context: screen))
        return (seen.prompt, seen.calls)
    }
    let said = "ship poptalk to meal prep."
    #expect(await dictate(said).prompt.contains("<transcript>ship PopTalk to Meal Prep.</transcript>"))
    // #130: screen terms still recase with screen boosting off (the default); not with the screen unread.
    #expect(!ContextSources(d).screenVocabulary)
    for k in [ContextSources.Key.focusedText, ContextSources.Key.nearbyText, ContextSources.Key.ocr, ContextSources.Key.windowTitle] {
        d.set(false, forKey: k)
    }
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

// Gated per model: E4B fixes screen terms itself and regressed when they were pre-fixed (#75). E2B fine-tunes, now
// only local adapter folders (#101), keep it.
@Test func recaseIsOnForE2BAdaptersOnly() async {
    final class Seen: @unchecked Sendable { var prompt = "" }
    for (model, recased) in [(fineTune, true), ("/Users/me/out/gemma-4-e2b-poptalk-v5", true), (ModelSettings.e4b, false)] {
        let seen = Seen()
        let p = Pipeline(complete: { _, m, _, _ in seen.prompt = m.last!.content; return "ok" },
                         vocabulary: VocabularyStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
                         cleanupModel: model, editModel: model)
        _ = await p.run(Request(transcript: "refer to my meal prep project", selection: nil, context: ScreenSnapshot(text: todoist)))
        #expect(seen.prompt.contains("<transcript>refer to my Meal Prep project</transcript>") == recased, "\(model)")
    }
}

// #75 step 2: a shortlisted sound-alike run becomes the screen term when the yes/no check scores it at or above
// `termScoreThreshold`; off by default. Invented names.
@Test func soundAlikeTermsNeedTheFlagAndAYes() async {
    final class Seen: @unchecked Sendable { var prompt = ""; var asked: [String] = [] }
    let screen = ScreenSnapshot(text: "Paavo Toivonen: the Corvelle build is out")
    func dictate(_ on: Bool, score: Double) async -> Seen {
        let seen = Seen()
        var f = DictationFeatures()
        f.soundAlikeTerms = on
        var p = Pipeline(complete: { _, m, _, _ in seen.prompt = m.last!.content; return "Ok." },
                         vocabulary: VocabularyStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
                         cleanupModel: fineTune, editModel: fineTune, features: f)
        p.termScore = { _, heard, term in seen.asked.append("\(heard)=\(term)"); return score }
        _ = await p.run(Request(transcript: "ask toy vonen about the core vell build.", selection: nil, context: screen))
        return seen
    }
    let yes = await dictate(true, score: Pipeline.termScoreThreshold)
    #expect(yes.prompt.contains("<transcript>ask Toivonen about the Corvelle build.</transcript>"))
    #expect(Set(yes.asked) == ["toy vonen=Toivonen", "core vell=Corvelle"])
    let no = await dictate(true, score: Pipeline.termScoreThreshold - 1)
    #expect(no.prompt.contains("<transcript>ask toy vonen about the core vell build.</transcript>"))
    let off = await dictate(false, score: 0)
    #expect(off.asked.isEmpty && off.prompt.contains("toy vonen"))
}
