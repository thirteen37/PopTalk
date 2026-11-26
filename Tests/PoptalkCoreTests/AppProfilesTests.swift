import Foundation
import Testing
@testable import PoptalkCore

// #96: per-app profiles that turn context sources off.
private let all = ContextSources()

private func resolve(_ bundleID: String?, _ domain: String?, isPrivate: Bool = false, isSensitive: Bool = false,
                     _ profiles: [AppProfile], defaults: ContextSources = all) -> ResolvedProfile {
    AppProfiles.resolve(bundleID: bundleID, domain: domain, isPrivate: isPrivate, isSensitive: isSensitive,
                        profiles: profiles, defaults: defaults)
}

private func resolve(_ bundleID: String?, isSensitive: Bool = false, _ profiles: [AppProfile],
                     defaults: ContextSources = all) -> ResolvedProfile {
    resolve(bundleID, nil, isSensitive: isSensitive, profiles, defaults: defaults)
}

private let mailOff = AppProfile(bundleID: "com.example.Mail", off: [.ocr])
private let siteOff = AppProfile(domain: "example.com", off: [.nearbyText])
private let browserSiteOff = AppProfile(bundleID: "com.example.Browser", domain: "example.com", off: [.focusedText])
private let browserOff = AppProfile(bundleID: "com.example.Browser", off: [.windowTitle])

@Test func noMatchGivesTheDefault() {
    #expect(resolve("com.example.Notes", "example.org", [mailOff, siteOff]) == ResolvedProfile(sources: all))
    var d = all
    d.ocr = false
    #expect(resolve(nil, [mailOff], defaults: d) == ResolvedProfile(sources: d))
}

@Test func bundleIDMatchTurnsItsSourcesOff() {
    let r = resolve("com.example.Mail", [mailOff])
    #expect(r.custom && !r.sources.ocr && r.sources.nearbyText && r.sources.focusedText)
    #expect(resolve("COM.EXAMPLE.MAIL", [mailOff]).custom)  // bundle IDs case-insensitive
}

@Test func domainMatchesOnALabelBoundary() {
    #expect(resolve("com.example.Browser", "example.com", [siteOff]).custom)
    #expect(resolve("com.example.Browser", "mail.example.com", [siteOff]).custom)
    #expect(resolve("com.example.Browser", "Mail.Example.COM", [siteOff]).custom)
    #expect(!resolve("com.example.Browser", "notexample.com", [siteOff]).custom)
    #expect(!resolve("com.example.Browser", "example.com.evil.test", [siteOff]).custom)
    #expect(!resolve("com.example.Browser", nil, [siteOff]).custom)
}

@Test func mostSpecificProfileWins() {
    let profiles = [siteOff, browserOff, browserSiteOff]
    let both = resolve("com.example.Browser", "docs.example.com", profiles).sources
    #expect(!both.focusedText && both.windowTitle && both.nearbyText)
    let bundle = resolve("com.example.Browser", "example.org", profiles).sources
    #expect(!bundle.windowTitle && bundle.focusedText && bundle.nearbyText)
    let domain = resolve("com.example.Other", "example.com", profiles).sources
    #expect(!domain.nearbyText && domain.focusedText && domain.windowTitle)
}

@Test func longestDomainSuffixWins() {
    let docs = AppProfile(domain: "docs.example.com", off: [.ocr])
    let r = resolve("com.example.Browser", "a.docs.example.com", [siteOff, docs]).sources
    #expect(!r.ocr && r.nearbyText)
}

@Test func privateWindowIgnoresDomainProfilesAndKeepsItsExclusions() {
    let r = resolve("com.example.Browser", "example.com", isPrivate: true, [siteOff, browserSiteOff])
    #expect(!r.custom && r.sources.focusedText && !r.sources.nearbyText && !r.sources.ocr && !r.sources.webDomain)
    #expect(resolve("com.example.Browser", "example.com", isPrivate: true, [browserOff]).custom)  // app-only still applies
}

@Test func sensitiveCapturesNothingWhateverTheProfileSays() {
    let none = ContextSource.allCases.allSatisfy { !resolve("com.example.Mail", isSensitive: true, [mailOff]).sources[$0] }
    #expect(none)
    #expect(ContextSource.allCases.allSatisfy { !resolve("com.1password.1password", []).sources[$0] })
}

@Test func profilesOnlyTurnSourcesOff() {
    var d = all
    d.ocr = false
    let keepsOCR = AppProfile(bundleID: "com.example.Mail", off: [])
    #expect(!resolve("com.example.Mail", [keepsOCR], defaults: d).sources.ocr)  // off globally stays off
}

@Test func learningOffForAnAppStillUsesRememberedTerms() {
    var d = all
    (d.rememberScreenTerms, d.learnScreenTerms) = (true, true)
    let r = resolve("com.example.Mail", [AppProfile(bundleID: "com.example.Mail", off: [.learnScreenTerms])], defaults: d)
    #expect(r.sources.rememberScreenTerms && !r.sources.learnScreenTerms)
}

@Test func emptyMatchRuleMatchesNothing() {
    #expect(!resolve("com.example.Mail", "example.com", [AppProfile(off: [.ocr])]).custom)
}

@Test func profilesRoundTripThroughDefaults() throws {
    let d = UserDefaults(suiteName: "poptalk-test-\(UUID())")!
    #expect(AppProfiles.load(d).isEmpty)
    AppProfiles.save([mailOff, browserSiteOff], to: d)
    #expect(AppProfiles.load(d) == [mailOff, browserSiteOff])
    let json = try JSONEncoder().encode(mailOff)
    #expect(try JSONDecoder().decode(AppProfile.self, from: json) == mailOff)
}

