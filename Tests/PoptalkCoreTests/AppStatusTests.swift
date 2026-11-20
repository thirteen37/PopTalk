import Testing
@testable import PoptalkCore

@Test func versionLabelFromInfoPlist() {
    #expect(versionLabel(["CFBundleShortVersionString": "0.1", "CFBundleVersion": "412", "PoptalkCommit": "9b4cc05-dirty"])
        == "Poptalk 0.1 (412 · 9b4cc05-dirty)")
    #expect(versionLabel(["CFBundleShortVersionString": "0.1"]) == "Poptalk 0.1")
    #expect(versionLabel(nil) == "Poptalk (development build)")
}

private func ok() -> AppStatus {
    var s = AppStatus()
    s.speech = .ready
    s.models = ["a": .ready, "b": .ready]
    s.granted = [.microphone, .accessibility, .screenRecording]
    s.hotkeyInstalled = true
    return s
}

@Test func readyWhenEverythingIsUp() {
    #expect(ok().summary == "Ready")
    #expect(!ok().needsAttention)
    #expect(ok().launchTab == nil)
}

@Test func missingPermissionsComeFirst() {
    var s = ok()
    s.granted = [.screenRecording]
    s.speech = .failed("x")
    s.models["a"] = .downloading(0.4)
    #expect(s.missing == [.microphone, .accessibility])
    #expect(s.summary == "Needs attention: Microphone, Accessibility")
    #expect(s.needsAttention)
    #expect(s.launchTab == .permissions)
}

// The tap needs Accessibility or Input Monitoring: only blame Input Monitoring once Accessibility is granted.
@Test func inputMonitoringOnlyAfterAccessibility() {
    var s = ok()
    s.hotkeyInstalled = false
    #expect(s.summary == "Needs attention: Input Monitoring")
    #expect(!s.isGranted(.inputMonitoring))
    s.granted.remove(.accessibility)
    #expect(s.missing == [.accessibility])
}

@Test func screenRecordingIsOptional() {
    var s = ok()
    s.granted.remove(.screenRecording)
    #expect(s.summary == "Ready")
    #expect(s.launchTab == nil)
    #expect(!s.isGranted(.screenRecording))
}

@Test func failuresThenDownloadsThenLoading() {
    var s = ok()
    s.models = ["a": .downloading(0.8), "b": .downloading(0.42)]
    #expect(s.summary == "Downloading model 42%")
    #expect(!s.needsAttention)
    s.models["b"] = .loading
    #expect(s.summary == "Downloading model 80%")
    s.models["a"] = .ready
    #expect(s.summary == "Loading models…")
    s.models["b"] = .failed("oops")
    #expect(s.summary == "Needs attention: Model failed")
    #expect(s.needsAttention)
    s.speech = .failed("x")
    #expect(s.summary == "Needs attention: Speech model failed")
    s.speech = .loading
    s.models = [:]
    #expect(s.summary == "Loading models…")
    s.speech = .downloading(0.3)
    #expect(s.summary == "Downloading model 30%")
    #expect(s.launchTab == nil)
}
