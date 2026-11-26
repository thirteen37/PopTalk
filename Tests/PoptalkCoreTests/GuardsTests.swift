import Foundation
import Testing
@testable import PoptalkCore

// #108: the dictation guards are named lists, run in order; PoptalkBench --guards turns steps off.
@Test func guardNamesAreUniqueAndOrdered() {
    #expect(Pipeline.guardNames == ["spokenFormatting", "spokenCancel", "spokenNumbers", "stripChatter", "restoreMarks", "openingCue",
                                    "empty", "length", "dropsContent", "dropsProtected", "echoesContext"])
    #expect(Set(Pipeline.guardNames).count == Pipeline.guardNames.count)
}

private func dictate(_ transcript: String, reply: String, off: Set<String> = []) async -> PipelineResult {
    var features = DictationFeatures()
    features.guardsOff = off
    let p = Pipeline(complete: { _, _, _, _ in reply },
                     vocabulary: VocabularyStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
                     cleanupModel: "s", editModel: "b", features: features)
    return await p.run(Request(transcript: transcript, selection: nil, context: ScreenSnapshot()))
}

// #117: which repairs changed the reply, for replay counts; trimming alone doesn't count.
@Test func repairedNamesTheRepairsThatChangedTheReply() async {
    #expect(await dictate("Send the report by Friday.", reply: "Send the report by Friday.\n").repaired == [])
    #expect(await dictate("Send the report by Friday.", reply: "<think>ok</think>Send the report by Friday.").repaired == ["stripChatter"])
    let r = await dictate("No, send the report by Friday.", reply: "<think></think>Send the report by Friday.")
    #expect(r.repaired == ["stripChatter", "openingCue"])
    #expect(r.outcome == .insert("No, send the report by Friday.", label: "Dictated"))
    let rejected = await dictate("Send the report by Friday.", reply: "<think></think>" + String(repeating: "lorem ipsum dolor ", count: 6))
    #expect(rejected.rejectedBy == "length")
    #expect(rejected.repaired == ["stripChatter"])
    #expect(await dictate("Send the report by Friday.", reply: "<think></think>Send it.", off: ["stripChatter"]).repaired == [])
}

@Test func turnedOffGuardIsSkipped() async {
    let said = "Send the report by Friday.", long = String(repeating: "lorem ipsum dolor ", count: 6)
    #expect(await dictate(said, reply: long).rejectedBy == "length")
    let r = await dictate(said, reply: long, off: ["length"])
    #expect(r.rejectedBy == nil)
    #expect(r.outcome == .insert(long.trimmingCharacters(in: .whitespaces), label: "Dictated"))
    #expect(Pipeline.dictationPrepass("about seventy five thousand users", off: ["spokenNumbers"]) == "about seventy five thousand users")
    #expect(Pipeline.dictationPrepass("about seventy five thousand users") != "about seventy five thousand users")
}
