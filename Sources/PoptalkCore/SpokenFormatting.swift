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

    /// "scratch that" / "delete that" as its own unit (the "new line" delimiters) drops the sentence before it, from
    /// the previous . ! ? or newline (or the start), and the command; the next letter is capitalized (#98). With no
    /// sentence before it in this dictation (a lone command, or one that opens it) it stays literal: commands on the
    /// previous dictation are gone (#85). Undelimited ("I'll scratch that idea") it is dictation.
    /// ponytail: unpunctuated transcripts leave the command to the model, like "new line".
    public static func spokenCancel(_ s: String) -> String {
        // A lead-in "actually," / "wait," / "no," (as in the training templates) is part of the command.
        let command = /(?i)(?:^|[.!?,;:\n])\h*(?:(?:actually|wait|no)\h*[,;:]?\h*)*(?:scratch|delete)\h+that(?:\h*[.!?,;:]+|\h*$)\h*/
        // What stays of `before` once its last sentence is cancelled; nil when there is no sentence to cancel.
        func kept(_ before: Substring) -> Substring? {
            var body = before
            while let l = body.last, l.isWhitespace || ".!?,;:".contains(l) { body.removeLast() }
            guard !body.isEmpty else { return nil }
            guard var cut = body.lastIndex(where: { ".!?\n".contains($0) }) else { return "" }
            repeat { cut = body.index(after: cut) } while cut < body.endIndex && body[cut].isWhitespace
            return body[..<cut]
        }
        var out = s
        next: while true {
            for m in out.matches(of: command) {
                guard let keep = kept(out[..<m.range.lowerBound]) else { continue }
                let rest = out[m.range.upperBound...]
                out = rest.isEmpty ? String(keep).replacing(/\h+$/, with: "")
                    : keep + rest.prefix(1).uppercased() + rest.dropFirst()
                continue next
            }
            return out
        }
    }
}
