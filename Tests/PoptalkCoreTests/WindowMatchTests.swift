import CoreGraphics
import Testing
@testable import PoptalkCore

private let back = (frame: CGRect(x: 0, y: 0, width: 800, height: 600), title: "Inbox")
private let front = (frame: CGRect(x: 100, y: 50, width: 900, height: 700), title: "Draft")

@Test func picksWindowMatchingFocusedFrame() {
    #expect(WindowMatch.index(of: [back, front], frame: front.frame, title: "Other") == 1)
}

@Test func fallsBackToTitleWhenNoFrameMatches() {
    #expect(WindowMatch.index(of: [back, front], frame: nil, title: "Draft") == 1)
}

@Test func fallsBackToFirstWindow() {
    #expect(WindowMatch.index(of: [back, front], frame: nil, title: nil) == 0)
    #expect(WindowMatch.index(of: [], frame: nil, title: nil) == nil)
}
