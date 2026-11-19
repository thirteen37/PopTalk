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
