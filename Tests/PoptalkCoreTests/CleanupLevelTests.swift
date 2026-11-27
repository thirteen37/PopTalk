import Foundation
import Testing
@testable import PoptalkCore

// #96: the Cleanup level (Verbatim / Clean / Polished). Inert until a model is trained on the tag.

private let screen = ScreenSnapshot(appName: "Notes", windowTitle: "Plan", text: "ship the beta", cursorOffset: 13)
private let vocab = [VocabTerm(text: "Corvelle")]

@Test func cleanPromptIsByteIdenticalForEveryModel() {
    let user = "<screen app=\"Notes\" window=\"Plan\">\nship the beta\n</screen>\n<vocabulary>Corvelle</vocabulary>\n<transcript>hello world</transcript>"
    for (model, system) in [(ModelSettings.fineTune, Prompts.dictationSystem), (ModelSettings.e2b, Prompts.dictationSystem),
                            (ModelSettings.e4b, Prompts.e4bDictationSystem), ("/models/candidate", Prompts.dictationSystem)] {
        let m = Prompts.dictation(model: model, transcript: "hello world", context: screen, vocabulary: vocab, cleanup: .clean)
        #expect(m == [ChatMessage(role: "system", content: system), ChatMessage(role: "user", content: user)], "\(model)")
        #expect(m == Prompts.dictation(model: model, transcript: "hello world", context: screen, vocabulary: vocab))
    }
    let s1 = Prompts.dictation(model: "/models/s1-mini-4bit", transcript: "hello world", context: screen, vocabulary: vocab, cleanup: .polished)
    #expect(s1 == [ChatMessage(role: "system", content: Prompts.s1MiniSystem),
                   ChatMessage(role: "user", content: "\(Prompts.s1MiniControl)\nhello world")])
}

@Test func nonDefaultLevelAddsOneLineBeforeTranscript() {
    for level in [CleanupLevel.verbatim, .polished] {
        let user = Prompts.dictation(transcript: "hello world", context: screen, vocabulary: vocab, cleanup: level)[1].content
        #expect(user.hasSuffix("</vocabulary>\n<style cleanup=\"\(level.rawValue)\"/>\n<transcript>hello world</transcript>"))
    }
}

// The training render path (#124): PoptalkDatagen render's `cleanup` field goes through dictationMessages.
@Test func renderPathCarriesTheTag() {
    let m = Pipeline.dictationMessages(model: ModelSettings.e2b, transcript: "so like the plan is set", context: screen,
                                       vocabulary: [], cleanup: .verbatim)
    #expect(m[1].content == "<screen app=\"Notes\" window=\"Plan\">\nship the beta\n</screen>\n<style cleanup=\"verbatim\"/>\n<transcript>so like the plan is set</transcript>")
    #expect(Pipeline.dictationMessages(model: ModelSettings.e2b, transcript: "hi", context: screen, vocabulary: [])
        == Pipeline.dictationMessages(model: ModelSettings.e2b, transcript: "hi", context: screen, vocabulary: [], cleanup: .clean))
}

private final class Seen: @unchecked Sendable { var user: [String] = [] }

private func prompts(model: String, levels: Bool? = nil, _ requests: [Request]) async -> [String] {
    let seen = Seen()
    var p = Pipeline(complete: { _, m, json, _ in
        seen.user.append(m[1].content)
        return json ? #"{"action":"edit","text":"Hi.","vocabulary":null,"remember":false}"# : "Hello there."
    }, vocabulary: VocabularyStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")),
       cleanupModel: model, editModel: model)
    if let levels { p.levels = levels }
    for r in requests { _ = await p.run(r) }
    return seen.user
}

@Test func tagGoesOnlyToModelsTrainedForLevels() async {
    let polished = Request(transcript: "hello there", selection: nil, context: ScreenSnapshot(), cleanup: .polished)
    #expect(ModelSettings.levelModels.isEmpty)  // no current model is marked: the app never sends the tag
    #expect(await prompts(model: ModelSettings.fineTune, [polished]).allSatisfy { !$0.contains("<style") })
    #expect(await prompts(model: ModelSettings.e4b, [polished]).allSatisfy { !$0.contains("<style") })
    #expect(await prompts(model: "adapters/candidate", levels: true, [polished])
        .allSatisfy { $0.contains("<style cleanup=\"polished\"/>\n<transcript>") })
    // Edits are unaffected.
    let edit = Request(transcript: "make it shorter", selection: "Hello there.", context: ScreenSnapshot(), cleanup: .polished)
    #expect(await prompts(model: "adapters/candidate", levels: true, [edit]).allSatisfy { !$0.contains("<style") })
}

private let mail = AppProfile(bundleID: "com.example.Mail", cleanup: .verbatim)
private let site = AppProfile(domain: "example.com", cleanup: .polished)
private let mailSite = AppProfile(bundleID: "com.example.Mail", domain: "example.com", off: [.ocr])

