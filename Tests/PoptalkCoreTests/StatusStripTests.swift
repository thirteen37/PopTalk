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

@Test func stripShowsOCROffOrWarming() {
    var src = ContextSources()
    #expect(StatusStrip.badges(normal(), llm: .ready, sources: src, ocrWarm: false, history: false).map(\.symbol) == ["hourglass"])
    src.ocr = false
    #expect(StatusStrip.badges(normal(), llm: .ready, sources: src, ocrWarm: false, history: false).map(\.symbol) == ["text.viewfinder"])
}
