import Foundation
import Testing
@testable import PoptalkCore

private let esc: Int64 = 53, ret: Int64 = 36
private let command: UInt64 = 0x100000, option: UInt64 = 0x80000, capsLock: UInt64 = 0x10000

@Test func bareEscUndoesAndBareReturnAccepts() {
    #expect(OutcomeKeys.action(code: esc, flags: 0, canUndo: true, canAccept: true) == .undo)
    #expect(OutcomeKeys.action(code: ret, flags: 0, canUndo: true, canAccept: true) == .accept)
}

@Test func modifiedKeysPassThrough() {
    #expect(OutcomeKeys.action(code: esc, flags: option | command, canUndo: true, canAccept: true) == nil)
    #expect(OutcomeKeys.action(code: ret, flags: command, canUndo: true, canAccept: true) == nil)
}

@Test func capsLockDoesNotCountAsModifier() {
    #expect(OutcomeKeys.action(code: esc, flags: capsLock, canUndo: true, canAccept: false) == .undo)
}

@Test func unavailableActionsPassThrough() {
    #expect(OutcomeKeys.action(code: esc, flags: 0, canUndo: false, canAccept: true) == nil)
    #expect(OutcomeKeys.action(code: ret, flags: 0, canUndo: true, canAccept: false) == nil)
    #expect(OutcomeKeys.action(code: 0, flags: 0, canUndo: true, canAccept: true) == nil)
}

@Test func undoWindowDefaultsAndClamps() {
    let d = UserDefaults(suiteName: "poptalk-test-\(UUID())")!
    #expect(OutcomeKeys.undoWindow(d) == 5)
    d.set(9, forKey: OutcomeKeys.undoWindowKey); #expect(OutcomeKeys.undoWindow(d) == 9)
    d.set(0, forKey: OutcomeKeys.undoWindowKey); #expect(OutcomeKeys.undoWindow(d) == 2)
    d.set(99, forKey: OutcomeKeys.undoWindowKey); #expect(OutcomeKeys.undoWindow(d) == 15)
}
