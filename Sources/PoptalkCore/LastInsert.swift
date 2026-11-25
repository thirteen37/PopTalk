import Foundation

/// PopTalk's last paste, so a dictation into the same field soon after can be spaced even when the
/// cursor position is unknown (Electron apps, browsers, OCR-only context). Assumes the cursor is still after it.
/// ponytail: a click elsewhere or a typed Enter within `window` can give a stray space; read the real
/// preceding character (kAXStringForRangeParameterizedAttribute) where an app supports it.
public struct LastInsert<Target: Equatable> {
    public let target: Target
    public let text: String
    public let at: Date
    /// The history request that inserted it, when history is on.
    public let requestID: UUID?
    /// Set when it was inserted raw while the language model loaded (#39).
    public let reprocess: RawInsert?
    /// Spacing pasted before `text`.
    public let prefix: String
    /// Set when pasted into a terminal (#79), where it's taken back by backspaces instead.
    public let terminal: TerminalStamp?
    /// Set when pasted into an app whose ⌘Z ignores the paste (#93, `AXUndo`), where it's deleted directly instead.
    public let axUndo: TerminalStamp?
    /// Parakeet's unboosted text for this take, in memory only, for `redictated` (#95).
    public let rawTranscript: String?
    /// The field's text right after the paste (nil: unreadable), for `isUntouched` (#110).
    public var fieldValue: String?
    /// When the insert was seen deleted (or the field sent, #94) or undone, for `redictated` (#95).
    public var deletedAt: Date?

    public init(target: Target, text: String, at: Date = Date(), requestID: UUID? = nil, reprocess: RawInsert? = nil,
                prefix: String = "", terminal: TerminalStamp? = nil, axUndo: TerminalStamp? = nil, rawTranscript: String? = nil) {
        self.target = target
        self.text = text
        self.at = at
        self.requestID = requestID
        self.reprocess = reprocess
        self.prefix = prefix
        self.terminal = terminal
        self.axUndo = axUndo
        self.rawTranscript = rawTranscript
    }

    /// Whether `target` is focused with its text exactly as PopTalk left it, so the insert can be found and edited.
    public func isUntouched(focused: Target?, value: String?) -> Bool {
        fieldValue != nil && focused == target && value == fieldValue
    }

    /// The space to put before `s` being dictated into `target`.
    public func space(before s: String, into target: Target, now: Date = Date(), window: TimeInterval = 20) -> String {
        guard target == self.target, deletedAt == nil, now.timeIntervalSince(at) < window, s.first?.isWhitespace == false
        else { return "" }
        return Pipeline.leadingSpace(after: text.last)
    }
}
