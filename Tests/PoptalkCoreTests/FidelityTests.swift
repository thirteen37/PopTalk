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

@Test func lastSentenceOnlyFallsBackToRaw() async {
    let said = "One of my earlier dictations had quote and unquote, but those weren't translated properly. Whose job is that?"
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

// Hyphenated interjections are words: kept whole, never half-stripped.
@Test func hesitationStripKeepsHyphenatedInterjections() {
    #expect(Pipeline.stripHesitations("Mm-hmm.") == "Mm-hmm.")
    #expect(Pipeline.stripHesitations("uh-huh, sounds good") == "uh-huh, sounds good")
    #expect(Pipeline.stripHesitations("Uh-oh, the build broke") == "Uh-oh, the build broke")
    #expect(Pipeline.stripHesitations("hmm") == "")
    #expect(Pipeline.stripHesitations("um") == "")
    #expect(Pipeline.stripHesitations("hmm, let me think. um ok") == "let me think. ok")
}
