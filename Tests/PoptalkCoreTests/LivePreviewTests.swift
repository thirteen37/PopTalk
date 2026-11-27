import Foundation
import Testing
@testable import PoptalkCore

// #131 follow-up: once Shift is seen, the recording footer says the hold goes in raw, ahead of the edit note; it
// replaces the degraded mode's own "raw — …" note rather than repeating it.
@Test func rawNoteLeadsTheFooter() {
    #expect(LivePreview.rawNote(nil) == "Raw — no cleanup")
    #expect(LivePreview.rawNote("Editing the last insert") == "Raw — no cleanup · Editing the last insert")
    #expect(LivePreview.rawNote("raw — model loading") == "Raw — no cleanup")
    #expect(LivePreview.rawNote(LivePreview.rawNote(nil)) == "Raw — no cleanup")
}

// #43: speculative cleanup while the key is held.

private func words(_ s: String, _ ranges: [Range<String.Index>]) -> [String] { ranges.map { String(s[$0]) } }

@Test func wordDiffMarksRemovedAndAddedWords() {
    let raw = "um so the fluid audio build is uh ready"
    let clean = "So the FluidAudio build is ready."
    let d = WordDiff.changes(raw, clean)
    #expect(words(raw, d.removed) == ["um", "fluid", "audio", "uh"])
    #expect(words(clean, d.added) == ["FluidAudio"])
}

@Test func wordDiffIgnoresPunctuationAndSentenceCapitals() {
    let raw = "hello world. and then we go"
    let clean = "Hello world, and then we go."
    let d = WordDiff.changes(raw, clean)
    #expect(d.removed.isEmpty)
    #expect(d.added.isEmpty)
}

@Test func wordDiffMarksRecasingAndSelfCorrections() {
    // Mid-sentence recasing counts; a self-correction strikes the old words and marks the new one.
    let raw = "meet me at github on tuesday no wednesday"
    let clean = "Meet me at GitHub on Wednesday."
    let d = WordDiff.changes(raw, clean)
    #expect(words(raw, d.removed) == ["github", "tuesday", "no", "wednesday"])
    #expect(words(clean, d.added) == ["GitHub", "Wednesday."])
}

@Test func shownDictationTrimsSpacingAndMarksChanges() {
    let r = PipelineResult(outcome: .insert(" So the FluidAudio build.", label: "Dictated"))
    let s = LivePreview.shown(r, input: "um so the fluid audio build", selection: nil)!
    #expect(s.act == nil)
    #expect(s.text == "So the FluidAudio build.")
    #expect(words(s.text, s.marks) == ["FluidAudio"])
    #expect(words("um so the fluid audio build", s.rawMarks) == ["um", "fluid", "audio"])
}

@Test func shownEditNamesThePlannedAction() {
    let r = PipelineResult(outcome: .replaceSelection("Todoist", label: "Corrected"))
    let s = LivePreview.shown(r, input: "correct to todoist", selection: "todo list")!
    #expect(s.act == "Correct →")
    #expect(s.text == "Todoist")
    #expect(s.marks.isEmpty)  // nothing kept from the selection: no highlight
    #expect(s.rawMarks.isEmpty)
    let e = LivePreview.shown(PipelineResult(outcome: .replaceSelection("Ship it on Friday.", label: "Edited")),
                              input: "make it friday", selection: "Ship it on Monday.")!
    #expect(e.act == "Edit →")
    #expect(words(e.text, e.marks) == ["Friday."])
    #expect(LivePreview.shown(PipelineResult(outcome: .insertAfter(" Thanks.")), input: "add thanks", selection: "Hi.")?.act
            == "Insert after →")
    #expect(LivePreview.shown(PipelineResult(outcome: .nothing), input: "hmm", selection: "Hi.")?.act == "No change")
    #expect(LivePreview.shown(PipelineResult(outcome: .error("Model took too long")), input: "x", selection: "Hi.") == nil)
}

@Test func runsOnAPauseWithNewWordsOnly() {
    // New words and a quiet tail (or no change since the last tick): run.
    #expect(LivePreview.shouldRun("hello there", lastRun: "hello", previous: "hello", paused: true, edit: false))
    #expect(LivePreview.shouldRun("hello there", lastRun: "hello", previous: "hello there", paused: false, edit: false))
    // Still talking.
    #expect(!LivePreview.shouldRun("hello there", lastRun: "hello", previous: "hello", paused: false, edit: false))
    // Already ran on this text.
    #expect(!LivePreview.shouldRun("hello there", lastRun: "hello there", previous: "hello there", paused: true, edit: false))
    // Edits wait for a few words.
    #expect(!LivePreview.shouldRun("make this", lastRun: nil, previous: nil, paused: true, edit: true))
    #expect(LivePreview.shouldRun("make it formal", lastRun: nil, previous: nil, paused: true, edit: true))
}

