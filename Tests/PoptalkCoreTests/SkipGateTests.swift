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

// #122: the check that stops the gate first, for replay counts; nil when it skips.
@Test func skipGateStopNamesTheFirstCheck() {
    func stop(_ said: String, _ terms: [String] = []) -> String? {
        Pipeline.skipGateStop(said: said, transcript: said, terms: terms)
    }
    #expect(stop("Can you send me the report by Friday?") == nil)
    #expect(stop("send it today.") == "casing")
    #expect(stop("Send it today") == "punctuation")
    #expect(stop("So, like, we need to ship this.") == "cue")
    #expect(stop("Buy milk, bullet eggs.") == "command")
    #expect(stop("Ask Maheena about it.", ["Mahina"]) == "term")
    for s in ["send it today.", "Send it today", "Ask Maheena about it.", "Can you send me the report by Friday?"] {
        #expect(Pipeline.skipsLLM(said: s, transcript: s, terms: ["Mahina"]) == (stop(s, ["Mahina"]) == nil))
    }
}

@Test func skipGateRecordsItsStopAndTime() async {
    for (gate, said) in [(true, "Can you send me the report by Friday?"), (true, "send it today."), (false, "Send it.")] {
        let p = Pipeline(complete: { _, _, _, _ in said },
                         vocabulary: VocabularyStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
                         cleanupModel: "s", editModel: "b", features: { var f = DictationFeatures(); f.skipGate = gate; return f }())
        let r = await p.run(Request(transcript: said, selection: nil, context: ScreenSnapshot()))
        #expect((r.skipGateSeconds != nil) == gate)
        #expect(r.skipGateStop == (gate && !r.skippedLLM ? "casing" : nil))
    }
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

// PoptalkBench --gate-eval: the gate on a history record, and how a reply differs from the transcript.
@Test func gateEvalGatesAndClassifies() {
    #expect(GateEval.gate(said: "Can you send me the report by Friday?", boost: [], screen: "", model: "m").skips)
    let g = GateEval.gate(said: "Ask maheena about it.", boost: ["Mahina"], screen: "Mahina", model: "m")
    #expect(!g.skips && g.transcript == "Ask maheena about it.")
    let c = { (r: String) in GateEval.change(from: "So we ship it on Friday.", to: r, terms: ["Meal Prep", "FluidAudio"]) }
    #expect(c("So we ship it on Friday.") == .same)
    #expect(c(" So we ship it on Friday. ") == .trimmed)
    #expect(c("so we ship it on friday.") == .casing)
    #expect(c("So, we ship it on Friday!") == .punctuation)
    #expect(c("so, we ship it on friday") == .casingAndPunctuation)
    #expect(c("So we ship it.\nOn Friday.") == .formatting)
    #expect(c("So we ship FluidAudio on Friday.") == .term)
    #expect(c("We ship it on Friday.") == .removed)
    #expect(c("So we ship it on Friday morning.") == .added)
    #expect(c("So we send it on Friday.") == .replaced)
    #expect(GateEval.change(from: "Open meal prep.", to: "Open Meal Prep.", terms: ["Meal Prep"]) == .term)
}

// #75 step 2: runs of 1–3 words that may be a misheard term, for the yes/no term check. Invented names.
@Test func shortlistFindsSoundAlikeRuns() {
    let s = "Ping toy vonen about the core vell build."
    let c = Pipeline.termShortlist(s, terms: ["Toivonen", "Corvelle"])
    #expect(c.contains { $0.heard == "toy vonen" && $0.term == "Toivonen" })
    #expect(c.contains { $0.heard == "core vell" && $0.term == "Corvelle" })
    #expect(c.allSatisfy { (s as NSString).substring(with: $0.range) == $0.heard })
}

@Test func shortlistFoldsSpellingsThatSoundAlike() {
    // x heard as "ks": edit distance alone puts these under 0.75.
    #expect(Pipeline.termShortlist("Open grav links now.", terms: ["Gravlynx"]).map(\.heard) == ["grav links"])
    #expect(Pipeline.termShortlist("Ask pel tricks.", terms: ["Peltrix"]).map(\.heard) == ["pel tricks"])
    // Overlapping runs that sound alike equally: the closer spelling.
    #expect(Pipeline.termShortlist("Ask kas ia now.", terms: ["Kasia"]).map(\.heard) == ["kas ia"])
}

@Test func shortlistSkipsExactAndUnrelated() {
    #expect(Pipeline.termShortlist("Ask Mahina about the Corvelle build.", terms: ["Mahina", "Corvelle"]).isEmpty)
    #expect(Pipeline.termShortlist("Can you send me the report by Friday?", terms: ["Korvanta", "Brisolt"]).isEmpty)
    // A multi-word term's names count alone; terms under 4 letters are left out.
    #expect(Pipeline.termShortlist("Tell toy vonen.", terms: ["Paavo Toivonen"]).map(\.term) == ["Toivonen"])
    #expect(Pipeline.termShortlist("Tell Bo.", terms: ["Boa"]).isEmpty)
}
