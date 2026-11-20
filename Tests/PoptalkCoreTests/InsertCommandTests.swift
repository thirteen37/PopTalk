import Foundation
import Testing
@testable import PoptalkCore

private let t0 = Date(timeIntervalSince1970: 1000)
private let last = "Let's meet on Tuesday at noon."

@Test func parsesDeleteCommands() {
    for s in ["scratch that", "Scratch that.", "Delete that!", "um, scratch that", "remove it", "undo that"] {
        #expect(InsertCommand(s, last: last) == .scratch, "\(s)")
    }
    #expect(InsertCommand("Delete the last word.", last: last) == .deleteLastWord)
    #expect(InsertCommand("delete last sentence", last: last) == .deleteLastSentence)
    #expect(InsertCommand("Remove the last sentence", last: last) == .deleteLastSentence)
}

@Test func parsesChangeCommands() {
    #expect(InsertCommand("No, I meant Wednesday.", last: last) == .change)
    #expect(InsertCommand("no I meant Wednesday", last: last) == .change)
    #expect(InsertCommand("Change Tuesday to Wednesday", last: last) == .change)
    #expect(InsertCommand("change tuesday to Wednesday.", last: last) == .change)  // case-insensitive find
}

@Test func lookAlikesStayDictation() {
    for s in ["I'll scratch that idea", "Scratch that idea.", "scratch that and start over tomorrow",
              "Delete that file from the server", "Please delete the last sentence of the draft",
              "I meant Wednesday", "No, I didn't mean that", "Change of plans to meet at noon",
              "Change Friday to Monday",  // Friday isn't in the last insert
              "change Tuesday to", "No, I meant", "", "scratch"] {
        #expect(InsertCommand(s, last: last) == nil, "\(s)")
    }
}

@Test func deleteRemainders() {
    #expect(InsertCommand.scratch.remainder(of: last) == "")
    #expect(InsertCommand.deleteLastWord.remainder(of: last) == "Let's meet on Tuesday at")
    #expect(InsertCommand.deleteLastWord.remainder(of: " Hello") == "")
    #expect(InsertCommand.deleteLastWord.remainder(of: " Hello there") == " Hello")
    #expect(InsertCommand.deleteLastSentence.remainder(of: " Hi there. How are you?") == " Hi there.")
    #expect(InsertCommand.deleteLastSentence.remainder(of: "One. Two! Three?  ") == "One. Two!")
    #expect(InsertCommand.deleteLastSentence.remainder(of: "Only one sentence") == "")
    #expect(InsertCommand.deleteLastWord.remainder(of: "...") == "")
    #expect(InsertCommand.change.remainder(of: last) == nil)
}

@Test func changedPartForOverlay() {
    #expect(InsertCommand.changed(from: last, to: "Let's meet on Wednesday at noon.") == "Wednesday")
    #expect(InsertCommand.changed(from: "Hi Bob", to: "Hi Bob and Ann") == "and Ann")
    #expect(InsertCommand.changed(from: "Hi Bob and Ann", to: "Hi Ann") == nil)  // only removed words
    #expect(InsertCommand.changed(from: "same", to: "same") == nil)
}

@Test func amendOnlyRecentUntouchedInsertInSameField() {
    let ins = LastInsert(target: "slack", text: "hello", at: t0, prefix: " ", fieldValue: "Hi hello")
    #expect(ins.canAmend(focused: "slack", value: "Hi hello", now: t0 + 30))
    #expect(!ins.canAmend(focused: "mail", value: "Hi hello", now: t0 + 30))
    #expect(!ins.canAmend(focused: nil, value: "Hi hello", now: t0 + 30))
    #expect(!ins.canAmend(focused: "slack", value: "Hi hello!", now: t0 + 30))  // edited since
    #expect(!ins.canAmend(focused: "slack", value: nil, now: t0 + 30))
    #expect(!ins.canAmend(focused: "slack", value: "Hi hello", now: t0 + 61))  // too late
    // Field text unread at insert time (or not a dictation): never amendable.
    #expect(!LastInsert(target: "slack", text: "hello", at: t0).canAmend(focused: "slack", value: nil, now: t0 + 1))
}
