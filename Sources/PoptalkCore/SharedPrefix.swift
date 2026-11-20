/// How many leading tokens two prompts share: the part a KV cache could reuse (#42).
public func sharedPrefix(_ a: [Int], _ b: [Int]) -> Int {
    zip(a, b).prefix { $0 == $1 }.count
}
