import Foundation
import Testing
@testable import PoptalkCore

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("vocabulary.json")
}

@Test func addPersistsAcrossInstances() throws {
    let url = tempURL()
    try VocabularyStore(url: url).add(VocabTerm(text: "Todoist", aliases: ["todo list"]))
    #expect(VocabularyStore(url: url).terms == [VocabTerm(text: "Todoist", aliases: ["todo list"])])
}

@Test func addMergesAliasesCaseInsensitively() throws {
    let store = VocabularyStore(url: tempURL())
    try store.add(VocabTerm(text: "Todoist", aliases: ["todo list"]))
    try store.add(VocabTerm(text: "todoist", aliases: ["to do list", "Todo List"]))
    #expect(store.terms == [VocabTerm(text: "Todoist", aliases: ["todo list", "to do list"])])
}

@Test func missingFileIsEmpty() {
    #expect(VocabularyStore(url: tempURL()).terms.isEmpty)
}

@Test func importsFluidVoiceFormat() throws {
    let url = tempURL()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"alpha":2.8,"terms":[{"text":"FluidVoice","aliases":["fluid voice"],"weight":10.0}]}"#.utf8).write(to: url)
    #expect(try VocabularyStore.importFluidVoice(from: url)
        == [VocabTerm(text: "FluidVoice", aliases: ["fluid voice"], weight: 10)])
}
