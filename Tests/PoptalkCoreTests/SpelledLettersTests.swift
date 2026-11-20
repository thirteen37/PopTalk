import Foundation
import Testing
@testable import PoptalkCore

// #50: a trailing run of spelled letters resolves the correction without the model.
@Test(arguments: [
    ("Replace this with R J A J A Y.", "Arjee", "Ajay"),  // "Ajay" heard as "R J" before its spelling
    ("This is Todoist, capital T-O-D-O-I-S-T", "todo list", "Todoist"),
    ("it's Priya, P-R-I-Y-A", "pria", "Priya"),
    ("A, J, A, Y", "Arjee", "Ajay"),
    ("it's NASA, all caps N A S A", "nassa", "NASA"),
    ("it's GitHub, capital G I T capital H U B", "git hub", "GitHub"),
])
func spelledLettersResolve(utterance: String, selection: String, word: String) async {
    #expect(Pipeline.spelledWord(utterance, selection: selection) == word)
    let store = VocabularyStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
    let p = Pipeline(complete: { _, _, _, _ in Issue.record("model called"); return "" },
                     vocabulary: store, cleanupModel: "s", editModel: "e")
    let r = await p.run(Request(transcript: utterance, selection: selection, context: ScreenSnapshot()))
    #expect(r.outcome == .replaceSelection(word, label: "Corrected"))
    #expect(r.vocabularyOffer == VocabTerm(text: word, aliases: [selection.lowercased()]))
}

@Test(arguments: [
    ("make it A B testing friendly", "this"),
    ("add a Q and A section", "Intro"),
    ("make it a B C", "xyz"),  // letters, but nothing they spell sounds like
    ("it's A B", "ab"),  // under 3 letters
])
func nonSpellingsReachModel(utterance: String, selection: String) {
    #expect(Pipeline.spelledWord(utterance, selection: selection) == nil)
}
