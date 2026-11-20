import Foundation
import Testing
@testable import PoptalkCore

// #40: each context source can be switched off in Settings; all on by default.
@Test func contextSourcesDefaultOnAndReadFromDefaults() {
    let d = UserDefaults(suiteName: "poptalk-test-\(UUID())")!
    #expect(ContextSources(d) == ContextSources())
    #expect(ContextSources().focusedText && ContextSources().nearbyText && ContextSources().ocr
        && ContextSources().windowTitle && ContextSources().screenVocabulary)
    d.set(false, forKey: ContextSources.Key.ocr)
    d.set(false, forKey: ContextSources.Key.windowTitle)
    let s = ContextSources(d)
    #expect(!s.ocr && !s.windowTitle && s.focusedText && s.nearbyText && s.screenVocabulary)
}

@Test func contextSourcesStripWindowTitleWhenOff() {
    let snap = ScreenSnapshot(appName: "Slack", windowTitle: "general (slack.com)", text: "hi", cursorOffset: 2, ocrText: "ocr")
    #expect(ContextSources().apply(snap) == snap)
    var off = ContextSources()
    off.windowTitle = false
    #expect(off.apply(snap) == ScreenSnapshot(appName: "Slack", text: "hi", cursorOffset: 2, ocrText: "ocr"))
}

@Test func boostTermsSkipScreenTermsWhenOffButKeepSaved() {
    let saved = [VocabTerm(text: "Poptalk")]
    let snap = ScreenSnapshot(text: "Ask Kubernetes about FluidAudio and FluidAudio again")
    #expect(Pipeline.boostTerms(saved: saved, context: snap).count > 1)
    #expect(Pipeline.boostTerms(saved: saved, context: snap, fromScreen: false).map(\.text) == ["Poptalk"])
}
