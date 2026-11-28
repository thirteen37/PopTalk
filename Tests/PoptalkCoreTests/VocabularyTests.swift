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

// MARK: iCloud sync (#129). A temp directory stands in for iCloud Drive.

/// A Mac with its own vocabulary.json and defaults, syncing via `root` while its defaults' "sync" is true.
private func mac(_ root: URL, sync on: Bool = true) -> (VocabularyStore, UserDefaults) {
    let name = "poptalk-test-\(UUID())"
    let d = UserDefaults(suiteName: name)!
    d.set(on, forKey: "sync")
    let sync = VocabularyStore.Sync(root: root, defaults: d) { UserDefaults(suiteName: name)!.bool(forKey: "sync") }
    return (VocabularyStore(url: tempURL(), sync: sync), d)
}

private func syncRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

private let t0 = Date(timeIntervalSince1970: 1_000_000)

@Test func addOnOneMacShowsUpOnAnother() throws {
    let root = syncRoot()
    let (a, _) = mac(root), (b, _) = mac(root)
    try b.add(VocabTerm(text: "Poptalk"))
    try a.add(VocabTerm(text: "Todoist", aliases: ["todo list"]))
    a.sync(now: t0)
    b.sync(now: t0 + 1)
    a.sync(now: t0 + 2)
    #expect(b.terms == [VocabTerm(text: "Poptalk"), VocabTerm(text: "Todoist", aliases: ["todo list"])])
    #expect(a.terms == [VocabTerm(text: "Todoist", aliases: ["todo list"]), VocabTerm(text: "Poptalk")])
    #expect(a.sync?.file.lastPathComponent == "vocabulary-\(a.sync!.deviceID).json")
}

@Test func deleteBeatsAnOlderUpsertFromAnotherMac() throws {
    let root = syncRoot()
    let (a, _) = mac(root), (b, _) = mac(root)
    try a.add(VocabTerm(text: "Todoist"))
    a.sync(now: t0)
    b.sync(now: t0 + 1)
    #expect(b.terms == [VocabTerm(text: "Todoist")])
    try b.update("Todoist", to: VocabTerm(text: "Todoist", aliases: ["todo list"]))
    b.sync(now: t0 + 2)  // B's edit is older than A's delete, which A makes before seeing it
    try a.remove("todoist")
    a.sync(now: t0 + 3)
    b.sync(now: t0 + 4)
    a.sync(now: t0 + 5)
    #expect(a.terms.isEmpty && b.terms.isEmpty)
    // Re-adding later wins over the delete.
    try b.add(VocabTerm(text: "Todoist"))
    b.sync(now: t0 + 6)
    a.sync(now: t0 + 7)
    #expect(a.terms == [VocabTerm(text: "Todoist")])
}

@Test func renameSyncsAsDeleteAndUpsert() throws {
    let root = syncRoot()
    let (a, _) = mac(root), (b, _) = mac(root)
    try a.add(VocabTerm(text: "Todo", aliases: ["to do"]))
    try a.add(VocabTerm(text: "Poptalk"))
    a.sync(now: t0)
    b.sync(now: t0 + 1)
    try a.update("todo", to: VocabTerm(text: "Todoist", aliases: ["to do"]))
    a.sync(now: t0 + 2)
    b.sync(now: t0 + 3)
    #expect(b.terms == [VocabTerm(text: "Poptalk"), VocabTerm(text: "Todoist", aliases: ["to do"])])
}

@Test func vocabularySyncOffWritesNothingAndDeleteRemovesOnlyThisMacsFile() throws {
    let root = syncRoot()
    let (a, d) = mac(root, sync: false)
    try a.add(VocabTerm(text: "Todoist"))
    a.sync(now: t0)
    #expect(!FileManager.default.fileExists(atPath: root.path))
    d.set(true, forKey: "sync")  // read per sync: takes effect at once
    a.sync(now: t0 + 1)
    let (b, _) = mac(root)
    b.sync(now: t0 + 2)
    #expect(b.terms == [VocabTerm(text: "Todoist")])
    d.set(false, forKey: "sync")
    try a.remove("Todoist")
    a.sync(now: t0 + 3)
    b.sync(now: t0 + 4)
    #expect(b.terms == [VocabTerm(text: "Todoist")])  // off: A's delete isn't written
    a.deleteSyncedCopy()
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [b.sync!.file.lastPathComponent])
}

@Test func mergeKeepsTheNewestChangePerKeyAndDeletesWinTies() {
    let up = VocabChange(VocabTerm(text: "Todoist"), at: t0)
    let del = VocabChange(deleted: "todoist", at: t0)
    #expect(VocabularyStore.merge([["todoist": up], ["todoist": del]])["todoist"] == del)
    #expect(VocabularyStore.merge([["todoist": del], ["todoist": up]])["todoist"] == del)
    let newer = VocabChange(VocabTerm(text: "todoist"), at: t0 + 1)
    #expect(VocabularyStore.merge([["todoist": newer], ["todoist": del]])["todoist"] == newer)
}
