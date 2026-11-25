import Foundation

/// Right-⌥ presses as gestures (#109). A press released within `tap` seconds is a tap; a tap whose press comes within
/// `doubleTapGap` of the previous tap's release is a double tap, which ends the sequence (a third tap starts anew).
/// That second press held for `tap` seconds or more is a tap-then-hold instead (#110), which edits the last insert.
/// A hold, or another key, also starts over. Each release decides at once: a first tap gets no added latency.
public struct HotkeyGesture {
    public static let tap: TimeInterval = 0.15
    public static let doubleTapGap: TimeInterval = 0.4

    public enum Release: Equatable { case tap, doubleTap, hold, editHold }

    private var pressedAt: Date?
    private var cancelled = false
    /// The current press came within `doubleTapGap` of a tap.
    private var second = false
    /// The last tap's release, while a second tap may still follow.
    private var tappedAt: Date?

    public init() {}

    public var isPressed: Bool { pressedAt != nil }

    /// Right ⌥ went down; ignored while already down. True if it came soon after a tap: a double tap or a
    /// tap-then-hold, which its release decides.
    @discardableResult
    public mutating func press(at now: Date) -> Bool {
        guard pressedAt == nil else { return false }
        pressedAt = now
        cancelled = false
        second = tappedAt.map { now.timeIntervalSince($0) < Self.doubleTapGap } ?? false
        tappedAt = nil
        return second
    }

    /// Another key went down: cancels a press in progress (true the first time) and forgets a pending tap.
    public mutating func otherKey() -> Bool {
        tappedAt = nil
        guard pressedAt != nil, !cancelled else { return false }
        cancelled = true
        return true
    }

    /// Right ⌥ came up: what the press was, nil if cancelled or not pressed.
    public mutating func release(at now: Date) -> Release? {
        guard let start = pressedAt else { return nil }
        pressedAt = nil
        if cancelled { return nil }
        guard now.timeIntervalSince(start) < Self.tap else { return second ? .editHold : .hold }
        if second { return .doubleTap }
        tappedAt = now
        return .tap
    }

    /// Whether the last tap stands alone (#111): the double-tap window has passed with no press or other key since,
    /// so it may accept a showing offer without a double tap also doing so. True once.
    public mutating func tapSettled(at now: Date) -> Bool {
        guard let t = tappedAt, now.timeIntervalSince(t) >= Self.doubleTapGap else { return false }
        tappedAt = nil
        return true
    }
}
