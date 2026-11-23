import Foundation
import Testing
@testable import PoptalkCore

// MARK: - Anchors

@Test func anchorsFindTheInsertEndingAtTheCaret() throws {
    // "a b" occurs twice; the caret says which one was pasted.
    let value = "a b, then a b"
    let a = try #require(InsertAnchors(value: value, inserted: " a b", caret: value.utf16.count))
    #expect(a.span(in: value) == " a b")
    #expect(a.span(in: "a b, then a c") == " a c")
}

@Test func anchorsFallBackToTheOnlyOccurrenceWithoutAUsableCaret() throws {
    let value = "Hi. Send it to todo list. Bye"
    for caret in [nil, 0, 999] as [Int?] {
        let a = try #require(InsertAnchors(value: value, inserted: " Send it to todo list.", caret: caret))
        #expect(a.span(in: "Hi. Send it to Todoist. Bye") == " Send it to Todoist.")
    }
}

@Test func anchorsAreNilWhenTheInsertIsAmbiguousOrMissing() {
    #expect(InsertAnchors(value: "ok ok", inserted: "ok", caret: nil) == nil)
    #expect(InsertAnchors(value: "ok ok", inserted: "ok", caret: 1) == nil)
    #expect(InsertAnchors(value: "ok ok", inserted: "ok", caret: 2)?.span(in: "OK ok") == "OK")
    #expect(InsertAnchors(value: "something else", inserted: "hello", caret: 5) == nil)
    #expect(InsertAnchors(value: "hello", inserted: "", caret: 0) == nil)
}

@Test func spanIsNilOnceTheTextAroundTheInsertChanged() throws {
    let a = try #require(InsertAnchors(value: "Dear Bob, hello there. Thanks", inserted: " hello there.", caret: 22))
    #expect(a.span(in: "Dear Rob, hello there. Thanks") == nil)
    #expect(a.span(in: "Dear Bob, hello there. Cheers") == nil)
    #expect(a.span(in: "") == nil)
    #expect(a.span(in: "Dear Bob, Thanks") == "")  // deleted
}

/// What `TypingWatch` gets from a field value: the correction and the offer, if any.
private func watched(_ a: InsertAnchors, _ inserted: String, _ value: String, said: String) -> (TypedCorrection, VocabTerm?)? {
    a.span(in: value).flatMap { TypedCorrection(inserted: inserted, span: $0, transcript: said) }
        .map { ($0, $0.offer(known: [], isWord: { $0.lowercased() != "quorbit" })) }
}

@Test func dictationIntoAnEmptyFieldEndsWhenSentOrReplaced() throws {
    // An empty composer: both anchors are empty, so they match any later value (#94).
    let ins = "Call me later."
    let a = try #require(InsertAnchors(value: ins, inserted: ins, caret: ins.utf16.count))
    #expect(a.span(in: "") == "")  // sent or deleted: the watch ends there (#95 tells which)
    // The next message: once a misheard term offer, now new text, not a fix.
    #expect(a.span(in: "Run quorbit now") == nil)
    #expect(watched(a, ins, "Run quorbit now", said: "call me later") == nil)
    #expect(a.span(in: "Did the parcel arrive yet?") == nil)
    // Typed on after a prefix the next message shares.
    let b = try #require(InsertAnchors(value: "Hi there, call me later.", inserted: " call me later.", caret: 24))
    #expect(b.span(in: "Hi there, see you on the weekend") == nil)
}

@Test func fixingADictationInAnEmptyFieldStillCounts() throws {
    let ins = "Ask the cue orbit team."
    let a = try #require(InsertAnchors(value: ins, inserted: ins, caret: ins.utf16.count))
    let (c, term) = try #require(watched(a, ins, "Ask the Quorbit team.", said: "ask the cue orbit team"))
    #expect(c.changes == [.init(old: ["cue", "orbit"], new: ["Quorbit"], cause: .misheard)])
    #expect(term == VocabTerm(text: "Quorbit", aliases: ["cue orbit"]))
    // A short one with a term fixed, and typing on after a fix.
    let short = "Run cue orbit."
    let s = try #require(InsertAnchors(value: short, inserted: short, caret: short.utf16.count))
    #expect(watched(s, short, "Run Quorbit.", said: "run cue orbit")?.1?.text == "Quorbit")
    #expect(watched(a, ins, "Ask the Quorbit team. And one more thing", said: "ask the cue orbit team")?.0.text
        == "Ask the Quorbit team.")
}

@Test func anchorsCountUTF16LikeAX() throws {
    let value = "👋 hi 😀 there"
    let caret = ("👋 hi 😀" as String).utf16.count
    let a = try #require(InsertAnchors(value: value, inserted: " hi 😀", caret: caret))
    #expect(a.span(in: "👋 hey 😀 there") == " hey 😀")
}

// MARK: - Diff and classification

private func fix(_ inserted: String, _ span: String, said transcript: String) -> TypedCorrection? {
    TypedCorrection(inserted: inserted, span: span, transcript: transcript)
}

@Test func unchangedOrWhitespaceOnlyOrDeletedIsNoCorrection() {
    #expect(fix(" Send it.", " Send it.", said: "send it") == nil)
    #expect(fix(" Send it.", "Send  it.", said: "send it") == nil)
    #expect(fix(" Send it.", "", said: "send it") == nil)
}

