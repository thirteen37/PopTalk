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

// #3: 4 s base covers cold starts; long dictations get 20 ms per word on top.
@Test func cleanupTimeoutScalesWithLength() async {
    let calls = Calls()
    _ = await pipeline(reply: "Hi.", calls: calls).run(req("hi"))
    _ = await pipeline(reply: "x", calls: calls).run(req(Array(repeating: "word", count: 150).joined(separator: " ")))
    #expect(zip(calls.timeouts, [4.02, 7.0]).allSatisfy { abs($0 - $1) < 1e-9 } && calls.timeouts.count == 2)
}

@Test func dictationFallsBackToRawWhenLLMFails() async {
    let r = await pipeline(reply: nil).run(req("hello there"))
    #expect(r.outcome == .insert("hello there", label: "Dictated (raw)"))
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
        .run(req("This is Todoist, capital T-O-D-O-I-S-T", selection: "todo list"))
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

@Test func malformedEditReplyIsError() async {
    let r = await pipeline(reply: "Sure, here you go: Hey.").run(req("make it formal", selection: "hey"))
    guard case .error = r.outcome else { Issue.record("expected error, got \(r.outcome)"); return }
}
