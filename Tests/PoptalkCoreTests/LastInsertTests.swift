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
    var deleted = last
    deleted.deletedAt = t0 + 3  // deleted (or sent, #95): nothing left to space after
    #expect(deleted.space(before: "Hi", into: "slack", now: t0 + 5) == "")
}

// #110: tap-then-hold edits the last insert only while its field is focused and its text as PopTalk left it.
@Test func editableInPlaceOnlyUntouchedInItsField() {
    var last = LastInsert(target: "slack", text: "hello", at: t0)
    #expect(!last.isUntouched(focused: "slack", value: "Hi hello"))  // field text never read
    last.fieldValue = "Hi hello"
    #expect(last.isUntouched(focused: "slack", value: "Hi hello"))
    #expect(!last.isUntouched(focused: "mail", value: "Hi hello"))
    #expect(!last.isUntouched(focused: nil, value: "Hi hello"))
    #expect(!last.isUntouched(focused: "slack", value: "Hi hello!"))
    #expect(!last.isUntouched(focused: "slack", value: nil))
}

// #130: a tap-then-hold edit that takes out a term the dictation's boost or casing fix wrote unlearns it.
@Test func unlearnedAreTheWrittenTermsAnEditTookOut() {
    var last = LastInsert(target: "notes", text: "I Install Quillmate on Yarrowly.")
    last.written = ["Install", "Quillmate", "Yarrowly"]
    #expect(last.unlearned(by: "I installed Quillmate on Yarrowly.") == ["Install"])
    #expect(last.unlearned(by: "I install Quillman on Yarrowly!") == ["Install", "Quillmate"])
    #expect(last.unlearned(by: "I Install Quillmate on Yarrowly today.").isEmpty)  // kept: nothing forgotten
    #expect(LastInsert(target: "notes", text: "I Install it.").unlearned(by: "I installed it.").isEmpty)  // wrote nothing
}
