import Foundation
import Testing
@testable import PoptalkCore

// #75 step 2: the learned fidelity guard's probe. A yes/no score from the cleanup model on (transcript, reply, level);
// below `fidelityProbeThreshold` the reply goes in raw, only with `fidelityProbe` on. `fidelityShadow` (PoptalkBench
// replay) scores without acting. Invented text.
private final class Asked: @unchecked Sendable { var messages: [[ChatMessage]] = [] }

private func dictate(_ said: String, reply: String, score: Double?, probe: Bool = false, shadow: Bool = false,
                     screen: String = "") async -> (PipelineResult, Asked) {
    let asked = Asked()
    var f = DictationFeatures()
    (f.fidelityProbe, f.fidelityShadow) = (probe, shadow)
    var p = Pipeline(complete: { _, _, _, _ in reply },
                     vocabulary: VocabularyStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
                     cleanupModel: "s", editModel: "s", features: f)
    p.fidelityScore = { _, m in
        asked.messages.append(m)
        guard let score else { throw LLMError(description: "no score") }
        return score
    }
    return (await p.run(Request(transcript: said, selection: nil, context: ScreenSnapshot(text: screen))), asked)
}

@Test func fidelityProbeRejectsBelowThresholdWithTheFlag() async {
    let said = "can you send me the agenda by noon"
    let low = Pipeline.fidelityProbeThreshold - 0.5
    let (on, asked) = await dictate(said, reply: "Sure, I'll send the agenda by noon.", score: low, probe: true)
    #expect(on.outcome == .insert(said, label: "Dictated (raw)"))
    #expect(on.rejectedBy == "fidelityProbe" && on.fidelityScore == low && on.fidelitySeconds != nil)
    #expect(asked.messages.count == 1)
    let at = await dictate(said, reply: "Can you send me the agenda by noon?", score: Pipeline.fidelityProbeThreshold, probe: true).0
    #expect(at.outcome == .insert("Can you send me the agenda by noon?", label: "Dictated") && at.rejectedBy == nil)
}

@Test func fidelityShadowScoresWithoutActing() async {
    let (r, asked) = await dictate("can you send me the agenda by noon", reply: "Sure.", score: -20, shadow: true)
    #expect(r.outcome == .insert("Sure.", label: "Dictated") && r.rejectedBy == nil && r.fidelityScore == -20)
    #expect(asked.messages.count == 1)
}

@Test func fidelityProbeOffNeverAsks() async {
    let (r, asked) = await dictate("can you send me the agenda by noon", reply: "Sure.", score: -20)
    #expect(r.rejectedBy == nil && r.fidelityScore == nil && asked.messages.isEmpty)
}

@Test func fidelityProbeFailureKeepsTheReply() async {
    let (r, asked) = await dictate("can you send me the agenda by noon", reply: "Can you send me the agenda by noon?", score: nil, probe: true)
    #expect(r.outcome == .insert("Can you send me the agenda by noon?", label: "Dictated") && r.fidelityScore == nil)
    #expect(asked.messages.count == 1)
}

// A deterministic reject keeps its name; the probe is still scored, for the replay's overlap counts.
@Test func deterministicRejectComesFirstButProbeStillScores() async {
    let said = "the boxes go in the attic and the lamps go in the hallway closet by the stairs"
    let (r, _) = await dictate(said, reply: "The lamps.", score: -20, probe: true)
    #expect(r.rejectedBy == "dropsContent" && r.fidelityScore == -20)
}

// The probe sees the repaired reply, the pre-passed transcript and the level's rules.
@Test func fidelityCheckCarriesTranscriptReplyAndLevel() async {
    let (_, asked) = await dictate("so the ferry leaves at noon", reply: "<think>hm</think>So the ferry leaves at noon.", score: 0, shadow: true)
    let text = asked.messages.first?.map(\.content).joined(separator: "\n") ?? ""
    #expect(text.contains("<said>so the ferry leaves at noon</said>"))
    #expect(text.contains("<cleaned>So the ferry leaves at noon.</cleaned>") && !text.contains("think"))
    #expect(text.contains(Pipeline.fidelityLevelRules[.clean]!))
    for l in CleanupLevel.allCases {
        #expect(Pipeline.fidelityCheck(transcript: "a", reply: "b", level: l).map(\.content).joined().contains(Pipeline.fidelityLevelRules[l]!))
    }
}

@Test func fidelityProbeIsOffUnlessTheDefaultIsSet() {
    let d = UserDefaults(suiteName: "fidelity-\(UUID())")!
    #expect(!DictationFeatures(d, sources: ContextSources()).fidelityProbe)
    d.set(true, forKey: DictationFeatures.Key.fidelityProbe)
    #expect(DictationFeatures(d, sources: ContextSources()).fidelityProbe)
    #expect(!DictationFeatures(d, sources: ContextSources()).fidelityShadow)
}

// What PoptalkBench --fidelity-pairs scores the deterministic rejects with: the same first reject as `run`.
@Test func rejectedByMatchesRun() {
    #expect(Pipeline.rejectedBy(reply: "Okay.", transcript: "okay") == nil)
    #expect(Pipeline.rejectedBy(reply: "", transcript: "okay") == "empty")
    let screen = "Shared drive. Quarterly review deck, budget draft spreadsheet, offsite photos folder."
    #expect(Pipeline.rejectedBy(reply: "Quarterly review deck, budget draft spreadsheet.", transcript: "the slides are in the drive",
                                screen: screen) == "echoesContext")
}
