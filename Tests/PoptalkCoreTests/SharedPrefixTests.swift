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

@Test func prefixPlanIgnoresPrefixesUnderTheMinimumReuse() {
    let prompt = Array(0 ..< 1000)
    let system = Array(0 ..< 300), screen = Array(0 ..< 600)
    // Too short to reuse or store: plain prefill.
    #expect(prefixPlan(prompt, entries: [(system, 0)], recent: [system], minReuse: 512) == PrefixPlan(entry: nil, keep: 0))
    // A long enough boundary is stored even though the short entry isn't used; a long entry is used.
    #expect(prefixPlan(prompt, entries: [(system, 0)], recent: [screen], minReuse: 512) == PrefixPlan(entry: nil, keep: 0, snapshot: 600))
    #expect(prefixPlan(prompt, entries: [(system, 0), (screen, 0)], recent: [], minReuse: 512) == PrefixPlan(entry: 1, keep: 600))
}

@Test func lruKeepsTheMostRecentEntriesThatFitTheBudget() {
    let old: [(item: String, bytes: Int)] = [("b", 60), ("c", 50), ("d", 30)]  // most recent first
    // The new entry goes in front; the least recent go until the total fits.
    #expect(lruInsert("a", bytes: 80, into: old, budget: 200).map(\.item) == ["a", "b", "c"])
    #expect(lruInsert("a", bytes: 150, into: old, budget: 200).map(\.item) == ["a"])
    // Bigger than the whole budget: never stored, and nothing is evicted for it.
    #expect(lruInsert("a", bytes: 201, into: old, budget: 200).map(\.item) == ["b", "c", "d"])
    // A lower budget evicts down to it.
    #expect(lruFit(old, budget: 100).map(\.item) == ["b"])
    #expect(lruFit(old, budget: 10).map(\.item) == [])
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
