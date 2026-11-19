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
