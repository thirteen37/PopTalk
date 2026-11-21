import Foundation

/// Right ⌥ tap-then-hold (#80): a tap (released within `tap` seconds, a cancel) and then a press within `gap` seconds
/// of it edits the last dictation. Each press decides at once, so a plain press gets no added latency.
public struct TapHold {
    public static let tap: TimeInterval = 0.15, gap: TimeInterval = 0.4
    private var tappedAt: Date?

    public init() {}

    /// A press at `now`: true if it's the hold of a tap-then-hold.
    public mutating func press(at now: Date) -> Bool {
        defer { tappedAt = nil }
        return tappedAt.map { now.timeIntervalSince($0) < Self.gap } ?? false
    }

    /// The release, at `now`, of a press at `start`: true if it was a tap, too short to dictate.
    public mutating func release(from start: Date, at now: Date) -> Bool {
        let tap = now.timeIntervalSince(start) < Self.tap
        tappedAt = tap ? now : nil
        return tap
    }
}
