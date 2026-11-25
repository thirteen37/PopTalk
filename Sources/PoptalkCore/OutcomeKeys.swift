import Foundation

/// Which key presses the outcome overlay consumes: bare Return (accept an offer). Undo is a right-⌥ double tap (#109).
public enum OutcomeKeys {
    /// Shift, Control, Option, Command, Fn (CGEventFlags raw values). Caps Lock doesn't count.
    static let modifiers: UInt64 = 0x20000 | 0x40000 | 0x80000 | 0x100000 | 0x800000

    public static func accepts(code: Int64, flags: UInt64) -> Bool { code == 36 && flags & modifiers == 0 }

    /// Settings → General "Undo window": how long an outcome, its undo and its Return key stay up (#46).
    public static let undoWindowKey = "undoWindowSeconds"
    public static let undoWindowRange = 2...15
    public static let undoWindowDefault = 5

    public static func undoWindow(_ d: UserDefaults) -> TimeInterval {
        let s = d.object(forKey: undoWindowKey) as? Int ?? undoWindowDefault
        return TimeInterval(min(max(s, undoWindowRange.lowerBound), undoWindowRange.upperBound))
    }
}
