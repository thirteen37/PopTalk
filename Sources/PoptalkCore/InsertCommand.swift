import Foundation

/// A spoken command on PopTalk's last dictation, said with nothing selected (#49).
public enum InsertCommand: Equatable, Sendable {
    case scratch, deleteLastWord, deleteLastSentence
    /// "no, I meant X" / "change A to B": an edit run on the last insert as if it were selected.
    case change

    private static let scratchPattern = #"^(?:scratch|delete|remove|erase|undo)\s+(?:that|this|it)$"#
    private static let lastPattern = #"^(?:scratch|delete|remove|erase)\s+(?:the\s+)?last\s+(word|sentence)$"#
    private static let meant = #"^no[,.]?\s+i\s+meant\s+\S"#
    private static let changeAB = try! NSRegularExpression(pattern: #"^change\s+(.+?)\s+to\s+\S"#, options: .caseInsensitive)

    /// The command `utterance` gives on the last insert `last`, or nil to dictate it literally. A delete
    /// must be the whole utterance ("scratch that idea" is dictation); "change A to B" needs A in `last`.
    /// ponytail: English phrase list; add phrasings as history shows them.
    public init?(_ utterance: String, last: String) {
        let s = Pipeline.stripHesitations(utterance)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        func matches(_ p: String) -> Bool { s.range(of: p, options: [.regularExpression, .caseInsensitive]) != nil }
        if matches(Self.scratchPattern) { self = .scratch; return }
        if matches(Self.lastPattern) { self = s.lowercased().hasSuffix("word") ? .deleteLastWord : .deleteLastSentence; return }
        if matches(Self.meant) { self = .change; return }
        let ns = s as NSString
        if let m = Self.changeAB.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
           last.localizedCaseInsensitiveContains(ns.substring(with: m.range(at: 1))) {
            self = .change; return
        }
        return nil
    }

    /// The command a press gives on the last insert `last`, nil for none. A plain hold has one only with nothing
    /// selected; tap-then-hold (`editLast`, #80) always does: a delete runs in code (#83), anything else is `.change`.
    public static func forPress(_ utterance: String, last: String?, selection: String?, editLast: Bool) -> InsertCommand? {
        guard let last, editLast || selection == nil else { return nil }
        let command = InsertCommand(utterance, last: last)
        return editLast ? command ?? .change : command
    }

    /// What's left of `text` after this delete ("" removes it all); nil for `.change`.
    public func remainder(of text: String) -> String? {
        let unit: String.EnumerationOptions
        switch self {
        case .scratch: return ""
        case .change: return nil
        case .deleteLastWord: unit = .byWords
        case .deleteLastSentence: unit = .bySentences
        }
        var cut = text.startIndex
        text.enumerateSubstrings(in: text.startIndex..., options: [unit, .reverse, .substringNotRequired]) { _, r, _, stop in
            cut = r.lowerBound
            stop = true
        }
        let kept = String(text[..<cut])
        guard let end = kept.lastIndex(where: { !$0.isWhitespace }) else { return "" }
        return String(kept[...end])
    }

    /// The words `new` has in place of `old`'s, for the overlay ("Changed → Wednesday"); nil if none.
    public static func changed(from old: String, to new: String) -> String? {
        let a = old.split(whereSeparator: \.isWhitespace), b = new.split(whereSeparator: \.isWhitespace)
        let p = zip(a, b).prefix { $0 == $1 }.count
        let q = zip(a.dropFirst(p).reversed(), b.dropFirst(p).reversed()).prefix { $0 == $1 }.count
        let mid = b.dropFirst(p).dropLast(q)
        return mid.isEmpty ? nil : mid.joined(separator: " ")
    }
}

extension LastInsert {
    /// A voice command may act on this insert only within `window` seconds, while its field is focused
    /// and the field's text is exactly as PopTalk left it (so the edit can be verified).
    public func canAmend(focused: Target?, value: String?, now: Date = Date(), window: TimeInterval = 60) -> Bool {
        guard let fieldValue, focused == target, now.timeIntervalSince(at) < window else { return false }
        return value == fieldValue
    }
}
