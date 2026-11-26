import Foundation
import Testing
@testable import PoptalkCore

private final class Calls: @unchecked Sendable { var models: [String] = []; var json: [Bool] = []; var timeouts: [TimeInterval] = [] }
private struct Boom: Error {}

private func pipeline(reply: String? = nil, store: VocabularyStore = VocabularyStore(url: tmp()),
                      calls: Calls = Calls()) -> Pipeline {
    Pipeline(complete: { model, _, json, timeout in
        calls.models.append(model); calls.json.append(json); calls.timeouts.append(timeout)
        guard let reply else { throw Boom() }
        return reply
    }, vocabulary: store, cleanupModel: "small", editModel: "big")
}

private func tmp() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
}

private func req(_ t: String, selection: String? = nil) -> Request {
    Request(transcript: t, selection: selection, context: ScreenSnapshot())
}

@Test func emptyTranscriptDoesNothing() async {
    let calls = Calls()
    let r = await pipeline(reply: "x", calls: calls).run(req("  \n"))
    #expect(r.outcome == .nothing)
    #expect(calls.models.isEmpty)
}

@Test func dictationUsesCleanupModel() async {
    let calls = Calls()
    let r = await pipeline(reply: "Hello there.", calls: calls).run(req("hello there"))
    #expect(r.outcome == .insert("Hello there.", label: "Dictated"))
    #expect(calls.models == ["small"])
    #expect(calls.json == [false])
}

// #67: an S1-mini cleanup model gets its own prompt; edits keep the edit prompt.
@Test func s1MiniCleanupGetsItsPromptAndEditsDont() async {
    final class Seen: @unchecked Sendable { var systems: [String] = [] }
    let seen = Seen()
    let p = Pipeline(complete: { _, messages, json, _ in
        seen.systems.append(messages[0].content)
        return json ? #"{"action":"edit","text":"Hi.","vocabulary":null,"remember":false}"# : "Hello there."
    }, vocabulary: VocabularyStore(url: tmp()), cleanupModel: "/models/s1-mini-4bit", editModel: "big")
    _ = await p.run(req("hello there"))
    _ = await p.run(req("make it shorter", selection: "Hello there."))
    #expect(seen.systems == [Prompts.s1MiniSystem, Prompts.editSystem])
}

// #3: 4 s base covers cold starts; long dictations get 20 ms per word on top.
@Test func cleanupTimeoutScalesWithLength() async {
    let calls = Calls()
    _ = await pipeline(reply: "Hi.", calls: calls).run(req("hi"))
    _ = await pipeline(reply: "x", calls: calls).run(req(Array(repeating: "word", count: 150).joined(separator: " ")))
    #expect(zip(calls.timeouts, [4.02, 7.0]).allSatisfy { abs($0 - $1) < 1e-9 } && calls.timeouts.count == 2)
}

// #29: Gemma sometimes returns the <screen> text instead of the cleaned transcript.
private let todoist = "Todoist — Projects: Inbox, Meal Prep, Work. Today: Buy oat milk, Call Priya re: Q3 OKRs"

@Test func echoedContextIsDetected() {
    #expect(Pipeline.echoesContext(todoist, transcript: "Remind me to call Priya about the OKRs.", context: todoist))
    #expect(Pipeline.echoesContext(todoist, transcript: "We went to the store yesterday and bought some milk", context: todoist))
}

@Test func termFixesFromContextAreNotEcho() {
    #expect(!Pipeline.echoesContext("Refer to my Meal Prep project on Todoist.", transcript: "refer to my meal prep project on to do list", context: todoist))
    // A short dictation corrected to one screen term is most of its words, but only one.
    #expect(!Pipeline.echoesContext("Todoist", transcript: "to do list", context: todoist))
    #expect(!Pipeline.echoesContext("Add Buy oat milk to my Todoist Inbox.", transcript: "Add Buy milk to my Todoist Inbox.", context: todoist))
}

@Test func dictationFallsBackToRawWhenModelEchoesScreen() async {
    let r = await pipeline(reply: todoist).run(Request(transcript: "remind me to call priya about the okrs", selection: nil, context: ScreenSnapshot(text: todoist)))
    #expect(r.outcome == .insert("remind me to call priya about the okrs", label: "Dictated (raw)"))
}

