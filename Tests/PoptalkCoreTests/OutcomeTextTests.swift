import Testing
@testable import PoptalkCore

@Test func outcomeCollapsesWhenTranscriptMatchesResult() {
    let l = OutcomeText.lines(heard: " hello world ", result: "hello world", label: "Dictated", edit: false)
    #expect(l == OutcomeLines(heard: nil, result: "hello world", label: "Dictated"))
}

@Test func outcomeShowsTranscriptAboveDictation() {
    let l = OutcomeText.lines(heard: "um send to do list", result: "Send to Todoist.", label: "Dictated", edit: false)
    #expect(l == OutcomeLines(heard: "um send to do list", result: "Send to Todoist.", label: "Dictated"))
}

@Test func outcomeMovesEditActionOntoResultLine() {
    let l = OutcomeText.lines(heard: "change it to todoist", result: "Todoist", label: "Corrected", edit: true)
    #expect(l == OutcomeLines(heard: "change it to todoist", result: "Corrected → Todoist", label: ""))
}

@Test func outcomeWithoutTranscriptKeepsLabelOnly() {
    #expect(OutcomeText.lines(heard: nil, result: nil, label: "Cleaned up", edit: false)
        == OutcomeLines(heard: nil, result: nil, label: "Cleaned up"))
}

@Test func outcomeTruncatesLongTextInTheMiddle() {
    let long = String(repeating: "a", count: 50) + String(repeating: "b", count: 50)
    let cut = OutcomeText.middle(long, limit: 21)
    #expect(cut == String(repeating: "a", count: 10) + "…" + String(repeating: "b", count: 10))
    #expect(OutcomeText.middle("short", limit: 21) == "short")
    let l = OutcomeText.lines(heard: long + "x", result: long, label: "Dictated", edit: false, limit: 21)
    #expect(l.heard?.count == 21 && l.result?.count == 21)
}
