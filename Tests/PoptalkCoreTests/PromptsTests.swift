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
