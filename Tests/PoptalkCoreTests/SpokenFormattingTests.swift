import Foundation
import Testing
@testable import PoptalkCore

// #48: spoken formatting commands, applied in code before the cleanup model.
private let f = Pipeline.spokenFormatting

@Test func quoteUnquoteBecomesCurlyQuotes() {
    #expect(f("I wanted to replace text and I said quote replace this with unquote and it was just put verbatim")
        == "I wanted to replace text and I said “replace this with” and it was just put verbatim")
    // Parakeet punctuates around the commands; the commas belong to the commands, not the quote.
    #expect(f("I said, quote, replace this with, unquote, and it was just put verbatim.")
        == "I said, “replace this with”, and it was just put verbatim.")
    #expect(f("Quote hello world end quote is the classic first program.") == "“hello world” is the classic first program.")
    #expect(f("she said quote yes unquote then quote no unquote") == "she said “yes” then “no”")
}

@Test func loneQuoteStaysLiteral() {
    #expect(f("the final quote from the printer") == "the final quote from the printer")
    #expect(f("Can you send me a quote by Friday?") == "Can you send me a quote by Friday?")
    #expect(f("end quote") == "end quote")
}

// #69: "quote and unquote" names the words; a body that is only a conjunction is a mention, not a command.
@Test func mentionedQuoteWordsStayLiteral() {
    #expect(f("one of my dictations had quote and unquote, but it got mangled")
        == "one of my dictations had quote and unquote, but it got mangled")
    #expect(f("I said the words quote and unquote.") == "I said the words quote and unquote.")
    #expect(f("Say quote, or end quote, to close it.") == "Say quote, or end quote, to close it.")
    #expect(f("Quote and unquote work, so quote hi unquote becomes curly.")
        == "Quote and unquote work, so “hi” becomes curly.")
    #expect(f("type open paren and close paren") == "type open paren and close paren")
    // A real body that happens to start or end with a conjunction is still a command.
    #expect(f("she said quote and then he left unquote") == "she said “and then he left”")
}

@Test func parensBecomeBrackets() {
    #expect(f("the deadline open paren tentative close paren is Friday") == "the deadline (tentative) is Friday")
    #expect(f("Ship it, open parenthesis, finally, close parenthesis.") == "Ship it, (finally).")
    #expect(f("open the paren file") == "open the paren file")
}

// Rule: "new line" / "new paragraph" is a command only as its own punctuation-delimited unit:
// right after the start, a newline or . ! ? , ; : and right before the end or one of those marks.
// The marks after it are dropped and the next letter is capitalized. Anything else is the noun.
@Test func lineBreaksAsStandaloneUnits() {
    #expect(f("Hi team. New paragraph. The build is green.") == "Hi team.\n\nThe build is green.")
    #expect(f("Thanks for the update, new line, Bob") == "Thanks for the update,\nBob")
    #expect(f("First point. New line. New line. Second point.") == "First point.\n\nSecond point.")
    #expect(f("New paragraph. Hello.") == "\n\nHello.")
    #expect(f("See you soon. New line") == "See you soon.\n")
    #expect(f("hi team, new paragraph, the build is green") == "hi team,\n\nThe build is green")
}

@Test func lineBreakNounsStayLiteral() {
    #expect(f("draw a new line on the chart") == "draw a new line on the chart")
    #expect(f("start a new paragraph in the doc") == "start a new paragraph in the doc")
    #expect(f("New line charts are better.") == "New line charts are better.")
    #expect(f("Add the new lines, then save.") == "Add the new lines, then save.")
    #expect(f("hi team new paragraph the build is green") == "hi team new paragraph the build is green")
}

private func dictate(_ transcript: String, reply: @escaping @Sendable ([ChatMessage]) -> String) async -> Outcome {
    let p = Pipeline(complete: { _, m, _, _ in reply(m) },
                     vocabulary: VocabularyStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
                     cleanupModel: "s", editModel: "b")
    return await p.run(Request(transcript: transcript, selection: nil, context: ScreenSnapshot())).outcome
}

@Test func modelSeesFormattedTranscriptAndGuardsKeepIt() async {
    let said = "I said, quote, replace this with, unquote, and it was just put verbatim. New paragraph. Thanks"
    let formatted = "I said, “replace this with”, and it was just put verbatim.\n\nThanks"
    // The model is handed the formatted text; echoing it back passes the length, echo and drop guards.
    let echo = await dictate(said) { m in
        m.last!.content.components(separatedBy: "<transcript>")[1].components(separatedBy: "</transcript>")[0]
    }
    #expect(echo == .insert(formatted, label: "Dictated"))
    // Straight quotes from the model pass the guards and get the curly ones back (#75).
    let straight = "I said \"replace this with\" and it was just put verbatim.\n\nThanks."
    #expect(await dictate(said) { _ in straight } == .insert("I said “replace this with” and it was just put verbatim.\n\nThanks.", label: "Dictated"))
    // The raw fallback is formatted as well.
    #expect(await dictate(said) { _ in "" } == .insert(formatted, label: "Dictated (raw)"))
}
