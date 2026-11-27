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

@Test func concurrentAddsAndReadsAreSafe() {
    let store = VocabularyStore(url: tempURL())
    DispatchQueue.concurrentPerform(iterations: 200) { i in
        try? store.add(VocabTerm(text: "term\(i)"))
        _ = store.terms.count
    }
    #expect(Set(store.terms.map(\.text)).count == 200)
    #expect(store.terms.count == 200)
}

@Test func removeDeletesCaseInsensitivelyAndPersists() throws {
    let url = tempURL()
    let store = VocabularyStore(url: url)
    try store.add(VocabTerm(text: "Todoist"))
    try store.add(VocabTerm(text: "Poptalk"))
    try store.remove("todoist")
    #expect(store.terms == [VocabTerm(text: "Poptalk")])
    #expect(VocabularyStore(url: url).terms == [VocabTerm(text: "Poptalk")])
}

@Test func missingFileIsEmpty() {
    #expect(VocabularyStore(url: tempURL()).terms.isEmpty)
}

@Test func importsFluidVoiceFormat() throws {
    let url = tempURL()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"alpha":2.8,"terms":[{"text":"FluidVoice","aliases":["fluid voice"],"weight":10.0}]}"#.utf8).write(to: url)
    #expect(try VocabularyStore.importFluidVoice(from: url)
        == [VocabTerm(text: "FluidVoice", aliases: ["fluid voice"])])
}

@Test func updateRenamesInPlaceKeepingPosition() throws {
    let url = tempURL()
    let store = VocabularyStore(url: url)
    try store.add(VocabTerm(text: "Todo", aliases: ["to do"]))
    try store.add(VocabTerm(text: "Poptalk"))
    try store.update("todo", to: VocabTerm(text: "Todoist", aliases: ["todo list"]))
    let want = [VocabTerm(text: "Todoist", aliases: ["todo list"]), VocabTerm(text: "Poptalk")]
    #expect(store.terms == want)
    #expect(VocabularyStore(url: url).terms == want)
}

@Test func updateChangesCaseOfTheSameTerm() throws {
    let store = VocabularyStore(url: tempURL())
    try store.add(VocabTerm(text: "todoist", aliases: ["todo list"]))
    try store.update("todoist", to: VocabTerm(text: "Todoist", aliases: []))
    #expect(store.terms == [VocabTerm(text: "Todoist")])
}

@Test func updateOntoAnotherTermMergesIntoIt() throws {
    let store = VocabularyStore(url: tempURL())
    try store.add(VocabTerm(text: "Todoist", aliases: ["todo list"]))
    try store.add(VocabTerm(text: "Todo", aliases: ["to do"]))
    try store.update("Todo", to: VocabTerm(text: "todoist", aliases: ["to do", "Todo List"]))
    #expect(store.terms == [VocabTerm(text: "Todoist", aliases: ["todo list", "to do"])])
}

@Test func updateTrimsAndDedupesAliases() throws {
    let store = VocabularyStore(url: tempURL())
    try store.add(VocabTerm(text: "Todo"))
    try store.update("Todo", to: VocabTerm(text: "  Todoist ", aliases: [" todo list ", "", "Todo List", "TODOIST", "to do"]))
    #expect(store.terms == [VocabTerm(text: "Todoist", aliases: ["todo list", "to do"])])
}

@Test func updateOfAMissingTermAddsIt() throws {
    let store = VocabularyStore(url: tempURL())
    try store.update("gone", to: VocabTerm(text: "Todoist"))
    #expect(store.terms == [VocabTerm(text: "Todoist")])
}

@Test func emptyTermIsRejected() throws {
    let store = VocabularyStore(url: tempURL())
    try store.add(VocabTerm(text: "Todoist"))
    #expect(throws: VocabularyError.emptyTerm) { try store.update("Todoist", to: VocabTerm(text: "  ")) }
    #expect(throws: VocabularyError.emptyTerm) { try store.add(VocabTerm(text: "", aliases: ["x"])) }
    #expect(store.terms == [VocabTerm(text: "Todoist")])
}

@Test func addNormalizesLikeUpdate() throws {
    let store = VocabularyStore(url: tempURL())
    try store.add(VocabTerm(text: " Todoist", aliases: ["todo list ", "todo list", "todoist"]))
    #expect(store.terms == [VocabTerm(text: "Todoist", aliases: ["todo list"])])
}
