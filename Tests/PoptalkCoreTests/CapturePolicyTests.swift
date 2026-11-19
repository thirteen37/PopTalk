import Testing
@testable import PoptalkCore

@Test func secureFieldIsSensitive() {
    #expect(CapturePolicy.isSensitive(subrole: "AXSecureTextField", bundleID: "com.apple.Safari"))
    #expect(!CapturePolicy.isSensitive(subrole: "AXTextField", bundleID: "com.apple.Safari"))
    #expect(!CapturePolicy.isSensitive(subrole: nil, bundleID: nil))
}

@Test func passwordManagersAreSensitive() {
    for id in ["com.1password.1password", "com.bitwarden.desktop", "com.apple.keychainaccess",
               "com.apple.Passwords", "me.proton.pass.electron"] {
        #expect(CapturePolicy.isSensitive(subrole: nil, bundleID: id), "\(id)")
    }
}

@Test func privateBrowserWindowsByTitle() {
    #expect(CapturePolicy.isPrivateWindow(bundleID: "com.google.Chrome", title: "New Tab - Google Chrome (Incognito)"))
    #expect(CapturePolicy.isPrivateWindow(bundleID: "org.mozilla.firefox", title: "Mozilla — Private Browsing"))
    #expect(CapturePolicy.isPrivateWindow(bundleID: "com.microsoft.edgemac", title: "Bing - [InPrivate] - Microsoft Edge"))
    #expect(CapturePolicy.isPrivateWindow(bundleID: "com.brave.Browser", title: "New Private Window - Brave"))
    #expect(!CapturePolicy.isPrivateWindow(bundleID: "com.google.Chrome", title: "Inbox - Gmail"))
}

@Test func privateTitleOutsideBrowsersIsNotPrivate() {
    #expect(!CapturePolicy.isPrivateWindow(bundleID: "com.apple.Notes", title: "Incognito mode notes"))
    #expect(!CapturePolicy.isPrivateWindow(bundleID: nil, title: "Private Browsing"))
}

@Test func electronGetsManualAccessibilityOnly() {
    #expect(CapturePolicy.axEnableAttributes(bundleID: "com.tinyspeck.slackmacgap", isElectron: true) == ["AXManualAccessibility"])
}

@Test func chromiumBrowsersFallBackToEnhancedUserInterface() {
    #expect(CapturePolicy.axEnableAttributes(bundleID: "com.google.Chrome", isElectron: false)
        == ["AXManualAccessibility", "AXEnhancedUserInterface"])
}

@Test func otherAppsGetNothingSet() {
    #expect(CapturePolicy.axEnableAttributes(bundleID: "com.apple.Safari", isElectron: false).isEmpty)
    #expect(CapturePolicy.axEnableAttributes(bundleID: "org.mozilla.firefox", isElectron: false).isEmpty)
    #expect(CapturePolicy.axEnableAttributes(bundleID: nil, isElectron: false).isEmpty)
}