@Test func domainsAreNormalizedForMatching() {
    #expect(AppProfile.host(" https://Mail.Example.com/inbox?x=1 ") == "mail.example.com")
    #expect(AppProfile.host("*.example.com") == "example.com")
    #expect(AppProfile.host("example.com/path") == "example.com")
    #expect(resolve("com.example.Browser", "mail.example.com", [AppProfile(domain: "https://example.com/", off: [.ocr])]).custom)
}

@Test func duplicateMatchRulesConflict() {
    let dup = AppProfile(bundleID: "COM.EXAMPLE.MAIL", off: [.nearbyText])
    #expect(AppProfiles.conflicts(dup, in: [mailOff, siteOff]))
    #expect(!AppProfiles.conflicts(mailOff, in: [mailOff, siteOff]))  // itself, by id
    #expect(!AppProfiles.conflicts(AppProfile(bundleID: "com.example.Mail", domain: "example.com"), in: [mailOff, siteOff]))
}

@Test func menuTogglesScreenReadingForTheApp() {
    var profiles = [mailOff]
    #expect(!AppProfiles.screenOff("com.example.Mail", in: profiles))
    AppProfiles.setScreenOff(true, bundleID: "com.example.Mail", in: &profiles)
    #expect(AppProfiles.screenOff("com.example.Mail", in: profiles) && profiles.count == 1)
    let r = resolve("com.example.Mail", profiles).sources
    #expect(!r.focusedText && !r.nearbyText && !r.ocr && !r.windowTitle && !r.webDomain && !r.screenVocabulary)
    AppProfiles.setScreenOff(false, bundleID: "com.example.Mail", in: &profiles)
    #expect(profiles.isEmpty)  // it turned nothing else off
    AppProfiles.setScreenOff(true, bundleID: "com.example.Notes", in: &profiles)
    #expect(profiles.map(\.bundleID) == ["com.example.Notes"] && profiles[0].domain.isEmpty)
}

// The domain is its own source; the prompt's window attribute is what it was when it rode in the title.
@Test func defaultProfilePromptIsUnchanged() {
    let snap = ScreenSnapshot(appName: "Browser", windowTitle: "Inbox", webDomain: "mail.example.com",
                              text: "Hi team", cursorOffset: 7)
    let sources = resolve("com.example.Browser", "mail.example.com", []).sources
    #expect(sources.apply(snap) == snap)
    #expect(Prompts.dictation(transcript: "hello", context: sources.apply(snap), vocabulary: [])[1].content
        == "<screen app=\"Browser\" window=\"Inbox (mail.example.com)\">\nHi team\n</screen>\n<transcript>hello</transcript>")
    #expect(Prompts.dictation(transcript: "hello", context: ScreenSnapshot(appName: "Browser", windowTitle: "Inbox (mail.example.com)",
                                                                         text: "Hi team", cursorOffset: 7), vocabulary: [])
        == Prompts.dictation(transcript: "hello", context: snap, vocabulary: []))
    #expect(ScreenSnapshot(webDomain: "example.com").titleAndDomain == "example.com")
}

@Test func domainCanBeOffWhileTheTitleStays() {
    let snap = ScreenSnapshot(appName: "Browser", windowTitle: "Inbox", webDomain: "mail.example.com")
    let r = resolve("com.example.Browser", "mail.example.com", [AppProfile(domain: "example.com", off: [.webDomain])])
    #expect(r.sources.apply(snap).titleAndDomain == "Inbox")
    #expect(ContextSources(UserDefaults(suiteName: "poptalk-test-\(UUID())")!).webDomain)
}

@Test func defaultProfileEditPromptIsUnchanged() {
    let snap = ScreenSnapshot(appName: "Browser", windowTitle: "Inbox", webDomain: "mail.example.com", text: "Hi team")
    let sources = resolve("com.example.Browser", "mail.example.com", []).sources
    #expect(Prompts.edit(instruction: "make it formal", selection: "hey", context: sources.apply(snap), vocabulary: [])
        == Prompts.edit(instruction: "make it formal", selection: "hey",
                        context: ScreenSnapshot(appName: "Browser", windowTitle: "Inbox (mail.example.com)", text: "Hi team"),
                        vocabulary: []))
}

// The page's host is read only when the prompt can use it or a website profile could still match.
@Test func domainIsLookedUpOnlyWhenSomethingCanUseIt() {
    let needs = { (b: String?, p: Bool, ps: [AppProfile], d: ContextSources) in
        AppProfiles.needsDomain(bundleID: b, isPrivate: p, profiles: ps, defaults: d)
    }
    var noDomain = all
    noDomain.webDomain = false
    #expect(needs("com.example.Browser", false, [], all))
    #expect(!needs("com.example.Browser", true, [siteOff], all))  // private window: never
    #expect(!needs("com.example.Browser", false, [], noDomain))
    #expect(needs("com.example.Browser", false, [siteOff], noDomain))  // a website profile may match
    #expect(needs("com.example.Browser", false, [browserSiteOff], noDomain))
    #expect(!needs("com.example.Other", false, [browserSiteOff], noDomain))  // another app's website profile
    let screenOff = AppProfile(bundleID: "com.example.Browser", off: ContextSource.screen)
    #expect(!needs("com.example.Browser", false, [screenOff], all))  // the app's own profile turned the domain off
    #expect(needs("com.example.Browser", false, [screenOff, browserSiteOff], all))  // a more specific one may turn it back
    #expect(!needs("com.1password.1password", false, [siteOff], all))  // password manager
}
