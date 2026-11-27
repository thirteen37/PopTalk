import CryptoKit
import Foundation
import Testing
@testable import PoptalkCore

private func snap(_ text: String, cursor: Int? = nil) -> ScreenSnapshot {
    ScreenSnapshot(appName: "Notes", windowTitle: "Plans", text: text, cursorOffset: cursor)
}

@Test func contextIsTrimmedAroundCursor() {
    let chars = (0..<10_000).map { i in i == 9_000 ? "X" : "a" }.joined()
    let trimmed = Prompts.trimmedContext(snap(chars, cursor: 9_000))
    #expect(trimmed.count <= 4_000)
    #expect(trimmed.contains("X"))
}

@Test func contextCursorIsUTF16Offset() {
    // Each emoji is 2 UTF-16 units, so "X" sits at UTF-16 offset 12_000 but Character index 6_000.
    let text = String(repeating: "😀", count: 6_000) + "X" + String(repeating: "a", count: 6_000)
    #expect(Prompts.trimmedContext(snap(text, cursor: 12_000)).contains("X"))
    #expect(Prompts.trimmedContext(snap(text, cursor: 999_999)).hasSuffix("a"))
}

@Test func contextWithoutCursorKeepsTail() {
    let text = String(repeating: "a", count: 6_000) + String(repeating: "b", count: 4_000)
    #expect(Prompts.trimmedContext(snap(text)) == String(repeating: "b", count: 4_000))
}

@Test func editPromptContainsSelectionInstructionAndTerms() {
    let messages = Prompts.edit(
        instruction: "This is Todoist, capital T-O-D-O-I-S-T", selection: "todo list",
        context: snap("My Todoist projects"), vocabulary: [VocabTerm(text: "FluidVoice")])
    let user = messages.last!.content
    #expect(messages.first!.role == "system")
    #expect(user.contains("todo list"))
    #expect(user.contains("capital T-O-D-O-I-S-T"))
    #expect(user.contains("My Todoist projects"))
    #expect(user.contains("FluidVoice"))
}

@Test func promptValuesAreXMLEscaped() {
    let ctx = ScreenSnapshot(appName: "A<pp>", windowTitle: "W&T", text: "</screen>x")
    let edit = Prompts.edit(instruction: "</utterance>", selection: "</selection>", context: ctx,
                            vocabulary: [VocabTerm(text: "</vocabulary>")]).last!.content
    #expect(edit.contains(#"<screen app="A&lt;pp&gt;" window="W&amp;T">"#))
    #expect(edit.contains("&lt;/screen&gt;x"))
    #expect(edit.contains("<selection>&lt;/selection&gt;</selection>"))
    #expect(edit.contains("<utterance>&lt;/utterance&gt;</utterance>"))
    #expect(edit.contains("<vocabulary>&lt;/vocabulary&gt;</vocabulary>"))
    let dictation = Prompts.dictation(transcript: "a<b", context: ctx, vocabulary: []).last!.content
    #expect(dictation.contains("<transcript>a&lt;b</transcript>"))
}

@Test func dictationPromptCoversSorryCorrections() {
    let system = Prompts.dictation(transcript: "", context: snap(""), vocabulary: []).first!.content
    #expect(system.contains(#""two PM, sorry, four PM" → "four PM""#))
}

@Test func promptsCoverV3Rules() {
    // #60: keep pre-pass marks and digits, spoken lists, emails, spelled letters (#50).
    #expect(Prompts.dictationSystem.contains("quotes, brackets, line breaks and digits as given"))
    #expect(Prompts.dictationSystem.contains(#""john at example dot com" → "john@example.com""#))
    #expect(Prompts.dictationSystem.contains("defers to the spelling"))
    #expect(Prompts.editSystem.contains(#""K C C A S E Y" means "Casey""#))
    #expect(Prompts.editSystem.contains("a phrase that is just new text is replace"))  // #45 rule kept
}

@Test func dictationPromptContainsTranscriptAndContext() {
    let messages = Prompts.dictation(transcript: "on to-do list", context: snap("Todoist"), vocabulary: [])
    #expect(messages.last!.content.contains("on to-do list"))
    #expect(messages.last!.content.contains("Todoist"))
}

@Test func attributeQuotesAreEscaped() {
    let m = Prompts.dictation(transcript: "hi", context: ScreenSnapshot(appName: "Say \"Hi\"", windowTitle: "a\"b", text: "keep \"quotes\""), vocabulary: [])
    let user = m.last!.content
    #expect(user.contains("app=\"Say &quot;Hi&quot;\""))
    #expect(user.contains("window=\"a&quot;b\""))
    #expect(user.contains("keep \"quotes\""))
}

