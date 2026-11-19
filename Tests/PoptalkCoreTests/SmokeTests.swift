import Testing
@testable import PoptalkCore

@Test func vocabTermDefaultsWeightToTen() {
    #expect(VocabTerm(text: "Todoist", aliases: ["todo list"]).weight == 10)
}
