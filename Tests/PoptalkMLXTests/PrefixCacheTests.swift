import Testing
@testable import PoptalkMLX

// #43: speculative prompts (the transcript so far, growing by a few words) reuse stored prefixes but never store
// snapshots or count as recent prompts, so they can't evict the system-prompt and screen entries.
@Test func speculativePromptsReuseButNeverStoreOrCount() {
    let system = Array(0 ..< 300)
    let c = PrefixCache()
    _ = c.insert(.init(tokens: system, cache: [], maxTrim: 0), bytes: 1)
    let first = system + Array(1000 ..< 1400)  // + screen + transcript
    _ = c.plan(first, enabled: true)
    // A non-speculative prompt sharing system + screen with `first` would snapshot there…
    let grown = first + [7, 8, 9]
    let spec = c.plan(grown, enabled: true, speculative: true)
    #expect(spec.plan.entry == 0 && spec.plan.keep == 300)
    #expect(spec.plan.snapshot == nil)
    // …and `grown` wasn't recorded: the final prompt is compared with `first`, as without speculation.
    let final = first + [7, 8, 9, 10]
    let f = c.plan(final, enabled: true)
    #expect(f.shared == first.count)
    #expect(f.plan.snapshot == first.count)
}
