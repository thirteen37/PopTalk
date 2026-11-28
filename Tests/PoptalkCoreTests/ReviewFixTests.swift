import Foundation
import Testing
@testable import PoptalkCore

// Review #3: extraction must be linear and only see the capped context.
// Compares 10x the input against its time (best of 3), so machine load doesn't matter:
// linear scales ~10x, the old quadratic look-back scaled ~100x.
@Test func extractionIsFastOnLongSingleLine() {
    func best(_ n: Int) -> Double {
        let line = (0..<n).map { "word Name\($0)x" }.joined(separator: " ")
        return (0..<3).map { _ in
            let start = Date()
            _ = TermExtractor.terms(from: line)
            return Date().timeIntervalSince(start)
        }.min()!
    }
    let small = best(2_000), large = best(20_000)
    #expect(large / small < 40, "10x input took \(large / small)x the time")
}

@Test func boostTermsUseCappedContext() {
    let far = "Farawayterm " + String(repeating: "a ", count: 5_000) + " near Todoist"
    let snap = ScreenSnapshot(text: far)  // no cursor → tail kept
    let terms = Pipeline.boostTerms(saved: [VocabTerm(text: "FluidVoice")], context: snap).map(\.text)
    #expect(terms.first == "FluidVoice")
    #expect(terms.contains("Todoist"))
    #expect(!terms.contains("Farawayterm"))
}

@Test func boostTermsSkipSavedDuplicates() {
    let terms = Pipeline.boostTerms(saved: [VocabTerm(text: "Todoist", aliases: ["todo list"])],
                                    context: ScreenSnapshot(text: "open Todoist")).map(\.text)
    #expect(terms == ["Todoist"])
}

// Review #1: accidental taps and silence do nothing.
@Test func audioGateRejectsShortAudio() {
    #expect(!AudioGate.hasSpeech([Float](repeating: 0.2, count: 16_000 / 4)))
}

@Test func audioGateRejectsSilence() {
    #expect(!AudioGate.hasSpeech([Float](repeating: 0.0005, count: 16_000)))
}

@Test func audioGateAcceptsSpeechLevelAudio() {
    let tone = (0..<16_000).map { Float(sin(Double($0) * 0.1) * 0.1) }
    #expect(AudioGate.hasSpeech(tone))
}

// Review #7 + thinking models: never paste model chatter.
private func dictate(_ reply: String, transcript: String = "send me the report", context: ScreenSnapshot = ScreenSnapshot()) async -> Outcome {
    let p = Pipeline(complete: { _, _, _, _ in reply },
                     vocabulary: VocabularyStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
                     cleanupModel: "s", editModel: "b")
    return await p.run(Request(transcript: transcript, selection: nil, context: context)).outcome
}

@Test func cleanupStripsThinkBlocksAndTags() async {
    #expect(await dictate("<think>user wants…</think>\n<transcript>Send me the report.</transcript>")
        == .insert("Send me the report.", label: "Dictated"))
    // Qwen3 with thinking off (#68): an empty block if the model re-emits it.
    #expect(await dictate("<think>\n\n</think>\n\nSend me the report.") == .insert("Send me the report.", label: "Dictated"))
}

@Test func cleanupChatterFallsBackToRaw() async {
    let chatter = "Sure! Here is the report you asked for. I have attached the quarterly figures and a summary of the key findings below."
    #expect(await dictate(chatter) == .insert("send me the report", label: "Dictated (raw)"))
}

@Test func editParserSkipsThinkBlock() throws {
    let raw = #"<think>maybe {"action":"edit"}?</think>{"action":"correct","text":"Todoist","vocabulary":null,"remember":false}"#
    #expect(try LLMClient.parseEditResult(raw).text == "Todoist")
}

// Review #8: consecutive dictations get a separating space.
@Test func dictationAddsSpaceAfterText() async {
    let ctx = ScreenSnapshot(text: "Hello world.", cursorOffset: 12)
    #expect(await dictate("How are you?", transcript: "how are you", context: ctx) == .insert(" How are you?", label: "Dictated"))
}

@Test func dictationNoSpaceAfterWhitespaceOrBracket() async {
    #expect(await dictate("Hi.", transcript: "hi", context: ScreenSnapshot(text: "Hello ", cursorOffset: 6)) == .insert("Hi.", label: "Dictated"))
    #expect(await dictate("Hi.", transcript: "hi", context: ScreenSnapshot(text: "(", cursorOffset: 1)) == .insert("Hi.", label: "Dictated"))
    #expect(await dictate("Hi.", transcript: "hi", context: ScreenSnapshot(text: "Hello")) == .insert("Hi.", label: "Dictated"))
}

@Test func rawFallbackAlsoGetsSpace() async {
    let p = Pipeline(complete: { _, _, _, _ in throw LLMError(description: "down") },
                     vocabulary: VocabularyStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
                     cleanupModel: "s", editModel: "b")
    let r = await p.run(Request(transcript: "hi", selection: nil, context: ScreenSnapshot(text: "Hello.", cursorOffset: 6)))
    #expect(r.outcome == .insert(" hi", label: "Dictated (raw)"))
}

// Hesitation sounds are never content: strip them even when the LLM is unavailable.
@Test func rawFallbackStripsHesitations() async {
    let p = Pipeline(complete: { _, _, _, _ in throw LLMError(description: "down") },
                     vocabulary: VocabularyStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
                     cleanupModel: "s", editModel: "b")
    let r = await p.run(Request(transcript: "Um, so we need to uh ship this, er, by Friday. Hmm.", selection: nil, context: ScreenSnapshot()))
    #expect(r.outcome == .insert("So we need to ship this, by Friday.", label: "Dictated (raw)"))
}

@Test func hesitationStripKeepsRealWords() {
    #expect(Pipeline.stripHesitations("I like the umbrella and the Uhuru park") == "I like the umbrella and the Uhuru park")
    #expect(Pipeline.stripHesitations("uh") == "")
}

// #135: all-caps acronyms and "err" are words; a trailing % or # is content.
@Test(arguments: [
    "We took him to the ER last night.",
    "I'd rather err on the side of caution.",
    "She studied at UM for two years.",
    "Revenue is up 25%",
    "I wrote it in C#",
])
func hesitationStripKeepsWordsAndMarks(_ said: String) {
    #expect(Pipeline.stripHesitations(said) == said)
}

@Test(arguments: ["er", "erm", "errr", "um", "umm", "uh"])
func hesitationStripDropsLowercaseSounds(_ h: String) {
    #expect(Pipeline.stripHesitations("\(h), we should ship it.") == "we should ship it.")
    #expect(Pipeline.stripHesitations("we should \(h) ship it today.") == "we should ship it today.")
}

// A trailing ellipsis survives the trim (#135) and closes up like other end marks.
@Test func hesitationStripClosesUpEllipsis() {
    #expect(Pipeline.stripHesitations("and then um…") == "and then…")
}
