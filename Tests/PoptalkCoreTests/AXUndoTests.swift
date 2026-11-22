import Foundation
import Testing
@testable import PoptalkCore

private let t0 = Date(timeIntervalSince1970: 1000)
private let stamp = TerminalStamp(app: 42, keyDowns: 7)

private func beeper(_ text: String, prefix: String = "") -> LastInsert<String> {
    LastInsert(target: "composer", text: text, at: t0, prefix: prefix, axUndo: stamp)
}

@Test func axUndoAppsByBundleID() {
    #expect(AXUndo.contains("com.automattic.beeper.desktop"))
    #expect(!AXUndo.contains("com.tinyspeck.slackmacgap"))  // Electron, but its ⌘Z takes the paste back
    #expect(!AXUndo.contains("com.apple.TextEdit"))
    #expect(!AXUndo.contains(nil))
}

@Test func axUndoSelectsTheInsertAtTheCaret() {
    // "ok" also occurs earlier: the one ending at the caret is the paste. UTF-16 offsets, like AX ranges.
    let ins = beeper("ok 👍", prefix: " ")
    let value = "ok then ok 👍 more"
    let steps = ins.axUndoSteps(focused: "composer", value: value, caret: 13, frontmost: 42, keyDowns: 7, now: t0 + 2)
    #expect(steps == [.select(location: 7, length: 6), .backspaces(5)])
}

@Test func axUndoBackspacesOnlyWhenTheCaretIsAfterIt() {
    // Caret moved (a click): found as the only occurrence, but deleting backwards from the caret would hit other text.
    let ins = beeper("hello")
    let steps = ins.axUndoSteps(focused: "composer", value: "hello world", caret: 11, frontmost: 42, keyDowns: 7, now: t0 + 2)
    #expect(steps == [.select(location: 0, length: 5)])
}

@Test func axUndoRefusesWhenTheInsertIsGoneOrFocusMoved() {
    let ins = beeper("hello")
    // Edited since, or ambiguous: leave the field alone (no backspaces into text PopTalk didn't write).
    #expect(ins.axUndoSteps(focused: "composer", value: "help", caret: 4, frontmost: 42, keyDowns: 7, now: t0 + 2) == [])
    #expect(ins.axUndoSteps(focused: "composer", value: "hello hello", caret: 3, frontmost: 42, keyDowns: 7, now: t0 + 2) == [])
    #expect(ins.axUndoSteps(focused: "search", value: "hello", caret: 5, frontmost: 42, keyDowns: 7, now: t0 + 2) == [])
    #expect(ins.axUndoSteps(focused: nil, value: nil, caret: nil, frontmost: 42, keyDowns: 7, now: t0 + 2) == [])
}

@Test func axUndoFallsBackToBackspacesWhenTheFieldIsUnreadable() {
    let ins = beeper("café", prefix: " ")
    #expect(ins.axUndoSteps(focused: "composer", value: nil, caret: nil, frontmost: 42, keyDowns: 7, now: t0 + 2)
            == [.backspaces(5)])
    // The terminal guard: no key pressed since, same app frontmost, in time, no newline.
    #expect(ins.axUndoSteps(focused: "composer", value: nil, caret: nil, frontmost: 42, keyDowns: 8, now: t0 + 2) == [])
    #expect(ins.axUndoSteps(focused: "composer", value: nil, caret: nil, frontmost: 9, keyDowns: 7, now: t0 + 2) == [])
    #expect(ins.axUndoSteps(focused: "composer", value: nil, caret: nil, frontmost: 42, keyDowns: 7, now: t0 + 61) == [])
    #expect(beeper("one\ntwo").axUndoSteps(focused: "composer", value: nil, caret: nil, frontmost: 42, keyDowns: 7,
                                           now: t0 + 2) == [])
}

@Test func axUndoOnlyForStampedInserts() {
    // Not pasted into an `AXUndo` app: ⌘Z (or the terminal path) takes it back.
    let ins = LastInsert(target: "composer", text: "hello", at: t0)
    #expect(ins.axUndoSteps(focused: "composer", value: "hello", caret: 5, frontmost: 42, keyDowns: 7, now: t0 + 2) == [])
}