@Test func dictationFallsBackToRawWhenLLMFails() async {
    let r = await pipeline(reply: nil).run(req("hello there"))
    #expect(r.outcome == .insert("hello there", label: "Dictated (raw)"))
    #expect(r.rejectedBy == nil)
}

@Test func rawFallbackNamesTheGuard() async {  // for the replay's per-guard counts
    let said = "we need to finish the slides before the client call on friday afternoon"
    let cases: [(String, String, ScreenSnapshot, String?)] = [
        (said, "We need to finish the slides before the client call on Friday afternoon.", ScreenSnapshot(), nil),
        (said, String(repeating: "Sure, here is the cleaned text. ", count: 10), ScreenSnapshot(), "length"),
        (said, String(repeating: "Sure, here is the cleaned text. ", count: 10), ScreenSnapshot(text: todoist), "length"),
        (said, "Friday.", ScreenSnapshot(), "dropsContent"),
        ("she said (not yet) and left", "She said and left.", ScreenSnapshot(), "dropsProtected"),
        ("remind me to call priya about the okrs", todoist, ScreenSnapshot(text: todoist), "echoesContext"),
    ]
    for (t, reply, ctx, guardName) in cases {
        let r = await pipeline(reply: reply).run(Request(transcript: t, selection: nil, context: ctx))
        #expect(r.rejectedBy == guardName, "\(reply.prefix(20))")
    }
}

// #116: echoesContext runs before length, so a long screen echo is named an echo, also when the
// replyLimit early stop (#100) cut it.
@Test func longScreenEchoIsNamedEcho() async {
    let said = "fix it", screen = String(repeating: todoist + "\n", count: 5)
    let limit = Pipeline.maxCleanupLength(said)
    let cut = (1...screen.count).lazy.map { String(screen.prefix($0)) }.first { Pipeline.pastReplyLimit($0, limit: limit) }!
    for reply in [screen, cut] {
        #expect(reply.count > limit)
        let r = await pipeline(reply: reply).run(Request(transcript: said, selection: nil, context: ScreenSnapshot(text: screen)))
        #expect(r.rejectedBy == "echoesContext")
        #expect(r.outcome == .insert(said, label: "Dictated (raw)"))
    }
}

// #116 step 2: a dictation of at most `shortDictationWords` words gets no screen text in its prompt (it echoed long
// screens). App, window title, domain and vocabulary stay; one word more keeps the screen.
@Test func shortDictationPromptLeavesOutScreenText() async {
    final class Seen: @unchecked Sendable { var user: [String] = [] }
    let seen = Seen(), store = VocabularyStore(url: tmp())
    try? store.add(VocabTerm(text: "Quillmate"))
    let p = Pipeline(complete: { _, messages, _, _ in seen.user.append(messages.last!.content); return "Ok." },
                     vocabulary: store, cleanupModel: "small", editModel: "big")
    let ctx = ScreenSnapshot(appName: "Ghostty", windowTitle: "build", webDomain: "example.com", text: todoist, ocrText: "Inbox zero")
    let n = Pipeline.shortDictationWords
    for words in [1, n, n + 1] {
        _ = await p.run(Request(transcript: Array(repeating: "ship", count: words).joined(separator: " "), selection: nil, context: ctx))
    }
    let empty = #"<screen app="Ghostty" window="build (example.com)">"# + "\n\n</screen>\n<vocabulary>Quillmate</vocabulary>"
    #expect(seen.user[0].hasPrefix(empty) && seen.user[1].hasPrefix(empty))
    #expect(seen.user[2].contains(todoist) && seen.user[2].contains("Inbox zero"))
}

// The rule changes only the prompt: the casing fix and echoesContext still see the whole screen.
@Test func shortDictationKeepsScreenForCasingAndEchoCheck() async {
    let r = await Pipeline(complete: { _, _, _, _ in "Ship it to Meal Prep." }, vocabulary: VocabularyStore(url: tmp()),
                           cleanupModel: "adapters/gemma-4-e2b-poptalk-v6", editModel: "big")
        .run(Request(transcript: "ship it to meal prep", selection: nil, context: ScreenSnapshot(text: todoist)))
    #expect(r.recased == ["Meal Prep"])
    let echo = await pipeline(reply: todoist).run(Request(transcript: "fix it", selection: nil, context: ScreenSnapshot(text: todoist)))
    #expect(echo.rejectedBy == "echoesContext")
}

