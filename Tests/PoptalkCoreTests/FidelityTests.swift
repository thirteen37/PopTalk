import Foundation
import Testing
@testable import PoptalkCore

// #47: a cleanup that drops most of what was said falls back to the raw transcript.
private func dictate(_ transcript: String, reply: String) async -> Outcome {
    let p = Pipeline(complete: { _, _, _, _ in reply },
                     vocabulary: VocabularyStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
                     cleanupModel: "s", editModel: "b")
    return await p.run(Request(transcript: transcript, selection: nil, context: ScreenSnapshot())).outcome
}

// A cleanup reply past the length guard is cut off at it: same raw outcome, sooner.
private final class Seen: @unchecked Sendable { var limits: [Int?] = [] }

private func run(_ transcript: String, selection: String? = nil, reply: String) async -> (Outcome, [Int?]) {
    let seen = Seen()
    let p = Pipeline(complete: { _, _, _, _ in seen.limits.append(Pipeline.replyLimit); return reply },
                     vocabulary: VocabularyStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
                     cleanupModel: "s", editModel: "b")
    return (await p.run(Request(transcript: transcript, selection: selection, context: ScreenSnapshot())).outcome, seen.limits)
}

@Test func longCleanupGetsLimitAndFallsBackToRaw() async {
    let said = "Send the report by Friday."
    let (outcome, limits) = await run(said, reply: String(repeating: "lorem ipsum dolor ", count: 60))
    #expect(outcome == .insert(said, label: "Dictated (raw)"))
    #expect(limits == [Pipeline.maxCleanupLength(said)])
    #expect(Pipeline.maxCleanupLength(said) == 79)  // 26 × 1.5 + 40
}

@Test func editsGetNoReplyLimit() async {
    let (outcome, limits) = await run("make it formal", selection: "hey there",
                                      reply: #"{"action":"edit","text":"Hello there.","vocabulary":null,"remember":false}"#)
    #expect(outcome == .replaceSelection("Hello there.", label: "Edited"))
    #expect(limits == [nil])
}

@Test func cleanupAtTheLimitIsAccepted() async {
    let said = "Send the report by Friday."
    let atLimit = "Send the report by Friday. " + String(repeating: "x", count: 79 - 27)
    #expect(await run(said, reply: atLimit).0 == .insert(atLimit, label: "Dictated"))
    #expect(await run(said, reply: atLimit + "x").0 == .insert(said, label: "Dictated (raw)"))
}

@Test func pastReplyLimitOnlyWhenNoAcceptedReplyCanFollow() {
    let x = { String(repeating: "x", count: $0) }
    #expect(!Pipeline.pastReplyLimit(x(79), limit: 79))
    // Margin: tag fragments and a list marker the guard strips before measuring.
    #expect(!Pipeline.pastReplyLimit(x(79) + "</transcript", limit: 79))
    #expect(!Pipeline.pastReplyLimit("  12. " + x(79), limit: 79))
    // Whitespace can be trimmed or collapsed away, so it never counts.
    #expect(!Pipeline.pastReplyLimit(x(70) + String(repeating: " ", count: 500), limit: 79))
    #expect(Pipeline.pastReplyLimit(x(200), limit: 79))
    // An open reasoning block may still close and be stripped; a closed one is ignored.
    #expect(!Pipeline.pastReplyLimit("<think>" + x(500), limit: 79))
    #expect(!Pipeline.pastReplyLimit("<think>" + x(500) + "</think>Fine.", limit: 79))
    #expect(Pipeline.pastReplyLimit("<think>a</think>" + x(200), limit: 79))
}

@Test func lastSentenceOnlyFallsBackToRaw() async {
    let said = "One of my earlier dictations had quote and unquote, but those weren't translated properly. Whose job is that?"
    // "quote and unquote" is a mention, not a spoken quote (#69).
    #expect(await dictate(said, reply: "Whose job is that?") == .insert(said, label: "Dictated (raw)"))
    let ask = "I pushed the fix to staging this morning. Can you check whether the login bug is gone?"
    #expect(await dictate(ask, reply: "Can you check whether the login bug is gone?") == .insert(ask, label: "Dictated (raw)"))
}

@Test func rawFallbackIsHesitationStripped() async {
    let said = "The delay when closing the overlay and uh also the time given to the user to press escape is a bit too short. Um can we make it configurable"
    #expect(await dictate(said, reply: "Can we make it configurable?") == .insert(
        "The delay when closing the overlay and also the time given to the user to press escape is a bit too short. can we make it configurable",
        label: "Dictated (raw)"))
}

@Test func selfCorrectionsAndFillersStillClean() async {
    let cases = [
        ("um so let's meet on tuesday no thursday at uh three", "Let's meet on Thursday at three."),
        ("the meeting is at two pm sorry four pm in the main room", "The meeting is at 4 PM in the main room."),
        ("book the table for four actually make it six", "Book the table for six."),
        ("call me at nine i mean ten tomorrow", "Call me at ten tomorrow."),
        ("so like the thing is we need to uh ship this by next week basically", "We need to ship this by next week."),
        ("you know i think we should um basically just go with the first option", "I think we should go with the first option."),
        ("remind me to call priya about the q three okrs", "Remind me to call Priya about the Q3 OKRs."),
        ("i'll review the kubernetes pr for fluid audio this afternoon", "I'll review the Kubernetes PR for FluidAudio this afternoon."),
        ("i'll send the questionnaire to tomasz vreshnevski today", "I'll send the questionnaire to Tomasz Wrzesniewski today."),
        ("One of my earlier dictations had quote and unquote, but those weren't translated properly. Whose job is that?",
         "One of my earlier dictations had \"and\", but those weren't translated properly. Whose job is that?"),
    ]
    for (said, clean) in cases {
        #expect(await dictate(said, reply: clean) == .insert(clean, label: "Dictated"), "\(said)")
    }
}

// #102: a spoken cancellation drops what it cancels; only what follows the last cue must stay.
@Test func cancellationsMayDropWhatTheyCancel() {
    let ok = [
        ("pick up the dry cleaning and drop off the parcels at the post office scratch that the post office is closed today",
         "The post office is closed today."),
        ("we should repaint the garden fence this weekend never mind it's going to rain", "It's going to rain."),
        ("bring the camping chairs the cooler and the big umbrella actually Forget the umbrella",
         "Bring the camping chairs and the cooler."),
    ]
    for (said, clean) in ok { #expect(!Pipeline.dropsContent(clean, transcript: said), "\(said)") }
    // Dropping what follows the cue still falls back, and "don't forget the" is no cancellation.
    #expect(Pipeline.dropsContent("The meeting moved to Friday.",
                                  transcript: "the meeting moved to friday scratch that it stays on thursday afternoon with the whole design team"))
    #expect(Pipeline.dropsContent("Snacks for the long drive.",
                                  transcript: "don't forget the passports the tickets the chargers and the snacks for the long drive"))
}

// Hyphenated interjections are words: kept whole, never half-stripped.
@Test func hesitationStripKeepsHyphenatedInterjections() {
    #expect(Pipeline.stripHesitations("Mm-hmm.") == "Mm-hmm.")
    #expect(Pipeline.stripHesitations("uh-huh, sounds good") == "uh-huh, sounds good")
    #expect(Pipeline.stripHesitations("Uh-oh, the build broke") == "Uh-oh, the build broke")
    #expect(Pipeline.stripHesitations("hmm") == "")
    #expect(Pipeline.stripHesitations("um") == "")
    #expect(Pipeline.stripHesitations("hmm, let me think. um ok") == "let me think. ok")
}