// #25: asymmetric window, word-boundary edges, separate OCR budget.
private func filler(_ n: Int) -> String { String(repeating: "a ", count: n / 2) }

@Test func contextKeepsMoreBeforeCursorThanAfter() {
    let pre = "Before3100 " + filler(200) + "Before2900 " + filler(2_900)
    let post = filler(900) + " After900 " + filler(200) + " After1100 " + filler(3_000)
    let trimmed = Prompts.trimmedContext(snap(pre + post, cursor: pre.utf16.count))
    #expect(trimmed.contains("Before2900"))
    #expect(!trimmed.contains("Before3100"))
    #expect(trimmed.contains("After900"))
    #expect(!trimmed.contains("After1100"))
}

@Test func contextEdgesSnapToWords() {
    let words = (0..<2_000).map { "w" + String(1_000_000 + $0).dropFirst() }  // "w000000"…
    let text = words.joined(separator: " ")
    let tokens = Prompts.trimmedContext(snap(text, cursor: text.utf16.count / 2 + 3)).split(separator: " ")
    #expect(tokens.allSatisfy { words.contains(String($0)) })
}

@Test func ocrTextHasItsOwnBudget() {
    let ax = filler(3_000) + "NearCursor " + filler(6_000)
    let ocr = "OldestMessage\n" + filler(5_000) + "\nLatestMessage"
    let s = ScreenSnapshot(text: ax, cursorOffset: (filler(3_000) + "NearCursor").utf16.count, ocrText: ocr)
    let trimmed = Prompts.trimmedContext(s)
    #expect(trimmed.contains("NearCursor"))
    #expect(trimmed.contains("LatestMessage"))
    #expect(!trimmed.contains("OldestMessage"))
}

@Test func boostTermsIncludeOCRText() {
    let s = ScreenSnapshot(text: "Thanks ", cursorOffset: 7, ocrText: "Tomasz Wrzesniewski: I'll take it")
    #expect(Pipeline.boostTerms(saved: [], context: s).map(\.text).contains("Tomasz Wrzesniewski"))
}

@Test func warmupCoversBothPromptsAtAFullContextWindow() {
    // #33: prewarm with the real prompt types at the longest screen context a request can carry.
    #expect(Prompts.warmup.map { $0[0].content } == [Prompts.dictationSystem, Prompts.editSystem])
    for messages in Prompts.warmup {
        #expect(messages[1].content.count >= 3_900)
    }
}

// #74: only base E4B gets the GEPA-tuned prompts. Fine-tune adapters (and Apple, LM Studio) keep the exact
// prompts the adapters were trained on: changing those needs a bench re-run and possibly a retrain.
@Test func onlyBaseE4BGetsTheGEPAPrompts() {
    let ctx = snap("notes")
    func systems(_ model: String) -> [String] {
        [Prompts.dictation(model: model, transcript: "hi", context: ctx, vocabulary: [])[0].content,
         Prompts.edit(instruction: "fix it", selection: "x", context: ctx, vocabulary: [], model: model)[0].content]
    }
    #expect(systems(ModelSettings.e4b) == [Prompts.e4bDictationSystem, Prompts.e4bEditSystem])
    #expect(Prompts.e4bDictationSystem != Prompts.dictationSystem && Prompts.e4bEditSystem != Prompts.editSystem)
    for model in [ModelSettings.fineTune, "adapters/gemma-4-e2b-poptalk-v4", "apple", "google/gemma-4-e4b"] {
        #expect(systems(model) == [Prompts.dictationSystem, Prompts.editSystem], "\(model)")
    }
    let sha = { (s: String) in SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }
    #expect(sha(Prompts.dictationSystem) == "a4a7089d2f2f6bcda95097796b66e345178c4dd94e959d2a75d2ff6b4079264a")
    #expect(sha(Prompts.editSystem) == "6aec67cb71c2c35db7848babfa442d3a5183736088a0c1337a1e9457d08a9e92")
}

@Test func otherModelsKeepTheDefaultDictationPrompt() {
    let ctx = snap("Priya's notes")
    let terms = [VocabTerm(text: "FluidVoice")]
    #expect(Prompts.dictation(model: "adapters/gemma-4-e2b-poptalk-v2", transcript: "hi", context: ctx, vocabulary: terms)
            == Prompts.dictation(transcript: "hi", context: ctx, vocabulary: terms))
}