@Test func literallyBypassesLLM() async {
    let calls = Calls()
    let r = await pipeline(reply: "x", calls: calls).run(req("Literally: make it shorter", selection: "Heading"))
    #expect(r.outcome == .replaceSelection("make it shorter", label: "Replaced"))
    #expect(calls.models.isEmpty)
}

// #14: an empty replacement must not delete the selection.
@Test func bareLiterallyDoesNothing() async {
    let r = await pipeline(reply: "x").run(req("Literally.", selection: "Heading"))
    #expect(r.outcome == .nothing)
}

// #53: "replace this with X" replaces the selection with X, without the model.
@Test(arguments: [
    ("Replaced this with Clippy.", "flippy", "Clippy"),
    ("replace it with Q4 roadmap", "Q3 plan", "Q4 roadmap"),
    ("Um, swap that for the blue one", "red one", "the blue one"),
    ("Replace with Final draft.", "Draft one.", "Final draft."),
])
func replaceThisWithBypassesLLM(utterance: String, selection: String, expected: String) async {
    let calls = Calls()
    let r = await pipeline(reply: "x", calls: calls).run(req(utterance, selection: selection))
    #expect(r.outcome == .replaceSelection(expected, label: "Replaced"))
    #expect(calls.models.isEmpty)
}

@Test(arguments: ["replace the commas with semicolons", "change the tone to formal", "change this to Wednesday",
                  "change this to French", "replace this with something shorter"])
