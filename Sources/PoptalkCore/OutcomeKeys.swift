import Foundation

/// Settings → General "Undo window": how long an outcome, its undo (a right-⌥ double tap, #109) and its offer (a
/// tap, #111) stay up (#46). The overlay catches no keys.
public enum OutcomeKeys {
    public static let undoWindowKey = "undoWindowSeconds"
    public static let undoWindowRange = 2...15
    public static let undoWindowDefault = 5

    public static func undoWindow(_ d: UserDefaults) -> TimeInterval {
        let s = d.object(forKey: undoWindowKey) as? Int ?? undoWindowDefault
        return TimeInterval(min(max(s, undoWindowRange.lowerBound), undoWindowRange.upperBound))
    }
}