private func level(_ bundleID: String?, _ domain: String?, _ profiles: [AppProfile], global: CleanupLevel = .clean) -> CleanupLevel {
    AppProfiles.resolve(bundleID: bundleID, domain: domain, isPrivate: false, profiles: profiles, defaults: ContextSources(),
                        cleanup: global).cleanup
}

@Test func perAppLevelOverridesTheGlobalOne() {
    #expect(level("com.example.Notes", nil, [mail, site], global: .polished) == .polished)  // no match: global
    #expect(level("com.example.Mail", nil, [mail, site], global: .polished) == .verbatim)
    #expect(level("com.example.Browser", "docs.example.com", [mail, site]) == .polished)
    // The most specific profile wins, and its nil level inherits the global one, not a less specific profile's.
    #expect(level("com.example.Mail", "example.com", [mail, site, mailSite], global: .polished) == .polished)
    #expect(level("com.example.Mail", "example.com", [mail, site]) == .verbatim)  // app beats domain
}

@Test func appProfileCodableKeepsTheLevelAndReadsOldJSON() throws {
    for p in [mail, AppProfile(bundleID: "com.example.Notes", off: [.ocr])] {
        #expect(try JSONDecoder().decode(AppProfile.self, from: JSONEncoder().encode(p)) == p)
    }
    #expect(!String(decoding: try JSONEncoder().encode(mailSite), as: UTF8.self).contains("cleanup"))
    let old = #"[{"id":"7C9E6679-7425-40DE-944B-E07FC1F90AE7","bundleID":"com.example.Mail","domain":"","off":["ocr"]}]"#
    let d = UserDefaults(suiteName: "cleanup-level-\(UUID())")!
    d.set(Data(old.utf8), forKey: AppProfiles.key)
    let loaded = AppProfiles.load(d)
    #expect(loaded.count == 1 && loaded[0].cleanup == nil && loaded[0].off == [.ocr])
}

@Test func globalLevelDefaultsToClean() {
    let d = UserDefaults(suiteName: "cleanup-level-\(UUID())")!
    #expect(CleanupLevel(d) == .clean)
    d.set("polished", forKey: CleanupLevel.key)
    #expect(CleanupLevel(d) == .polished)
    d.set("bogus", forKey: CleanupLevel.key)
    #expect(CleanupLevel(d) == .clean)
    #expect(CleanupLevel.allCases.map(\.displayName) == ["Verbatim", "Clean", "Polished"])
}

// The menu's "Don't read the screen" toggle must not drop a profile that still sets a level.
@Test func screenToggleKeepsAProfileWithALevel() {
    var profiles = [AppProfile(bundleID: "com.example.Mail", cleanup: .polished)]
    AppProfiles.setScreenOff(true, bundleID: "com.example.Mail", in: &profiles)
    AppProfiles.setScreenOff(false, bundleID: "com.example.Mail", in: &profiles)
    #expect(profiles.count == 1 && profiles[0].cleanup == .polished && profiles[0].off.isEmpty)
}

@Test func benchCaseCarriesItsLevel() throws {
    let c = try BenchCase.load(jsonl: #"{"id":"d-x","kind":"dictation","transcript":"hi","cleanup":"verbatim"}"#)[0]
    #expect(c.request.cleanup == .verbatim)
    #expect(try BenchCase.load(jsonl: #"{"id":"d-y","kind":"dictation","transcript":"hi"}"#)[0].request.cleanup == .clean)
}

// #96 step 2: the E4B teacher (PoptalkDatagen pipeline, `levels` on) gets the tag plus a rule saying what it means;
// at Clean its prompt is unchanged, so v6/v7's teacher outputs still hold.
@Test func e4bGetsALevelRuleOnlyAtNonDefaultLevels() async {
    for level in [CleanupLevel.verbatim, .polished] {
        let m = Prompts.dictation(model: ModelSettings.e4b, transcript: "hello world", context: screen, vocabulary: vocab, cleanup: level)
        #expect(m[0].content == Prompts.e4bDictationSystem + "\n\n" + Prompts.e4bLevelRules[level]!)
        #expect(m[0].content.contains("<style cleanup=\"\(level.rawValue)\"/>"))
        #expect(m[1].content.hasSuffix("<style cleanup=\"\(level.rawValue)\"/>\n<transcript>hello world</transcript>"))
        // The fine-tune learns the tag from data: its system prompt never changes.
        #expect(Prompts.dictation(model: ModelSettings.fineTune, transcript: "hello world", context: screen, vocabulary: vocab,
                                  cleanup: level)[0].content == Prompts.dictationSystem)
    }
    #expect(Prompts.e4bLevelRules[.clean] == nil)
    let clean = Request(transcript: "hello there", selection: nil, context: ScreenSnapshot())
    #expect(await prompts(model: ModelSettings.e4b, levels: true, [clean]) == prompts(model: ModelSettings.e4b, [clean]))
    let verbatim = Request(transcript: "hello there", selection: nil, context: ScreenSnapshot(), cleanup: .verbatim)
    #expect(await prompts(model: ModelSettings.e4b, levels: true, [verbatim]).allSatisfy { $0.contains("<style cleanup=\"verbatim\"/>") })
}