func replaceEditsStillReachModel(utterance: String) async {
    let calls = Calls()
    _ = await pipeline(reply: #"{"action":"edit","text":"y"}"#, calls: calls).run(req(utterance, selection: "a, b, c"))
    #expect(calls.models == ["big"])
}

@Test func emptyReplaceDoesNothing() async {
    let reply = #"{"action":"replace","text":"  ","vocabulary":null,"remember":false}"#
    let r = await pipeline(reply: reply).run(req("replace with", selection: "Heading"))
    #expect(r.outcome == .nothing)
}

@Test func correctionOffersVocabularyWithoutSaving() async {
    let store = VocabularyStore(url: tmp())
    let calls = Calls()
    let reply = #"{"action":"correct","text":"Todoist","vocabulary":{"text":"Todoist","aliases":["todo list"]},"remember":false}"#
    let r = await pipeline(reply: reply, store: store, calls: calls)
        .run(req("This is Todoist", selection: "todo list"))  // a spelled form takes the #50 fast path
    #expect(r.outcome == .replaceSelection("Todoist", label: "Corrected"))
    #expect(r.vocabularyOffer == VocabTerm(text: "Todoist", aliases: ["todo list"]))
    #expect(r.remembered == nil)
    #expect(store.terms.isEmpty)
    #expect(calls.models == ["big"])
    #expect(calls.json == [true])
}

@Test func rememberSavesVocabulary() async {
    let store = VocabularyStore(url: tmp())
    let reply = #"{"action":"correct","text":"Todoist","vocabulary":{"text":"Todoist","aliases":["todo list"]},"remember":true}"#
    let r = await pipeline(reply: reply, store: store).run(req("Todoist, remember this", selection: "todo list"))
    #expect(r.remembered == VocabTerm(text: "Todoist", aliases: ["todo list"]))
    #expect(r.vocabularyOffer == nil)
    #expect(store.terms == [VocabTerm(text: "Todoist", aliases: ["todo list"])])
}

@Test func insertAfterMapsOutcome() async {
    let reply = #"{"action":"insertAfter","text":" See you Thursday.","vocabulary":null,"remember":false}"#
    let r = await pipeline(reply: reply).run(req("add after this: see you Thursday", selection: "Thanks."))
    #expect(r.outcome == .insertAfter(" See you Thursday."))
}

// A bare phrase over a selection replaces it; inserting needs an explicit ask ("add", "after"…).
@Test func insertWithoutAskReplaces() async {
    let reply = #"{"action":"insertAfter","text":" Debounce period.","vocabulary":null,"remember":false}"#
    let r = await pipeline(reply: reply).run(req("Debounce period.", selection: "time limit"))
    #expect(r.outcome == .replaceSelection("Debounce period.", label: "Replaced"))
    let before = #"{"action":"insertBefore","text":"Note: ","vocabulary":null,"remember":false}"#
    #expect(await pipeline(reply: before).run(req("Note.", selection: "x")).outcome == .replaceSelection("Note:", label: "Replaced"))
}

@Test func insertCuesKeepInsert() {
    for u in ["add after this: see you Thursday", "Append thanks", "insert a greeting before it", "put hi at the start",
              "and then at the end say thanks", "prepend Note"] {
        #expect(Pipeline.asksToInsert(u), "\(u)")
    }
    for u in ["Debounce period.", "Quarterly Review", "Afternoon tea", "Addison Lee"] {
        #expect(!Pipeline.asksToInsert(u), "\(u)")
    }
}

// #2: a model that repeats the selection inside an insert must not duplicate it.
@Test func insertAfterStripsRepeatedSelection() async {
    let reply = #"{"action":"insertAfter","text":"Thanks for the update. See you Thursday.","vocabulary":null,"remember":false}"#
    let r = await pipeline(reply: reply).run(req("add see you Thursday", selection: "Thanks for the update."))
    #expect(r.outcome == .insertAfter(" See you Thursday."))
}

@Test func insertBeforeStripsRepeatedSelection() async {
    let reply = #"{"action":"insertBefore","text":"Hi Sam, Thanks for the update.","vocabulary":null,"remember":false}"#
    let r = await pipeline(reply: reply).run(req("add hi Sam before", selection: "Thanks for the update."))
    #expect(r.outcome == .insertBefore("Hi Sam, "))
}

@Test func editMapsOutcome() async {
    let reply = #"{"action":"edit","text":"Could you send it?","vocabulary":null,"remember":false}"#
    let r = await pipeline(reply: reply).run(req("more formal", selection: "send it"))
    #expect(r.outcome == .replaceSelection("Could you send it?", label: "Edited"))
}

@Test func editFailureLeavesSelectionUntouched() async {
    let r = await pipeline(reply: nil).run(req("make it formal", selection: "hey"))
    #expect(r.outcome == .error("Couldn't reach the language model"))
}

// #11: a slow model is not an unreachable one.
@Test func editTimeoutSaysTooLong() async {
    let p = Pipeline(complete: { _, _, _, _ in throw URLError(.timedOut) },
                     vocabulary: VocabularyStore(url: tmp()), cleanupModel: "s", editModel: "b")
    let r = await p.run(req("make it formal", selection: "hey"))
    #expect(r.outcome == .error("Model took too long"))
}

@Test func malformedEditReplyIsError() async {
    let r = await pipeline(reply: "Sure, here you go: Hey.").run(req("make it formal", selection: "hey"))
    guard case .error = r.outcome else { Issue.record("expected error, got \(r.outcome)"); return }
}

// A vocabulary offer only makes sense for a term the edit actually produced.
@Test func bogusVocabularyOfferIsDropped() async {
    let reply = #"{"action":"correct","text":"Quarterly Review","vocabulary":{"text":"Q3 Notes","aliases":["q3 notes"]},"remember":false}"#
    let r = await pipeline(reply: reply).run(req("Quarterly Review", selection: "Q3 Notes"))
    #expect(r.outcome == .replaceSelection("Quarterly Review", label: "Corrected"))
    #expect(r.vocabularyOffer == nil)
}

// #54: the model's own action, before guards, for the bench.
@Test func modelActionIsTheParsedActionBeforeGuards() async {
    let reply = #"{"action":"insertAfter","text":" Debounce period.","vocabulary":null,"remember":false}"#
    let r = await pipeline(reply: reply).run(req("Debounce period.", selection: "time limit"))
    #expect(r.outcome == .replaceSelection("Debounce period.", label: "Replaced"))
    #expect(r.modelAction == "insertAfter")
    let blank = #"{"action":"replace","text":"  ","vocabulary":null,"remember":false}"#
    #expect(await pipeline(reply: blank).run(req("x", selection: "y")).modelAction == "replace")
    let vocab = #"{"action":"correct","text":"Todoist","vocabulary":{"text":"Todoist","aliases":[]},"remember":false}"#
    #expect(await pipeline(reply: vocab).run(req("Todoist", selection: "todo list")).modelAction == "correct")
}

@Test func modelActionIsNilWithoutAnEditModelCall() async {
    #expect(await pipeline(reply: "x").run(req("literally hi", selection: "y")).modelAction == nil)
    #expect(await pipeline(reply: "Hi.").run(req("hi")).modelAction == nil)
    #expect(await pipeline(reply: nil).run(req("fix", selection: "y")).modelAction == nil)
}