@Test func pauseIsAQuietTail() {
    let speech = (0 ..< 16_000).map { Float(sin(Double($0) / 5)) * 0.1 }
    let quiet = [Float](repeating: 0.001, count: 6_000)
    #expect(LivePreview.paused(speech + quiet))
    #expect(!LivePreview.paused(quiet + speech))
    #expect(!LivePreview.paused([Float](repeating: 0, count: 1_000)))  // shorter than the window
}

@Test func reusesOnlyAMatchingCleanResult() {
    let ctx = ScreenSnapshot(appName: "Notes", text: "hi")
    let ran = Request(transcript: "hello there", selection: nil, context: ctx)
    #expect(LivePreview.sameInput(ran, Request(transcript: "hello there", selection: nil, context: ctx)))
    #expect(!LivePreview.sameInput(ran, Request(transcript: "hello there friend", selection: nil, context: ctx)))
    #expect(!LivePreview.sameInput(ran, Request(transcript: "hello there", selection: "x", context: ctx)))
    #expect(!LivePreview.sameInput(ran, Request(transcript: "hello there", selection: nil, context: ScreenSnapshot())))

    let ok = PipelineResult(outcome: .insert("Hello there.", label: "Dictated"))
    #expect(LivePreview.reusable(ok) == ok)
    #expect(LivePreview.reusable(nil) == nil)  // cancelled
    #expect(LivePreview.reusable(PipelineResult(outcome: .insert("hello there", label: "Dictated (raw)"), degraded: true)) == nil)
    #expect(LivePreview.reusable(PipelineResult(outcome: .error("Model took too long"))) == nil)
    #expect(LivePreview.reusable(PipelineResult(outcome: .insert("hello there", label: "Dictated (raw)"))) == nil)
    // Only the final run saves vocabulary, so a "remember" edit runs again.
    #expect(LivePreview.reusable(PipelineResult(outcome: .replaceSelection("Todoist", label: "Corrected"),
                                                remembered: VocabTerm(text: "Todoist"))) == nil)
}

@Test func speculativeEditNeverSavesVocabulary() async {
    let store = VocabularyStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
    let reply = #"{"action":"correct","text":"Todoist","vocabulary":{"text":"Todoist","aliases":["todo list"]},"remember":true}"#
    var p = Pipeline(complete: { _, _, _, _ in reply }, vocabulary: store, cleanupModel: "s", editModel: "b")
    p.remembers = false
    let r = await p.run(Request(transcript: "Todoist, remember this", selection: "todo list", context: ScreenSnapshot()))
    #expect(r.remembered?.text == "Todoist")
    #expect(store.terms.isEmpty)
}

@Test func livePreviewSettingDefaultsOn() {
    let d = UserDefaults(suiteName: UUID().uuidString)!
    #expect(LivePreview.enabled(d))
    d.set(false, forKey: LivePreview.key)
    #expect(!LivePreview.enabled(d))
}

@Test func sparklesSweepEachNewWordOncePerPress() {
    func r(_ t: String, _ w: String) -> NSRange { NSRange(t.range(of: w)!, in: t) }
    var s = LivePreview.Sparkles()
    let a = "Meet at GitHub on Wednesday."
    let first = s.sweeping([r(a, "GitHub"), r(a, "Wednesday.")], in: a, now: 10)
    #expect(first.map(\.range) == [r(a, "GitHub"), r(a, "Wednesday.")])
    #expect(first.map(\.start) == [10, 10 + LivePreview.Sparkles.stagger])  // staggered
    // A later partial moves them: they carry on from their start rather than restart.
    let b = "So meet at GitHub on Wednesday. And"
    let mid = s.sweeping([r(b, "GitHub"), r(b, "Wednesday.")], in: b, now: 10.3)
    #expect(mid.map(\.range) == [r(b, "GitHub"), r(b, "Wednesday.")])
    #expect(mid.map(\.start) == first.map(\.start))
    // Once swept, never again this press; a newly marked word starts now.
    let c = b + " TestFlight"
    let late = s.sweeping([r(c, "GitHub"), r(c, "TestFlight")], in: c, now: 11)
    #expect(late.map(\.range) == [r(c, "TestFlight")])
    #expect(late.map(\.start) == [11])
}
