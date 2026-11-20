import Foundation

/// Poptalk's last paste, so a dictation into the same field soon after can be spaced even when the
/// cursor position is unknown (Electron apps, browsers, OCR-only context). Assumes the cursor is still after it.
/// ponytail: a click elsewhere or a typed Enter within `window` can give a stray space; read the real
/// preceding character (kAXStringForRangeParameterizedAttribute) where an app supports it.
public struct LastInsert<Target: Equatable> {
    public let target: Target
    public let text: String
    public let at: Date
    /// The history request that inserted it, when history is on.
    public let requestID: UUID?

    public init(target: Target, text: String, at: Date = Date(), requestID: UUID? = nil) {
        self.target = target
        self.text = text
        self.at = at
        self.requestID = requestID
    }

    /// The space to put before `s` being dictated into `target`.
    public func space(before s: String, into target: Target, now: Date = Date(), window: TimeInterval = 20) -> String {
        guard target == self.target, now.timeIntervalSince(at) < window, s.first?.isWhitespace == false
        else { return "" }
        return Pipeline.leadingSpace(after: text.last)
    }
}
