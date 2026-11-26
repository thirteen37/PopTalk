import Foundation

/// A context source a per-app profile can turn off (#96); each names a `ContextSources` field.
public enum ContextSource: String, Codable, CaseIterable, Sendable {
    case focusedText, nearbyText, ocr, windowTitle, webDomain, screenVocabulary, rememberScreenTerms, learnScreenTerms

    /// What "Don't read this app's screen" turns off: every source read from the screen, and learning from it.
    /// Remembered terms are still used: they aren't read from this app.
    public static let screen = Set(allCases).subtracting([.rememberScreenTerms])
}

extension ContextSources {
    public subscript(_ s: ContextSource) -> Bool {
        get { self[keyPath: Self.path(s)] }
        set { self[keyPath: Self.path(s)] = newValue }
    }

    private static func path(_ s: ContextSource) -> WritableKeyPath<ContextSources, Bool> {
        switch s {
        case .focusedText: \.focusedText
        case .nearbyText: \.nearbyText
        case .ocr: \.ocr
        case .windowTitle: \.windowTitle
        case .webDomain: \.webDomain
        case .screenVocabulary: \.screenVocabulary
        case .rememberScreenTerms: \.rememberScreenTerms
        case .learnScreenTerms: \.learnScreenTerms
        }
    }
}

/// A per-app profile (#96): a match rule and the context sources it turns off. A profile only turns sources off,
/// so one off in Settings → Context stays off everywhere.
public struct AppProfile: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    /// "" matches any app (a website-only profile).
    public var bundleID = ""
    /// "" matches any page; "example.com" also matches "mail.example.com", not "notexample.com".
    public var domain = ""
    public var off: Set<ContextSource> = []

    public init(bundleID: String = "", domain: String = "", off: Set<ContextSource> = []) {
        (self.bundleID, self.domain, self.off) = (bundleID, domain, off)
    }

    /// The host part of what a user typed: "https://Mail.Example.com/inbox" → "mail.example.com", "*.example.com" →
    /// "example.com".
    public static func host(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let h = t.contains("://") ? URL(string: t)?.host() ?? t : String(t.prefix { $0 != "/" })
        return String(h.drop { $0 == "*" || $0 == "." })
    }

    /// App and domain beat app only, which beats domain only; then the longest domain.
    var rank: (Int, Int) { ((bundleID.isEmpty ? 0 : 2) + (domain.isEmpty ? 0 : 1), Self.host(domain).count) }

    /// `host` nil (no page, or a private window) matches app-only profiles only. A profile with neither app nor
    /// domain matches nothing.
    func matches(bundleID b: String?, host: String?) -> Bool {
        guard !bundleID.isEmpty || !domain.isEmpty else { return false }
        if !bundleID.isEmpty, bundleID.lowercased() != b?.lowercased() { return false }
        if domain.isEmpty { return true }
        guard let host = host?.lowercased() else { return false }
        let d = Self.host(domain)
        return host == d || host.hasSuffix("." + d)
    }
}

/// The context sources for one press, resolved once at capture and carried with the request (#96).
public struct ResolvedProfile: Sendable, Equatable {
    public var sources: ContextSources
    /// A per-app profile matched, for the log and the status strip. Which one, and the domain, never leave here.
    public var custom = false
    /// The sources the profile turned off that Settings → Context had on, for the status strip (#127).
    public var appOff: Set<ContextSource> = []

    public init(sources: ContextSources, custom: Bool = false, appOff: Set<ContextSource> = []) {
        (self.sources, self.custom, self.appOff) = (sources, custom, appOff)
    }
}

/// Per-app profiles (#96), a JSON array in local `UserDefaults` (not synced: the list shows what a user runs).
public enum AppProfiles {
    public static let key = "appProfiles"

    public static func load(_ d: UserDefaults) -> [AppProfile] {
        d.data(forKey: key).flatMap { try? JSONDecoder().decode([AppProfile].self, from: $0) } ?? []
    }

    public static func save(_ profiles: [AppProfile], to d: UserDefaults) {
        d.set(try? JSONEncoder().encode(profiles), forKey: key)
    }

    /// The most specific profile matching the app and page (`AppProfile.rank`) turns its sources off `defaults`.
    /// Hard exclusions win over any profile: a password field or manager (`isSensitive`, or a listed bundle ID)
    /// reads nothing; a private window ignores domain profiles and reads no nearby text, OCR or domain.
    public static func resolve(bundleID: String?, domain: String?, isPrivate: Bool, isSensitive: Bool = false,
                               profiles: [AppProfile], defaults: ContextSources) -> ResolvedProfile {
        var r = ResolvedProfile(sources: defaults)
        if let match = profiles.filter({ $0.matches(bundleID: bundleID, host: isPrivate ? nil : domain) })
            .max(by: { $0.rank < $1.rank }) {
            r.custom = true
            r.appOff = match.off.filter { defaults[$0] }
            for s in match.off { r.sources[s] = false }
        }
        if isPrivate { (r.sources.nearbyText, r.sources.ocr, r.sources.webDomain) = (false, false, false) }
        if isSensitive || CapturePolicy.isSensitive(subrole: nil, bundleID: bundleID) {
            for s in ContextSource.allCases { r.sources[s] = false }
        }
        return r
    }

    /// Whether capture should look up the page's host: the app's own resolution lets the domain into the prompt, or a
    /// website profile for this app (or any app) could still match. Never in a private window or a password manager.
    public static func needsDomain(bundleID: String?, isPrivate: Bool, profiles: [AppProfile], defaults: ContextSources) -> Bool {
        guard !isPrivate, !CapturePolicy.isSensitive(subrole: nil, bundleID: bundleID) else { return false }
        let b = bundleID?.lowercased()
        return resolve(bundleID: bundleID, domain: nil, isPrivate: false, profiles: profiles, defaults: defaults).sources.webDomain
            || profiles.contains { !$0.domain.isEmpty && ($0.bundleID.isEmpty || $0.bundleID.lowercased() == b) }
    }

    /// Another profile (by id) has the same match rule. Settings refuses to save it, so ties need no order.
    public static func conflicts(_ p: AppProfile, in profiles: [AppProfile]) -> Bool {
        profiles.contains {
            $0.id != p.id && $0.bundleID.lowercased() == p.bundleID.lowercased() && AppProfile.host($0.domain) == AppProfile.host(p.domain)
        }
    }

    /// The menu's "Don't read the screen in ‹app›": whether `bundleID`'s app-only profile turns every screen source off.
    public static func screenOff(_ bundleID: String, in profiles: [AppProfile]) -> Bool {
        profiles.first { $0.matchesAppOnly(bundleID) }.map { ContextSource.screen.isSubset(of: $0.off) } ?? false
    }

    /// Turns every screen source off (or back on) in `bundleID`'s app-only profile, adding it, or dropping it once it
    /// turns nothing off.
    public static func setScreenOff(_ on: Bool, bundleID: String, in profiles: inout [AppProfile]) {
        guard let i = profiles.firstIndex(where: { $0.matchesAppOnly(bundleID) }) else {
            if on { profiles.append(AppProfile(bundleID: bundleID, off: ContextSource.screen)) }
            return
        }
        if on { profiles[i].off.formUnion(ContextSource.screen) } else { profiles[i].off.subtract(ContextSource.screen) }
        if profiles[i].off.isEmpty { profiles.remove(at: i) }
    }
}

private extension AppProfile {
    func matchesAppOnly(_ b: String) -> Bool { domain.isEmpty && bundleID.lowercased() == b.lowercased() }
}
