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
    // Straight quotes around the pre-pass's span get its curly ones back (#75).
    #expect(await dictate(said, reply: "I said \"Ship it today!\" and left.") == .insert("I said “Ship it today!” and left.", label: "Dictated"))
}

// #75: v3 straightens the pre-pass's curly quotes and moves a comma inside them; both are restored.
@Test func curlyQuotesAreRestored() async {
    #expect(await dictate("the error just says quote permission denied end quote and nothing else",
                          reply: "The error just says \"permission denied\" and nothing else.")
        == .insert("The error just says “permission denied” and nothing else.", label: "Dictated"))
    #expect(await dictate("I wanted to replace text and I said, quote, replace this with, unquote, and it was just put verbatim.",
                          reply: "I wanted to replace text and I said, \"replace this with,\" and it was just put verbatim.")
        == .insert("I wanted to replace text and I said, “replace this with”, and it was just put verbatim.", label: "Dictated"))
    // Quotes the transcript didn't have stay as the model wrote them.
    #expect(await dictate("she said quote yes unquote and he said no", reply: "She said “yes” and he said \"no.\"")
        == .insert("She said “yes” and he said \"no.\"", label: "Dictated"))
}

// #75: v3 flattens the pre-pass's line breaks; they go back between the same words instead of falling back.
@Test func lineBreaksAreRestored() async {
    #expect(await dictate("Hi team. New paragraph. The build is green and we ship tomorrow.",
                          reply: "Hi team. The build is green, and we ship tomorrow.")
        == .insert("Hi team.\n\nThe build is green, and we ship tomorrow.", label: "Dictated"))
    #expect(await dictate("Thanks for the quick review, new line, Bob", reply: "Thanks for the quick review, Bob.")
        == .insert("Thanks for the quick review,\nBob.", label: "Dictated"))
    // Breaks the model kept aren't doubled.
    #expect(await dictate("Thanks for the quick review, new line, Bob", reply: "Thanks for the quick review,\nBob.")
        == .insert("Thanks for the quick review,\nBob.", label: "Dictated"))
    // No place for the break (its neighbours changed): raw, as before.
    #expect(await dictate("Hi team. New paragraph. The build is green.", reply: "Hello everyone, the build is green.")
        == .insert("Hi team.\n\nThe build is green.", label: "Dictated (raw)"))
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
