import Foundation

/// Speculative cleanup while the key is held (#43): at each pause the pipeline runs on the transcript so far, and the
/// overlay shows the result under the raw transcript. Nothing is applied before release; a run whose input matches
/// the final transcript is inserted at release instead of running again.
public enum LivePreview {
    /// Set around a speculative pipeline run: MLX reuses stored prefixes for it but neither stores new ones nor counts
    /// it as a recent prompt, so a growing transcript can't fill the cache with near-duplicates (`PrefixCache`).
    @TaskLocal public static var speculative = false

    /// "Live cleanup preview", default on; read per key press.
    public static let key = "liveCleanupPreview"
    public static func enabled(_ d: UserDefaults) -> Bool { d.object(forKey: key) as? Bool ?? true }

    /// The recording footer once Shift is seen (#131): the raw cue, then any other note ("Editing the last insert").
    /// The degraded mode's "raw — model loading" says the same thing, so the cue replaces it (as it does itself).
    public static func rawNote(_ note: String?) -> String {
        let cue = "Raw — no cleanup"
        guard let note, !note.lowercased().hasPrefix("raw") else { return cue }
        return "\(cue) · \(note)"
    }

    /// Edits preview only from this many words: shorter ones ("make this", "translate") are mostly unfinished and
    /// plan the wrong action, while short complete ones ("make it formal", "fix the typo") have three.
    public static let minEditWords = 3

    /// Run on `text` when it has new words since the last run and the speaker paused: a quiet tail, or no change
    /// since the previous tick (`previous`) for speakers whose room never goes quiet.
    public static func shouldRun(_ text: String, lastRun: String?, previous: String?, paused: Bool, edit: Bool) -> Bool {
        guard text != lastRun, paused || text == previous else { return false }
        return !edit || text.split(whereSeparator: \.isWhitespace).count >= minEditWords
    }

    /// The last `seconds` of 16 kHz audio are quiet: RMS under the silence floor or a quarter of the whole recording's.
    /// ponytail: relative energy threshold; a VAD if noisy rooms never read as paused (the unchanged-text rule covers them).
    public static func paused(_ samples: [Float], seconds: Double = 0.3) -> Bool {
        let n = Int(16_000 * seconds)
        guard samples.count >= n else { return false }
        func rms(_ s: ArraySlice<Float>) -> Float { (s.reduce(0) { $0 + $1 * $1 } / Float(s.count)).squareRoot() }
        return rms(samples.suffix(n)) < max(0.003, 0.25 * rms(samples[...]))
    }

    /// The final request is what the speculative run saw: same transcript, selection and screen.
    public static func sameInput(_ ran: Request, _ final: Request) -> Bool {
        ran.transcript == final.transcript && ran.selection == final.selection && ran.context == final.context
            && ran.cleanup == final.cleanup
    }

    /// A finished speculative result fit to insert as is; nil (cancelled), raw inserts, errors and "remember" edits
    /// (only the final run saves vocabulary) run again.
    public static func reusable(_ r: PipelineResult?) -> PipelineResult? {
        guard let r, !r.degraded, r.remembered == nil else { return nil }
        switch r.outcome {
        case .error: return nil
        // A failed or timed-out cleanup (e.g. while the GPU was busy) may succeed on a second try.
        case .insert(_, "Dictated (raw)"): return nil
        default: return r
        }
    }

    /// What the overlay shows of a speculative result: an edit's planned action ("Correct →"), the text, and the
    /// changed words in it (`marks`) and in the raw transcript (`rawMarks`, dictation only).
    public struct Shown: Equatable, Sendable {
        public var act: String?
        public var text: String
        public var marks: [Range<String.Index>]
        public var rawMarks: [Range<String.Index>]
    }