@Test func misheardWordsComeFromTheTranscript() throws {
    let c = try #require(fix(" Send it to todo list.", " Send it to Todoist.", said: "send it to todo list"))
    #expect(c.text == "Send it to Todoist.")
    #expect(c.changes == [.init(old: ["todo", "list."], new: ["Todoist."], cause: .misheard)])
}

@Test func cleanupMistakesHadTheUsersWordsInTheTranscript() throws {
    // Changed: the transcript said "Bob".
    let changed = try #require(fix("Send it to Rob.", "Send it to Bob.", said: "send it to bob"))
    #expect(changed.changes.map(\.cause) == [.cleanup])
    // Dropped: the user puts back what they said.
    let dropped = try #require(fix("Call mom.", "Call mom tomorrow at noon.", said: "call mom tomorrow at noon"))
    #expect(dropped.changes.map(\.cause) == [.cleanup])
    // Added: the user deletes words they never said.
    let added = try #require(fix("Thanks so much for your help!", "Thanks for your help!", said: "thanks for your help"))
    #expect(added.changes == [.init(old: ["so", "much"], new: [], cause: .cleanup)])
    // Case and punctuation only: what was said, formatted differently.
    let cased = try #require(fix("I use github.", "I use GitHub.", said: "i use github"))
    #expect(cased.changes.map(\.cause) == [.cleanup])
}

@Test func rewordingAndDeletingWhatWasSaidIsOther() throws {
    let reworded = try #require(fix("It was a big deal.", "It was a huge deal.", said: "it was a big deal"))
    #expect(reworded.changes.map(\.cause) == [.misheard])  // a single word from the transcript replaced...
    #expect(reworded.offer(known: [], isWord: { _ in true }) == nil)  // ...but a dictionary word: no offer
    let deleted = try #require(fix("It was a big deal.", "It was a deal.", said: "it was a big deal"))
    #expect(deleted.changes.map(\.cause) == [.other])
    let rewritten = try #require(fix("It was a significant deal.", "It was a huge deal.", said: "it was a big deal"))
    #expect(rewritten.changes.map(\.cause) == [.other])
}

@Test func textTypedBeforeOrAfterTheDictationIsLeftOut() throws {
    // Typed on right after a fix to the last word: cut after the sentence end the dictation had.
    let c = try #require(fix(" Send it to todo list.", " Send it to Todoist. And more text", said: "send it to todo list"))
    #expect(c.text == "Send it to Todoist.")
    #expect(c.changes == [.init(old: ["todo", "list."], new: ["Todoist."], cause: .misheard)])
    #expect(fix(" Send it.", " Send it. More", said: "send it") == nil)
    #expect(fix("Send it.", "So: Send it.", said: "send it") == nil)
}

@Test func severalChangesAreClassifiedEachOnTheirOwn() throws {
    let c = try #require(fix("Ask Rob today about todo list.", "Ask Bob about Todoist.", said: "ask bob about todo list"))
    #expect(c.changes.map(\.cause) == [.cleanup, .misheard])
}

// MARK: - Offers

private func notAWord(_ w: String) -> Bool { !["todoist", "kubectl"].contains(w.lowercased()) }

@Test func misheardTermIsOfferedWithTheHeardFormAsAlias() throws {
    let c = try #require(fix(" Send it to todo list.", " Send it to Todoist.", said: "send it to todo list"))
    #expect(c.offer(known: [], isWord: notAWord) == VocabTerm(text: "Todoist", aliases: ["todo list"]))
    let lower = try #require(fix("Run cube cuddle.", "Run kubectl.", said: "run cube cuddle"))
    #expect(lower.offer(known: [], isWord: notAWord) == VocabTerm(text: "kubectl", aliases: ["cube cuddle"]))
    // Inner capitals or digits look like a term even when every word is in the dictionary.
    let caps = try #require(fix("Open mac book.", "Open MacBook.", said: "open mac book"))
    #expect(caps.offer(known: [], isWord: { _ in true })?.text == "MacBook")
}

@Test func savedTermIsOfferedAgainOnlyForANewHeardForm() throws {
    let c = try #require(fix(" Send it to todo list.", " Send it to Todoist.", said: "send it to todo list"))
    // `VocabularyStore.add` merges the new alias into the saved term.
    #expect(c.offer(known: [VocabTerm(text: "todoist", aliases: ["today's"])], isWord: notAWord)
        == VocabTerm(text: "Todoist", aliases: ["todo list"]))
}

@Test func noOfferForSavedTermsCleanupMistakesOrLongRewrites() throws {
    let c = try #require(fix(" Send it to todo list.", " Send it to Todoist.", said: "send it to todo list"))
    #expect(c.offer(known: [VocabTerm(text: "todoist", aliases: ["Todo List"])], isWord: notAWord) == nil)
    let cleanup = try #require(fix("I use github.", "I use GitHub.", said: "i use github"))
    #expect(cleanup.offer(known: [], isWord: { _ in false }) == nil)
    let long = try #require(fix("Ask about the todo list thing.", "Ask about Todoist Pro Max Ultra.", said: "ask about the todo list thing"))
    #expect(long.offer(known: [], isWord: { _ in false }) == nil)
}
