import Foundation
import Testing
@testable import PoptalkCore

// #75: a clean, Parakeet-cased dictation skips the cleanup model (prototype, off by default).
private func skips(_ said: String, screen: String = "") -> Bool {
    let terms = Pipeline.recaseCandidates(Pipeline.boostTerms(saved: [], context: ScreenSnapshot(text: screen)).map(\.text))
    return Pipeline.skipsLLM(said: said, transcript: Pipeline.dictationPrepass(Pipeline.stripHesitations(said)), terms: terms)
}

@Test func cleanCasedDictationSkips() {
    #expect(skips("I uploaded the new build to TestFlight this morning.", screen: "App Store Connect — TestFlight: build 42"))
    #expect(skips("Refer to my Meal Prep project on Todoist.", screen: "Todoist — Projects: Inbox, Meal Prep, Work."))
    #expect(skips("Can you send me the report by Friday?"))
    #expect(skips("Ask Mahina about it.", screen: "Mahina: the deploy is done"))
    // The pre-pass already did the formatting.
    #expect(skips("The error says, quote, permission denied, end quote. New paragraph. Thanks."))
}

@Test func fillersAndCorrectionsNeedTheModel() {
    for said in ["So, like, we need to ship this.", "Um, send it today.", "Let's meet Tuesday, no, Thursday.",
                 "Book it for four, actually make it six.", "Send it to Bob. Scratch that.", "I mean, it works.",
                 "You know, it's fine.", "It's basically done.", "Two PM, sorry, four PM.", "Use the the blue one.",
                 "Make that three.", "Call Ana, or rather Bea."] {
        #expect(!skips(said), "\(said)")
    }
}

@Test func uncasedOrCommandsNeedTheModel() {
    for said in ["send it today.", "Send it today", "Buy milk, bullet eggs, bullet bread.", "Email john at example dot com.",
                 "My name is C A S E Y.", "First, milk. Second, eggs.", "Put a question mark there."] {
        #expect(!skips(said), "\(said)")
    }
}

// A word close to a screen name but not it: the model may fix it.
@Test func nearMissScreenTermNeedsTheModel() {
    #expect(!skips("Ask Maheena about it.", screen: "Mahina: the deploy is done"))
    #expect(!skips("Ping Paavo when the Toy Vonen build lands.", screen: "Paavo Toivonen joined the channel"))
}

@Test func skipGateBypassesTheModel() async {
    final class Calls: @unchecked Sendable { var n = 0 }
    for gate in [true, false] {
        let calls = Calls()
        let p = Pipeline(complete: { _, _, _, _ in calls.n += 1; return "Can you send me the report by Friday?" },
                         vocabulary: VocabularyStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
                         cleanupModel: "s", editModel: "b", features: { var f = DictationFeatures(); f.skipGate = gate; return f }())
        let r = await p.run(Request(transcript: "Can you send me the report by Friday?", selection: nil, context: ScreenSnapshot()))
        #expect(r.outcome == .insert("Can you send me the report by Friday?", label: "Dictated"))
        #expect(r.skippedLLM == gate)
        #expect(calls.n == (gate ? 0 : 1))
    }
}
