/// How many leading tokens two prompts share: the part a KV cache could reuse (#42).
public func sharedPrefix(_ a: [Int], _ b: [Int]) -> Int {
    zip(a, b).prefix { $0 == $1 }.count
}

/// How a prompt uses the stored prefix snapshots (#42): start from `entry` cut back to its first `keep` tokens
/// (nil: an empty cache), and snapshot the cache again once it holds the first `snapshot` tokens.
public struct PrefixPlan: Equatable, Sendable {
    public var entry: Int?
    public var keep: Int
    public var snapshot: Int?
    public init(entry: Int?, keep: Int, snapshot: Int? = nil) { (self.entry, self.keep, self.snapshot) = (entry, keep, snapshot) }
}

/// Picks the entry sharing the longest prefix with `prompt` that can be cut back to that prefix exactly (`maxTrim`:
/// how many trailing tokens it can drop), and a snapshot point: the longest prefix shared with a `recent` prompt,
/// i.e. the part that repeats (a kind's system prompt, unchanged screen context), when that's `minGain` tokens
/// past what's reused. The last token is never reused: the model must run it for the first logits.
public func prefixPlan(_ prompt: [Int], entries: [(tokens: [Int], maxTrim: Int)], recent: [[Int]], minGain: Int = 32) -> PrefixPlan {
    let limit = max(prompt.count - 1, 0)
    var plan = PrefixPlan(entry: nil, keep: 0)
    for (i, e) in entries.enumerated() {
        let keep = min(sharedPrefix(e.tokens, prompt), limit)
        if keep > plan.keep, e.tokens.count - keep <= e.maxTrim { plan = PrefixPlan(entry: i, keep: keep) }
    }
    let boundary = min(recent.map { sharedPrefix($0, prompt) }.max() ?? 0, limit)
    if boundary >= plan.keep + minGain { plan.snapshot = boundary }
    return plan
}