    /// Nil for an error: the overlay keeps the raw transcript alone.
    public static func shown(_ r: PipelineResult, input: String, selection: String?) -> Shown? {
        func edit(_ act: String, _ text: String) -> Shown {
            let d = WordDiff.changes(selection ?? "", text)
            // Nothing kept from the selection (a rewrite, a translation): highlighting all of it says nothing.
            let kept = d.added.count < text.split(whereSeparator: \.isWhitespace).count
            return Shown(act: act, text: text, marks: kept ? d.added : [], rawMarks: [])
        }
        switch r.outcome {
        case .insert(let s, _):
            let text = s.trimmingCharacters(in: .whitespacesAndNewlines)
            let d = WordDiff.changes(input, text)
            return Shown(act: nil, text: text, marks: d.added, rawMarks: d.removed)
        case .replaceSelection(let s, let label):
            let verb = ["Corrected": "Correct", "Replaced": "Replace", "Edited": "Edit"][label] ?? label
            return edit(verb + " →", s)
        case .insertBefore(let s): return edit("Insert before →", s.trimmingCharacters(in: .whitespaces))
        case .insertAfter(let s): return edit("Insert after →", s.trimmingCharacters(in: .whitespaces))
        case .nothing: return Shown(act: "No change", text: "", marks: [], rawMarks: [])
        case .error: return nil
        }
    }

    /// The light sweeping across a newly corrected word (iOS 27's): once per press per word, keyed by its text since
    /// every partial moves it. The overlay rebuilds on each partial, so a sweep carries on from when it started.
    public struct Sparkles: Sendable {
        public static let duration = 0.7, stagger = 0.08
        private var started: [String: Double] = [:]
        public init() {}

        /// `marks` (ranges in `text`) whose sweep hasn't ended at `now`, with when it starts; words new at `now` start
        /// then, `stagger` apart.
        public mutating func sweeping(_ marks: [NSRange], in text: String, now: Double) -> [(range: NSRange, start: Double)] {
            let ns = text as NSString
            var fresh = 0.0
            return marks.compactMap { r in
                let word = ns.substring(with: r)
                if started[word] == nil { started[word] = now + fresh * Self.stagger; fresh += 1 }
                let start = started[word]!
                return now < start + Self.duration ? (r, start) : nil
            }
        }
    }
}

/// Word-level diff for the live preview (#43): what a cleanup changed, ignoring punctuation and a sentence's capital.
public enum WordDiff {
    /// Ranges of the words in `old` the new text dropped or changed, and of the words in `new` that are new or changed.
    /// ponytail: O(n·m) LCS; fine for a dictation's few hundred words.
    public static func changes(_ old: String, _ new: String) -> (removed: [Range<String.Index>], added: [Range<String.Index>]) {
        let a = tokens(old), b = tokens(new)
        var lcs = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in a.indices.reversed() {
            for j in b.indices.reversed() {
                lcs[i][j] = same(a[i], b[j]) ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var (i, j) = (0, 0)
        var removed: [Range<String.Index>] = [], added: [Range<String.Index>] = []
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, same(a[i], b[j]) { i += 1; j += 1 }
            else if j < b.count, i == a.count || lcs[i][j + 1] >= lcs[i + 1][j] { added.append(b[j].range); j += 1 }
            else { removed.append(a[i].range); i += 1 }
        }
        return (removed, added)
    }

    private struct Token { let range: Range<String.Index>; let key: String; let sentenceStart: Bool }

    /// Whitespace-separated words, keyed by their letters and digits; punctuation-only tokens are left out.
    private static func tokens(_ s: String) -> [Token] {
        var out: [Token] = [], start = true
        for m in s.matches(of: /\S+/) {
            let key = String(m.output.filter { $0.isLetter || $0.isNumber })
            if !key.isEmpty { out.append(Token(range: m.range, key: key, sentenceStart: start)) }
            start = m.output.last.map { ".!?:".contains($0) } ?? false || (key.isEmpty && start)
        }
        return out
    }

    /// Equal words, or the same word with only its first letter's case changed at a sentence start.
    private static func same(_ a: Token, _ b: Token) -> Bool {
        if a.key == b.key { return true }
        guard a.sentenceStart || b.sentenceStart, a.key.dropFirst() == b.key.dropFirst() else { return false }
        return a.key.prefix(1).lowercased() == b.key.prefix(1).lowercased()
    }
}
