import Foundation

/// The text around a dictation in its field right after the paste (#86), to find the dictation again once the user
/// has typed over it. In UTF-16 units, as AX counts them. Held in memory only.
public struct InsertAnchors: Equatable, Sendable {
    let before: [UInt16], after: [UInt16]

    /// `inserted` (spacing included) as it lies in the field's `value`: ending at `caret` (AX selection end, UTF-16)
    /// when the text there matches, else its only occurrence. Nil when it isn't there or occurs more than once.
    public init?(value: String, inserted: String, caret: Int?) {
        let v = Array(value.utf16), ins = Array(inserted.utf16)
        guard !ins.isEmpty else { return nil }
        var start: Int
        if let caret, caret >= ins.count, caret <= v.count, v[(caret - ins.count)..<caret].elementsEqual(ins) {
            start = caret - ins.count
        } else {
            let found = value.ranges(of: inserted)
            guard found.count == 1 else { return nil }
            start = found[0].lowerBound.utf16Offset(in: value)
        }
        before = Array(v[..<start])
        after = Array(v[(start + ins.count)...])
    }

    /// What lies between the anchors in `value` now; nil once the text before or after the dictation changed.
    /// ponytail: exact match on the whole rest of the field, so an edit elsewhere in it (or an app that rewrites the
    /// field) loses the dictation; match only nearby text if that turns out common.
    public func span(in value: String) -> String? {
        let v = Array(value.utf16)
        guard v.count >= before.count + after.count, v.starts(with: before), v.reversed().starts(with: after.reversed())
        else { return nil }
        return String(decoding: v[before.count..<(v.count - after.count)], as: UTF16.self)
    }
}

/// How the user's typed version of a dictation differs from what PopTalk inserted (#86), word by word, and why
/// each change was likely needed, judged against the transcript the pipeline got.
public struct TypedCorrection: Equatable, Sendable {
    public enum Cause: Equatable, Sendable {
        /// The replaced words came from the transcript and the user's didn't: speech recognition misheard.
        case misheard
        /// The transcript had the user's words (perhaps cased or punctuated differently), or never had the words the
        /// user deleted: the cleanup changed, dropped or added them.
        case cleanup
        /// Rewording, or deleting what was said.
        case other
    }

    public struct Change: Equatable, Sendable {
        /// Whitespace-separated words as inserted and as typed; either may be empty.
        public var old: [String], new: [String]
        public var cause: Cause

        public init(old: [String], new: [String], cause: Cause) { (self.old, self.new, self.cause) = (old, new, cause) }
    }

    /// The user's version of the dictation, without text typed on before or after it.
    public var text: String
    public var changes: [Change]

    /// Nil when nothing but whitespace changed, the dictation was deleted, or the only change is text typed before or
    /// after it.
    /// ponytail: classification checks whether words occur anywhere in the transcript, not where; a common word the
    /// user restores counts as the cleanup's fault even if it was said elsewhere. Align words to the transcript if
    /// that mislabels too much.
    public init?(inserted: String, span: String, transcript: String) {
        let old = Self.words(inserted).map { String(inserted[$0]) }
        let spanWords = Self.words(span)
        var new = spanWords.map { String(span[$0]) }
        let diff = new.difference(from: old)
        func offsets(_ cs: [CollectionDifference<String>.Change]) -> Set<Int> {
            Set(cs.map { switch $0 { case .remove(let o, _, _), .insert(let o, _, _): o } })
        }
        let removed = offsets(diff.removals), added = offsets(diff.insertions)
        var hunks: [(old: Range<Int>, new: Range<Int>)] = []
        var (i, j) = (0, 0)
        while i < old.count || j < new.count {
            let (i0, j0) = (i, j)
            while (i < old.count && removed.contains(i)) || (j < new.count && added.contains(j)) {
                if i < old.count && removed.contains(i) { i += 1 } else { j += 1 }
            }
            if (i0, j0) != (i, j) { hunks.append((i0..<i, j0..<j)) } else { (i, j) = (i + 1, j + 1) }
        }
        // Typed before or after the dictation, not a change to it. Typing straight on after fixing its last words
        // shares their hunk: cut that after the first typed word ending the way the dictation ended (".", "!", "?").
        // ponytail: without such an ending, the typed-on text stays in; a missing last word put back is lost.
        var (lo, hi) = (0, new.count)
        if let h = hunks.first, h.old.isEmpty, h.new.lowerBound == 0 { lo = h.new.upperBound; hunks.removeFirst() }
        if let h = hunks.last, h.old.upperBound == old.count {
            if h.old.isEmpty {
                hi = h.new.lowerBound
                hunks.removeLast()
            } else if let end = old.last?.last, ".!?".contains(end),
                      let k = new[h.new].firstIndex(where: { $0.last == end }) {
                hi = k + 1
                hunks[hunks.count - 1].new = h.new.lowerBound..<hi
            }
        }
        guard !hunks.isEmpty, lo < hi else { return nil }
        text = String(span[spanWords[lo].lowerBound..<spanWords[hi - 1].upperBound])
        new = Array(new[..<hi])
        let said = Self.words(transcript).map { Self.normalized(transcript[$0]) }
        changes = hunks.map { h in
            let (o, n) = (Array(old[h.old]), Array(new[h.new]))
            let cause: Cause = if !n.isEmpty, Self.contains(said, n) { .cleanup }
                else if n.isEmpty, !Self.contains(said, o) { .cleanup }
                else if !n.isEmpty, !o.isEmpty, Self.contains(said, o) { .misheard }
                else { .other }
            return Change(old: o, new: n, cause: cause)
        }
    }

    /// A vocabulary term to offer: the first misheard change of up to three words each way whose new text looks like
    /// a term (a word `isWord` doesn't know, a capital inside a word, or a digit). The heard words, lowercased and
    /// without punctuation, are its alias. A term saved in `known` is offered again only for a heard form it doesn't
    /// have as an alias yet (`VocabularyStore.add` merges it in).
    public func offer(known: [VocabTerm], isWord: (String) -> Bool) -> VocabTerm? {
        for c in changes where c.cause == .misheard && c.old.count <= 3 && c.new.count <= 3 {
            let words = c.new.map(Self.trimmed).filter { !$0.isEmpty }
            let text = words.joined(separator: " ")
            let heard = c.old.map(Self.normalized).joined(separator: " ")
            let saved = known.first { $0.text.lowercased() == text.lowercased() }
            guard !text.isEmpty, saved?.aliases.contains(where: { $0.lowercased() == heard }) != true,
                  words.contains(where: { w in !isWord(w) || w.contains(where: \.isNumber) || w.dropFirst().contains(where: \.isUppercase) })
            else { continue }
            return VocabTerm(text: text, aliases: [heard])
        }
        return nil
    }

    static func words(_ s: String) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = [], start: String.Index?
        for i in s.indices {
            if s[i].isWhitespace { if let st = start { out.append(st..<i); start = nil } } else if start == nil { start = i }
        }
        if let start { out.append(start..<s.endIndex) }
        return out
    }

    static func trimmed(_ w: some StringProtocol) -> String {
        w.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
    }

    static func normalized(_ w: some StringProtocol) -> String { trimmed(w).lowercased() }

    /// Whether `words`, normalised, occur in a row in `said`.
    static func contains(_ said: [String], _ words: [String]) -> Bool {
        let w = words.map(normalized)
        return !w.isEmpty && w.count <= said.count && (0...(said.count - w.count)).contains { said[$0..<($0 + w.count)].elementsEqual(w) }
    }
}
