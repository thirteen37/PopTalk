/// Lines of the outcome overlay (#56): what was heard (dimmed), the result, then the label.
public struct OutcomeLines: Equatable, Sendable {
    /// nil when there's no transcript or it matches the result.
    public var heard: String?
    public var result: String?
    /// Empty when an edit's action moved onto the result line.
    public var label: String
}

public enum OutcomeText {
    /// Characters per line before middle truncation: a first cut, a little over the overlay's four-line cap at its
    /// max width, which `fit` then enforces (#82).
    public static let limit = 400

    /// `edit`: the label is an action ("Corrected"), shown as "Corrected → text" instead of on the label line.
    public static func lines(heard: String?, result: String?, label: String, edit: Bool, limit: Int = limit) -> OutcomeLines {
        let h = heard?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let r = result?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !r.isEmpty else { return OutcomeLines(heard: nil, result: nil, label: label) }
        let body = middle(r, limit: limit)
        return OutcomeLines(heard: h.isEmpty || h == r ? nil : middle(h, limit: limit),
                            result: edit ? "\(label) → \(body)" : body, label: edit ? "" : label)
    }

    /// At most `limit` characters, keeping the start and end around a "…", cut between words when it can be (#82).
    public static func middle(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let keep = limit - 1
        var head = text.prefix(keep - keep / 2), tail = text.suffix(keep / 2)
        if !text[head.endIndex].isWhitespace, let i = head.lastIndex(where: \.isWhitespace) { head = head[..<i] }
        if !text[text.index(before: tail.startIndex)].isWhitespace, let i = tail.firstIndex(where: \.isWhitespace) { tail = tail[i...] }
        return head + "…" + tail
    }

    /// The longest `middle` cut of `text` that `fits` (the overlay's line cap, #82); `text` itself when it fits.
    public static func fit(_ text: String, _ fits: (String) -> Bool) -> String {
        guard !fits(text) else { return text }
        var (lo, hi, best) = (1, text.count - 1, "…")
        while lo <= hi {
            let mid = (lo + hi) / 2, s = middle(text, limit: mid)
            if fits(s) { (best, lo) = (s, mid + 1) } else { hi = mid - 1 }
        }
        return best
    }
}
