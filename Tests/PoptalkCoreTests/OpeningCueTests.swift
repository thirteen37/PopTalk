import Foundation
import Testing
@testable import PoptalkCore

// #105: E2B v6 deletes a "No"/"Sorry" that opens the dictation, as if it were a self-correction.
private func dictate(_ transcript: String, selection: String? = nil, reply: String) async -> Outcome {
    let p = Pipeline(complete: { _, _, _, _ in reply },
                     vocabulary: VocabularyStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
                     cleanupModel: "s", editModel: "b")
    return await p.run(Request(transcript: transcript, selection: selection, context: ScreenSnapshot())).outcome
}

@Test func heldOutNoIsPutBack() async {
    #expect(await dictate("no the review is still on for today", reply: "The review is still on for today.")
            == .insert("No, the review is still on for today.", label: "Dictated"))
}

@Test func openingCueCasing() {
    func fix(_ out: String, _ said: String) -> String { Pipeline.restoreOpeningCue(out, transcript: said) }
    #expect(fix("The review is on.", "no the review is on") == "No, the review is on.")
    #expect(fix("Tuesday works.", "No, Tuesday works.") == "No, Tuesday works.")
    #expect(fix("Tuesday works.", "no Tuesday works") == "No, Tuesday works.")
    #expect(fix("I didn't catch your name.", "sorry i didn't catch your name") == "Sorry, I didn't catch your name.")
    #expect(fix("I'm on my way.", "wait I'm on my way") == "Wait, I'm on my way.")
    #expect(fix("The old one was faster.", "actually the old one was faster") == "Actually, the old one was faster.")
    // A capital that only starts a sentence in the transcript isn't a name.
    #expect(fix("The review is on.", "No. The review is on.") == "No, the review is on.")
    // Acronyms keep their case.
    #expect(fix("API is down.", "no api is down") == "No, API is down.")
    // #148: "forget the" mid-sentence is no cancel, so the opener still goes back.
    #expect(fix("I always forget the door code.", "no I always forget the door code") == "No, I always forget the door code.")
}

@Test func openingCueAfterFiller() {
    #expect(Pipeline.restoreOpeningCue("The review is on.", transcript: "um, no the review is on") == "No, the review is on.")
    #expect(Pipeline.restoreOpeningCue("The review is on.", transcript: "uh no the review is on") == "No, the review is on.")
}

@Test func openingCueLeftAlone() async {
    func fix(_ out: String, _ said: String) -> String { Pipeline.restoreOpeningCue(out, transcript: said) }
    // Already there, or a phrase starting with the word.
    #expect(fix("No problem, I'll send it.", "no problem i'll send it") == "No problem, I'll send it.")
    #expect(fix("No, the review is on.", "no the review is on") == "No, the review is on.")
    #expect(fix("Sorry, I'm late.", "sorry i'm late") == "Sorry, I'm late.")
    // Not opening the transcript; a word only starting with a cue.
    #expect(fix("The review is Thursday.", "the review is tuesday no thursday") == "The review is Thursday.")
    #expect(fix("Nothing changed.", "nothing changed") == "Nothing changed.")
    #expect(fix("Notes are ready.", "notes are ready") == "Notes are ready.")
    // Empty output.
    #expect(fix("", "no the review is on") == "")
    // A spoken cancel later on may take the opener with it.
    #expect(fix("It's off.", "no the review is on. never mind, it's off") == "It's off.")
    #expect(fix("It's off.", "no the review is on. Forget it, it's off") == "It's off.")
    // Raw fallback: the guards rejected the reply, so the raw transcript goes in unchanged.
    #expect(await dictate("no the review is still on for today", reply: "")
            == .insert("no the review is still on for today", label: "Dictated (raw)"))
    // Whole-dictation cancel: nothing is inserted.
    #expect(await dictate("no the review is still on. scratch that.", reply: "The review is still on.") == .nothing)
    // Edits never get it.
    #expect(await dictate("no make it formal", selection: "hey there",
                          reply: #"{"action":"edit","text":"Hello there.","vocabulary":null,"remember":false}"#)
            == .replaceSelection("Hello there.", label: "Edited"))
}
