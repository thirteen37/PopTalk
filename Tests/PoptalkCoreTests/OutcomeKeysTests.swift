import Foundation
import Testing
@testable import PoptalkCore

private let esc: Int64 = 53, ret: Int64 = 36
private let command: UInt64 = 0x100000, option: UInt64 = 0x80000, capsLock: UInt64 = 0x10000

@Test func bareReturnAccepts() {
    #expect(OutcomeKeys.accepts(code: ret, flags: 0))
}

@Test func escPassesThrough() {
    #expect(!OutcomeKeys.accepts(code: esc, flags: 0))  // #109: undo is a right-⌥ double tap
    #expect(!OutcomeKeys.accepts(code: 0, flags: 0))
}

@Test func modifiedReturnPassesThrough() {
    #expect(!OutcomeKeys.accepts(code: ret, flags: command))
    #expect(!OutcomeKeys.accepts(code: ret, flags: option))
}

@Test func capsLockDoesNotCountAsModifier() {
    #expect(OutcomeKeys.accepts(code: ret, flags: capsLock))
}

@Test func undoWindowDefaultsAndClamps() {
    let d = UserDefaults(suiteName: "poptalk-test-\(UUID())")!
    #expect(OutcomeKeys.undoWindow(d) == 5)
    d.set(9, forKey: OutcomeKeys.undoWindowKey); #expect(OutcomeKeys.undoWindow(d) == 9)
    d.set(0, forKey: OutcomeKeys.undoWindowKey); #expect(OutcomeKeys.undoWindow(d) == 2)
    d.set(99, forKey: OutcomeKeys.undoWindowKey); #expect(OutcomeKeys.undoWindow(d) == 15)
}
