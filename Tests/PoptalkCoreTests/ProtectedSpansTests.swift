import Foundation
import Testing
@testable import PoptalkCore

// #61: words inside ( … ), “ … ” and " … ", and line breaks, from the #48 pre-pass must survive cleanup.
private func dictate(_ transcript: String, reply: String) async -> Outcome {
    let p = Pipeline(complete: { _, _, _, _ in reply },
                     vocabulary: VocabularyStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
                     cleanupModel: "s", editModel: "b")
    return await p.run(Request(transcript: transcript, selection: nil, context: ScreenSnapshot())).outcome
}

@Test func droppedParentheticalFallsBackToRaw() async {
    let said = "the deadline open paren tentative close paren is next friday"
    #expect(await dictate(said, reply: "The deadline is next Friday.")
        == .insert("the deadline (tentative) is next friday", label: "Dictated (raw)"))
    #expect(await dictate(said, reply: "The deadline (Tentative) is next Friday.")
        == .insert("The deadline (Tentative) is next Friday.", label: "Dictated"))
}

@Test func quoteSpansAreProtected() async {
    let said = "I said quote ship it today unquote and left"
    #expect(await dictate(said, reply: "I said “ship it” and left.") == .insert("I said “ship it today” and left", label: "Dictated (raw)"))
    #expect(await dictate(said, reply: "I said \"Ship it today!\" and left.") == .insert("I said \"Ship it today!\" and left.", label: "Dictated"))
}

@Test func protectedSpanRule() {
    let drops = Pipeline.dropsProtected
    // Curly and straight quotes, either side, count as kept; so do case and punctuation changes.
    #expect(!drops("He said \"don't go.\"", "he said “don’t go”"))
    #expect(!drops("He said “Don’t go.”", "he said \"don't go\""))
    #expect(drops("He said “go.”", "he said “don’t go”"))
    // Words must stay together and in order.
    #expect(drops("Go, don't.", "he said “don't go”"))
    // Nothing protected → nothing to check.
    #expect(!drops("Hi.", "hi"))
    // Line breaks: fewer in the reply than in the transcript fall back.
    #expect(drops("Hi team. The build is green.", "hi team.\n\nThe build is green"))
    #expect(!drops("Hi team.\n\nThe build is green.", "hi team.\n\nThe build is green"))
}
