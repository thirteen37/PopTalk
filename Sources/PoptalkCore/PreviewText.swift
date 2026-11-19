/// Live-transcript text for the overlay.
public enum PreviewText {
    /// The last `limit` characters, starting at a word boundary when possible, prefixed with "…" if cut.
    public static func tail(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let cut = text.suffix(limit)
        if text[text.index(before: cut.startIndex)] == " " { return "…" + cut }
        guard let space = cut.firstIndex(of: " ") else { return "…" + cut }
        return "…" + cut[cut.index(after: space)...]
    }
}
