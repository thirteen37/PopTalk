import Testing
@testable import PoptalkCore

private func normal() -> AppStatus {
    var s = AppStatus()
    s.speech = .ready
    s.granted = [.microphone, .accessibility, .screenRecording]
    s.hotkeyInstalled = true
    return s
}

@Test func stripIsEmptyWhenAllIsNormal() {
    #expect(StatusStrip.badges(normal(), llm: .ready, sources: ContextSources(), ocrWarm: true, history: false).isEmpty)
}

@Test func stripListsEachInactiveSubsystem() {
    var s = normal()
    s.speech = .loading
    s.granted = [.accessibility]
    var src = ContextSources()
    src.windowTitle = false
    src.nearbyText = false
    let b = StatusStrip.badges(s, llm: .downloading(0.5), sources: src, ocrWarm: true, history: true)
    #expect(b.map(\.symbol) == ["waveform.slash", "text.bubble", "lock", "eye.slash", "text.badge.xmark", "circle.fill"])
    #expect(b[1].help == "Language model downloading 50%: raw dictation")
    #expect(b[2].help == "Microphone permission missing")
    #expect(b[4].help == "Context off: nearby text, window title")
}

// #96: a profile that turns off every screen read shows one badge instead of each source.
@Test func stripSaysScreenReadingIsOffInThisApp() {
    var profiles: [AppProfile] = []
    AppProfiles.setScreenOff(true, bundleID: "com.example.Mail", in: &profiles)
    let r = AppProfiles.resolve(bundleID: "com.example.Mail", domain: nil, isPrivate: false, profiles: profiles,
                                defaults: ContextSources())
    let b = StatusStrip.badges(normal(), llm: .ready, sources: r.sources, ocrWarm: true, history: false, custom: r.custom)
    #expect(b == [StatusBadge(symbol: "eye.slash", help: "Screen reading off in this app")])
    var ocrOff = ContextSources()
    ocrOff.ocr = false
    #expect(StatusStrip.badges(normal(), llm: .ready, sources: ocrOff, ocrWarm: true, history: false, custom: true)
        .map(\.symbol) == ["text.viewfinder"])
}

@Test func stripShowsOCROffOrWarming() {
    var src = ContextSources()
    #expect(StatusStrip.badges(normal(), llm: .ready, sources: src, ocrWarm: false, history: false).map(\.symbol) == ["hourglass"])
    src.ocr = false
    #expect(StatusStrip.badges(normal(), llm: .ready, sources: src, ocrWarm: false, history: false).map(\.symbol) == ["text.viewfinder"])
}
