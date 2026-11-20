/// Lines of the outcome overlay (#56): what was heard (dimmed), the result, then the label.
public struct OutcomeLines: Equatable, Sendable {
    /// nil when there's no transcript or it matches the result.
    public var heard: String?
    public var result: String?
    /// Empty when an edit's action moved onto the result line.
    public var label: String
}

public enum OutcomeText {
    /// Characters per line before middle truncation; roughly three wrapped lines at the overlay's max width.
    public static let limit = 240

    /// `edit`: the label is an action ("Corrected"), shown as "Corrected → text" instead of on the label line.
    public static func lines(heard: String?, result: String?, label: String, edit: Bool, limit: Int = limit) -> OutcomeLines {
        let h = heard?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let r = result?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !r.isEmpty else { return OutcomeLines(heard: nil, result: nil, label: label) }
        let body = middle(r, limit: limit)
        return OutcomeLines(heard: h.isEmpty || h == r ? nil : middle(h, limit: limit),
                            result: edit ? "\(label) → \(body)" : body, label: edit ? "" : label)
    }

    /// At most `limit` characters, keeping the start and end around a "…".
    public static func middle(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let keep = limit - 1
        return text.prefix(keep - keep / 2) + "…" + text.suffix(keep / 2)
    }
}
