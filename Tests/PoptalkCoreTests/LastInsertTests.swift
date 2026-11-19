import Foundation
import Testing
@testable import PoptalkCore

private let t0 = Date(timeIntervalSince1970: 1000)

@Test func spaceAfterRecentInsertIntoSameField() {
    let last = LastInsert(target: "slack", text: "Hello world.", at: t0)
    #expect(last.space(before: "How are you?", into: "slack", now: t0 + 5) == " ")
}

@Test func noSpaceForOtherFieldStaleInsertOrSpacedText() {
    let last = LastInsert(target: "slack", text: "Hello world.", at: t0)
    #expect(last.space(before: "Hi", into: "mail", now: t0 + 5) == "")
    #expect(last.space(before: "Hi", into: "slack", now: t0 + 60) == "")
    #expect(last.space(before: " Hi", into: "slack", now: t0 + 5) == "")
    #expect(LastInsert(target: "slack", text: "Dear (", at: t0).space(before: "Hi", into: "slack", now: t0 + 5) == "")
    #expect(LastInsert(target: "slack", text: "Line\n", at: t0).space(before: "Hi", into: "slack", now: t0 + 5) == "")
}
