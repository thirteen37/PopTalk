import Foundation

extension Pipeline {
    /// Unambiguous spoken formatting, done in code before cleanup and kept in the raw fallback (#48):
    /// - "quote … unquote" / "quote … end quote" → “…” (curly, for prose). A lone "quote" is a word, and so is
    ///   "quote and unquote" (a body of only "and"/"or" is a mention, #69).
    /// - "open paren … close paren" (or "parenthesis") → (…).
    /// - "new line" / "new paragraph" → "\n" / "\n\n", only as its own punctuation-delimited unit: right after
    ///   the start, a newline or . ! ? , ; : and right before the end or one of those marks (which are dropped;
    ///   the next letter is capitalized). "draw a new line on the chart" stays.
    /// ponytail: unpunctuated transcripts ("hi team new paragraph the build") never break lines; loosen if
    /// history shows Parakeet dropping the punctuation around the command.
    public static func spokenFormatting(_ s: String) -> String {
        func mention(_ body: Substring) -> Bool { ["and", "or"].contains(body.lowercased()) }
        var out = s
            .replacing(/(?i)\bquote\b[,:]?\s+(.+?)[,.]?\s+(?:unquote|end\s+quote)\b/) {
                mention($0.1) ? String($0.0) : "“\($0.1)”"
            }
            .replacing(/(?i)\bopen\s+paren(?:thesis)?\b[,:]?\s+(.+?)[,.]?\s+close\s+paren(?:thesis)?\b/) {
                mention($0.1) ? String($0.0) : "(\($0.1))"
            }
        let lineBreak = /(?i)(^|[.!?,;:\n])\h*new\h+(line|paragraph)(?:\h*[.!?,;:]+|\h*$)\h*/
        while let m = out.firstMatch(of: lineBreak) {
            out.replaceSubrange(m.range, with: m.1 + (m.2.lowercased() == "line" ? "\n" : "\n\n"))
        }
        return out.replacing(/\n(\p{Ll})/) { "\n" + $0.1.uppercased() }
    }
}
