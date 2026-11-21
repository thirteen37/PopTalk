import Testing
@testable import PoptalkCore

@Test func previewKeepsShortTextWhole() {
    #expect(PreviewText.tail("hello world", limit: 20) == "hello world")
}

@Test func previewKeepsTailAtWordBoundary() {
    #expect(PreviewText.tail("one two three four five", limit: 12) == "…four five")
}

@Test func previewCutsAnUnbrokenWord() {
    #expect(PreviewText.tail("abcdefghij", limit: 4) == "…ghij")
}

// #82: a line break is a word boundary too.
@Test func previewCutsAtALineBreak() {
    #expect(PreviewText.tail("Thanks.\n\nCheers,\nGurpreet", limit: 12) == "…Gurpreet")
    #expect(PreviewText.tail("Thanks.\nGurpreet", limit: 8) == "…Gurpreet")
}
