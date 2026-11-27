import Testing
@testable import PoptalkCore

private func texts(_ text: String, cursor: Int? = nil, title: String = "", limit: Int = 60) -> [String] {
    TermExtractor.terms(from: text, cursor: cursor, title: title, limit: limit).map(\.text)
}

@Test func findsProperNounsAndPhrases() {
    let terms = texts("Projects\nMeal Prep\nInbox. Open the Todoist app")
    #expect(terms.contains("Meal Prep"))
    #expect(terms.contains("Todoist"))
    #expect(terms.contains("Inbox"))
    #expect(!terms.contains("Open"))
    #expect(!terms.contains("the"))
}

@Test func findsCamelCaseAndIdentifiers() {
    let terms = texts("use FluidVoice and gpt-4o with snake_case")
    #expect(Set(terms) == ["FluidVoice", "gpt-4o", "snake_case"])
}

@Test func capsTermCount() {
    let text = (0..<1000).map { "word Name\(String(UnicodeScalar(65 + $0 % 26)!))\($0)x" }.joined(separator: " ")
    #expect(texts(text, limit: 200).count == 200)
    #expect(texts(text).count == 60)  // #26: default cap
}

@Test func dedupesCaseInsensitively() {
    let terms = texts("see Todoist and TODOIST and todoist")
    #expect(terms.filter { $0.lowercased() == "todoist" }.count == 1)
}

@Test func ordersByFrequency() {
    let terms = texts("ask Alice. ask Bob, ask Bob again")
    #expect(terms.first == "Bob")
}

// #26: rank by distance from the cursor, window title and frequency.
@Test func nearCursorOutranksFrequentFar() {
    let far = String(repeating: "see Farley. ", count: 5)
    let text = far + String(repeating: "a ", count: 1_500) + "ping Nearby"
    let terms = TermExtractor.terms(from: text, cursor: text.utf16.count)
    #expect(terms.map(\.text) == ["Nearby", "Farley"])
}

@Test func cursorIsUTF16Offset() {
    // Read as a Character index, the cursor would land nearer "Other".
    let pre = String(repeating: "😀 ", count: 2_000) + "ping Nearby "
    let text = pre + String(repeating: "😀 ", count: 1_500) + "ping Other"
    #expect(texts(text, cursor: pre.utf16.count).first == "Nearby")
}

@Test func windowTitleTermsComeFirst() {
    let text = (0..<100).map { "word Name\($0)x" }.joined(separator: " ")
    #expect(texts(text, title: "Quarterly Zephyr Review").first == "Quarterly Zephyr Review")
}

@Test func boostTermsAreRankedAndCapped() {
    let text = (0..<200).map { "word Name\($0)x" }.joined(separator: " ")
    let terms = Pipeline.boostTerms(saved: [VocabTerm(text: "FluidVoice")],
                                    context: ScreenSnapshot(text: text, cursorOffset: 0))
    #expect(terms.first == VocabTerm(text: "FluidVoice", aliases: ["fluid voice"]))
    #expect(terms.count == 61)
    #expect(terms[1].text == "Name0x")
}
