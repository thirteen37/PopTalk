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

@Test func dictationPromptContainsTranscriptAndContext() {
    let messages = Prompts.dictation(transcript: "on to-do list", context: snap("Todoist"), vocabulary: [])
    #expect(messages.last!.content.contains("on to-do list"))
    #expect(messages.last!.content.contains("Todoist"))
}
