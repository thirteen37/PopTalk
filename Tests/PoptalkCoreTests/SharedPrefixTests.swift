import Testing
@testable import PoptalkCore

@Test func sharedPrefixCountsLeadingEqualTokens() {
    #expect(sharedPrefix([1, 2, 3, 4], [1, 2, 9, 4]) == 2)
    #expect(sharedPrefix([1, 2, 3], [1, 2, 3, 4, 5]) == 3)
    #expect(sharedPrefix([1, 2, 3], [1, 2, 3]) == 3)
    #expect(sharedPrefix([7], [1]) == 0)
    #expect(sharedPrefix([], [1, 2]) == 0)
}

// #42: which stored prefix to start from, and where to snapshot a new one.
@Test func prefixPlanReusesTheLongestExactPrefixAndSnapshotsAtTheRecentBoundary() {
    let prompt = Array(0 ..< 200)
    let system = Array(0 ..< 100), screen = Array(0 ..< 150) + [999]
    // Longest usable entry wins; the boundary shared with a recent prompt is past it, so snapshot there.
    let p = prefixPlan(prompt, entries: [(system, 0), (Array(0 ..< 80), 0)], recent: [screen, [5]])
    #expect(p == PrefixPlan(entry: 0, keep: 100, snapshot: 150))
    // An entry that diverges needs trimming: only within its exact rewind limit.
    #expect(prefixPlan(prompt, entries: [(screen, 0), (system, 0)], recent: []) == PrefixPlan(entry: 1, keep: 100, snapshot: nil))
    #expect(prefixPlan(prompt, entries: [(screen, 1), (system, 0)], recent: []) == PrefixPlan(entry: 0, keep: 150, snapshot: nil))
}

@Test func prefixPlanLeavesTheLastTokenAndSkipsSmallGains() {
    let prompt = Array(0 ..< 200)
    // Same prompt again: everything but the last token, which must run for the first logits.
    #expect(prefixPlan(prompt, entries: [(Array(0 ..< 199), 0)], recent: [prompt]) == PrefixPlan(entry: 0, keep: 199, snapshot: nil))
    #expect(prefixPlan(prompt, entries: [(prompt, 0)], recent: []) == PrefixPlan(entry: nil, keep: 0))
    #expect(prefixPlan(prompt, entries: [], recent: [prompt]) == PrefixPlan(entry: nil, keep: 0, snapshot: 199))
    // A boundary a few tokens past what's reused (dictation vs edit share only the chat-template header) isn't worth an entry.
    #expect(prefixPlan(prompt, entries: [], recent: [Array(0 ..< 4)]) == PrefixPlan(entry: nil, keep: 0, snapshot: nil))
    #expect(prefixPlan(prompt, entries: [(Array(0 ..< 100), 0)], recent: [Array(0 ..< 120)]) == PrefixPlan(entry: 0, keep: 100, snapshot: nil))
}
