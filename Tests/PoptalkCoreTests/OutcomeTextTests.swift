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

// #82: the overlay caps the outcome's height; `fit` cuts the middle until it fits, keeping start and end.
@Test func outcomeFitKeepsStartAndEnd() {
    #expect(OutcomeText.fit("short") { $0.count <= 11 } == "short")
    #expect(OutcomeText.fit("abcdefghijklmnopqrstuvwxyz") { $0.count <= 11 } == "abcde…vwxyz")
    let lines = (1...8).map(String.init).joined(separator: "\n")
    #expect(OutcomeText.fit(lines) { $0.split(separator: "\n").count <= 4 } == "1\n2…\n7\n8")
}

@Test func outcomeCutsTheMiddleBetweenWords() {
    #expect(OutcomeText.middle("one two three four five six", limit: 12) == "one… six")
}
