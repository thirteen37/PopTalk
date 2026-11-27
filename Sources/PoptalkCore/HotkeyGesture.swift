import Foundation

/// Right-⌥ presses as gestures (#109). A press released within `tap` seconds is a tap; a tap whose press comes within
/// `doubleTapGap` of the previous tap's release is a double tap, which ends the sequence (a third tap starts anew).
/// That second press held for `tap` seconds or more is a tap-then-hold instead (#110), which edits the last insert.
/// A hold, or another key, also starts over. Each release decides at once: a first tap gets no added latency.
public struct HotkeyGesture {
    /// Both from `GestureTiming` (#112), passed in so this stays pure.
    public var tap: TimeInterval
    public var doubleTapGap: TimeInterval

    public enum Release: Equatable { case tap, doubleTap, hold, editHold }

    /// When the current press went down, nil while up.
    public private(set) var pressedAt: Date?
    /// Shift was down at some point in the current press, or the last one once released (#131): insert it raw.
    public private(set) var shifted = false
    private var cancelled = false
    /// The current press came within `doubleTapGap` of a tap.
    private var second = false
    /// The last tap's release, while a second tap may still follow.
    private var tappedAt: Date?

    public init(tap: TimeInterval = Double(GestureTiming.tapDefault) / 1000,
                doubleTapGap: TimeInterval = Double(GestureTiming.doubleTapGapDefault) / 1000) {
        (self.tap, self.doubleTapGap) = (tap, doubleTapGap)
    }

    public var isPressed: Bool { pressedAt != nil }

    /// Right ⌥ went down; ignored while already down. True if it came soon after a tap: a double tap or a
    /// tap-then-hold, which its release decides.
    @discardableResult
    public mutating func press(at now: Date) -> Bool {
        guard pressedAt == nil else { return false }
        pressedAt = now
        (cancelled, shifted) = (false, false)
        second = tappedAt.map { now.timeIntervalSince($0) < doubleTapGap } ?? false
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

    /// The modifier keys changed (or right ⌥ went down) with Shift down or not (#131).
    public mutating func modifiers(shift: Bool) {
        if shift, pressedAt != nil { shifted = true }
    }

    /// Right ⌥ came up: what the press was, nil if cancelled or not pressed.
    public mutating func release(at now: Date) -> Release? {
        guard let start = pressedAt else { return nil }
        pressedAt = nil
        if cancelled { return nil }
        guard now.timeIntervalSince(start) < tap else { return second ? .editHold : .hold }
        if second { return .doubleTap }
        tappedAt = now
        return .tap
    }

    /// Whether the last tap stands alone (#111): the double-tap window has passed with no press or other key since,
    /// so it may accept a showing offer without a double tap also doing so. True once.
    public mutating func tapSettled(at now: Date) -> Bool {
        guard let t = tappedAt, now.timeIntervalSince(t) >= doubleTapGap else { return false }
        tappedAt = nil
        return true
    }
}

/// Settings → General → Advanced (#112): the gesture times, in ms, clamped like `OutcomeKeys.undoWindow`.
public enum GestureTiming {
    /// "Longest tap". A deliberate tap often lasts 150-300 ms, and no real dictation or edit is that short: at 150 ms
    /// a slightly slow second tap became an edit hold and the double tap did nothing (#109). The app's delayed start
    /// (HUD, context, selection) waits this long too, so a tap never replaces the showing outcome.
    public static let tapKey = "hotkeyTapMs"
    public static let tapRange = 150...500
    public static let tapDefault = 300
    /// "Double-tap speed": the longest gap from a tap's release to the next press.
    public static let doubleTapGapKey = "hotkeyDoubleTapGapMs"
    public static let doubleTapGapRange = 250...800
    public static let doubleTapGapDefault = 400

    public static func tap(_ d: UserDefaults) -> TimeInterval { seconds(d, tapKey, tapDefault, tapRange) }
    public static func doubleTapGap(_ d: UserDefaults) -> TimeInterval {
        seconds(d, doubleTapGapKey, doubleTapGapDefault, doubleTapGapRange)
    }

    private static func seconds(_ d: UserDefaults, _ key: String, _ fallback: Int, _ range: ClosedRange<Int>) -> TimeInterval {
        let ms = d.object(forKey: key) as? Int ?? fallback
        return TimeInterval(min(max(ms, range.lowerBound), range.upperBound)) / 1000
    }
}
