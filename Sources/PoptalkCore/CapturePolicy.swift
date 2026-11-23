import Foundation

/// What screen context may be captured, decided from the focused element and frontmost app.
public enum CapturePolicy {
    static let passwordManagers: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop", "com.apple.keychainaccess", "com.apple.Passwords", "me.proton.pass.electron",
        "com.lastpass.LastPass", "com.dashlane.dashlanephonefinal", "org.keepassxc.keepassxc", "in.sinew.Enpass-Desktop",
    ]

    static let browsers: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "com.google.Chrome.canary", "org.chromium.Chromium",
        "com.microsoft.edgemac", "com.brave.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
        "company.thebrowser.Browser", "company.thebrowser.dia", "org.mozilla.firefox", "app.zen-browser.zen",
    ]

    static let chromiumBrowsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "org.chromium.Chromium", "com.microsoft.edgemac",
        "com.brave.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
        "company.thebrowser.Browser", "company.thebrowser.dia",
    ]

    /// App-element attributes to set true, in order until one succeeds, so Chromium builds its AX tree.
    /// `AXManualAccessibility` (Electron's documented switch) has no side effects; `AXEnhancedUserInterface`
    /// is the VoiceOver flag and can break window animations and window managers, so it's only a
    /// fallback for allowlisted Chromium browsers.
    public static func axEnableAttributes(bundleID: String?, isElectron: Bool) -> [String] {
        if isElectron { return ["AXManualAccessibility"] }
        guard let bundleID, chromiumBrowsers.contains(bundleID) else { return [] }
        return ["AXManualAccessibility", "AXEnhancedUserInterface"]
    }

    /// A password field is focused or a password manager is frontmost: capture nothing and don't ⌘C.
    public static func isSensitive(subrole: String?, bundleID: String?) -> Bool {
        subrole == "AXSecureTextField" || bundleID.map(passwordManagers.contains) == true
    }

    /// A private/incognito browser window, by the marker each browser puts in its window title.
    /// ponytail: title heuristic only; Safari private windows have no title marker and aren't detected.
    public static func isPrivateWindow(bundleID: String?, title: String) -> Bool {
        guard let bundleID, browsers.contains(bundleID) else { return false }
        let t = title.lowercased()
        return ["incognito", "inprivate", "private browsing", "private window"].contains { t.contains($0) }
    }
}

/// Which context sources the user allows (#40) in Settings → Context, narrowed per press by an app profile (#96,
/// `AppProfiles.resolve`). The selection and saved vocabulary aren't optional; password fields are excluded regardless.
public struct ContextSources: Sendable, Equatable {
    public enum Key {
        public static let focusedText = "contextFocusedText", nearbyText = "contextNearbyText", ocr = "contextOCR"
        public static let windowTitle = "contextWindowTitle", screenVocabulary = "contextScreenVocabulary"
        public static let rememberScreenTerms = "contextRememberScreenTerms"
    }
    public var focusedText = true, nearbyText = true, ocr = true, windowTitle = true, screenVocabulary = true
    /// Its own source per app (#96); globally it goes with the window title, as one toggle.
    public var webDomain = true
    /// #87 "Remember screen terms that fix dictations": off by default, and only with `screenVocabulary` on.
    /// Use them (boost and recase); a profile can keep that and still turn learning off.
    public var rememberScreenTerms = false
    /// Learn new ones from this press's screen (`LearnedTerms.record`).
    public var learnScreenTerms = false

    public init() {}

    /// Unset keys are on, but `rememberScreenTerms`.
    public init(_ d: UserDefaults) {
        func on(_ k: String) -> Bool { d.object(forKey: k) as? Bool ?? true }
        (focusedText, nearbyText, ocr) = (on(Key.focusedText), on(Key.nearbyText), on(Key.ocr))
        (windowTitle, screenVocabulary) = (on(Key.windowTitle), on(Key.screenVocabulary))
        webDomain = windowTitle
        rememberScreenTerms = screenVocabulary && d.bool(forKey: Key.rememberScreenTerms)
        learnScreenTerms = rememberScreenTerms
    }

    /// The title is still read during capture (private-window check, OCR window match); it's dropped here.
    public func apply(_ s: ScreenSnapshot) -> ScreenSnapshot {
        var s = s
        if !windowTitle { s.windowTitle = "" }
        if !webDomain { s.webDomain = "" }
        return s
    }
}
