import Testing
@testable import PoptalkCore

@Test func findsProperNounsAndPhrases() {
    let terms = TermExtractor.terms(from: "Projects\nMeal Prep\nInbox. Open the Todoist app")
    #expect(terms.contains("Meal Prep"))
    #expect(terms.contains("Todoist"))
    #expect(terms.contains("Inbox"))
    #expect(!terms.contains("Open"))
    #expect(!terms.contains("the"))
}

@Test func findsCamelCaseAndIdentifiers() {
    let terms = TermExtractor.terms(from: "use FluidVoice and gpt-4o with snake_case")
    #expect(Set(terms) == ["FluidVoice", "gpt-4o", "snake_case"])
}

@Test func capsTermCount() {
    let text = (0..<1000).map { "word Name\(String(UnicodeScalar(65 + $0 % 26)!))\($0)x" }.joined(separator: " ")
    #expect(TermExtractor.terms(from: text, limit: 200).count == 200)
}

@Test func dedupesCaseInsensitively() {
    let terms = TermExtractor.terms(from: "see Todoist and TODOIST and todoist")
    #expect(terms.filter { $0.lowercased() == "todoist" }.count == 1)
}

@Test func ordersByFrequency() {
    let terms = TermExtractor.terms(from: "ask Alice. ask Bob, ask Bob again")
    #expect(terms.first == "Bob")
}
