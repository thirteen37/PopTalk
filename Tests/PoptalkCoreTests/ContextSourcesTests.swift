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

// #132: screen-word boosting is back on by default (off in #130), now that it can't swap real words.
@Test func screenVocabularyIsOnUnlessTurnedOff() {
    let d = UserDefaults(suiteName: "poptalk-test-\(UUID())")!
    #expect(ContextSources(d).screenVocabulary && ContextSources().screenVocabulary)
    d.set(false, forKey: ContextSources.Key.screenVocabulary)
    #expect(!ContextSources(d).screenVocabulary)
}

@Test func contextSourcesStripWindowTitleWhenOff() {
    let snap = ScreenSnapshot(appName: "Slack", windowTitle: "general (slack.com)", text: "hi", cursorOffset: 2, ocrText: "ocr")
    #expect(ContextSources().apply(snap) == snap)
    var off = ContextSources()
    off.windowTitle = false
    #expect(off.apply(snap) == ScreenSnapshot(appName: "Slack", text: "hi", cursorOffset: 2, ocrText: "ocr"))
}

// #96: the domain is its own source; off with the window title globally, as when it rode in the title.
@Test func webDomainFollowsTheWindowTitleGlobally() {
    let d = UserDefaults(suiteName: "poptalk-test-\(UUID())")!
    #expect(ContextSources(d).webDomain)
    d.set(false, forKey: ContextSources.Key.windowTitle)
    #expect(!ContextSources(d).webDomain)
    #expect(ContextSources(d).learnScreenTerms == ContextSources(d).rememberScreenTerms)
}

@Test func boostTermsSkipScreenTermsWhenOffButKeepSaved() {
    let saved = [VocabTerm(text: "Poptalk")]
    let snap = ScreenSnapshot(text: "Ask Kubernetes about FluidAudio and FluidAudio again")
    #expect(Pipeline.boostTerms(saved: saved, context: snap).count > 1)
    #expect(Pipeline.boostTerms(saved: saved, context: snap, fromScreen: false).map(\.text) == ["Poptalk"])
}
