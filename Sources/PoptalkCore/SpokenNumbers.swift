import Foundation

extension Pipeline {
    /// Spoken numbers → digits (inverse text normalization, #59), house style, conservative:
    /// - One run of number words (spaces, hyphens, "and" after hundred/thousand) that reads as a single number
    ///   becomes digits when it is 10 or more: "fifty two" → 52, "one hundred and five" → 105,
    ///   "two thousand twenty six" → 2026, "three point five" → 3.5; 10,000 and up get commas.
    /// - Zero to nine stay words in prose ("two people"), except after a cue (issue 5, Q3, v2, #9) or a unit.
    /// - Units: "twenty five percent" → 25%, "five dollars" → $5. Times need am/pm: "three thirty pm" → 3:30 PM.
    /// - Ordinals only when compound: "twenty first" → 21st; "first", "tenth" alone stay. "second" counts only right
    ///   after a tens word ("twenty second floor" → 22nd floor), and not after "a"/"an" or before a duration noun
    ///   (`durations`): "a fifty second delay", "the thirty second timeout" stay durations.
    /// - Cents join whole dollars: "five dollars and fifty cents" → $5.50. Bare cents are a plain word ("50 cents").
    /// - "minus"/"negative" before a number → "-5" (ASCII), except after a number or "plus or" ("ten minus two").
    /// - A run that isn't one number stays as said: "one two three", "twelve fifty", "nineteen ninety nine".
    ///   A run can't start with hundred/thousand: "a hundred times".
    /// - A 0–9 word corrected to digits goes to digits too: "three actually twenty" → "3 actually 20" (`correctedSmall`).
    /// - Never half a phrase (#125): a run next to number words it can't absorb ("twenty oh five", "twelve dollars fifty",
    ///   "ten twelve and fourteen") leaves the whole phrase as words, for the model to write.
    public static func spokenNumbers(_ s: String) -> String {
        let s = s.replacing(time) { m in
            var t = "\(number[m.1.lowercased()]!.value)"
            if let mins = m.2?.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init) {
                t += mins[0] == "oh" ? ":0\(number[mins[1]]!.value)" : ":\(parse(mins)!.value)"
            }
            return t + " \(m.3.uppercased())M"
        }
        let words = s.matches(of: /[A-Za-z]+(?:'[A-Za-z]+)*/).map { (range: $0.range, text: $0.output.lowercased()) }
        // Adjacent: only whitespace or a single hyphen between.
        func adjacent(_ a: Int, _ b: Int) -> Bool {
            guard b < words.count else { return false }
            let gap = s[words[a].range.upperBound..<words[b].range.lowerBound]
            return gap == "-" || (!gap.isEmpty && gap.allSatisfy(\.isWhitespace))
        }
        func isNumber(_ k: Int) -> Bool { k < words.count && number[words[k].text] != nil }
        func extend(_ i: Int) -> Int {
            var j = i + 1
            while adjacent(j - 1, j), number[words[j - 1].text]?.ordinal != true {
                if words[j].text == "second" {
                    // "twenty second" → 22nd, but "a fifty second delay" / "the thirty second timeout" are durations.
                    let durationUnit = (i > 0 && adjacent(i - 1, i) && ["a", "an"].contains(words[i - 1].text))
                        || (adjacent(j, j + 1) && durations.contains(words[j + 1].text))
                    if number[words[j - 1].text]?.kind == .tens, !durationUnit { j += 1 }
                    break
                }
                if isNumber(j) { j += 1 }
                else if words[j].text == "and", [.hundred, .scale].contains(number[words[j - 1].text]?.kind), adjacent(j, j + 1),
                        isNumber(j + 1) { j += 1 }
                else { break }
            }
            return j
        }
        // Every run of number words, converted or not: `next` is the first word after it (past a unit), `edit` its digits.
        var runs: [(i: Int, next: Int, ordinal: Bool, edit: (start: String.Index, end: String.Index, text: String)?)] = []
        var i = 0, done = s.startIndex
        while i < words.count {
            guard let first = number[words[i].text] else { i += 1; continue }
            var j = extend(i)
            // "a hundred and fifty": no leading number, leave the whole run.
            guard first.kind != .hundred, first.kind != .scale, let parsed = parse(words[i..<j].map(\.text)) else {
                runs.append((i, j, false, nil)); i = j; continue
            }
            let (value, ordinal) = parsed
            var text = value >= 10_000 ? value.formatted(.number.locale(Locale(identifier: "en_US"))) : "\(value)"
            var forced = false, signed = false
            if !ordinal, words.indices.contains(j + 1), words[j].text == "point", adjacent(j - 1, j),
               case let digits = (j + 1..<words.count).prefix(while: { k in adjacent(k - 1, k) && fraction[words[k].text] != nil }),
               !digits.isEmpty {
                text += "." + digits.map { fraction[words[$0].text]! }.joined()
                j = digits.last! + 1
                forced = true
            }
            var end = words[j - 1].range.upperBound, next = j
            if !ordinal, adjacent(j - 1, j), ["percent", "dollar", "dollars"].contains(words[j].text) {
                text = words[j].text == "percent" ? text + "%" : "$" + text
                end = words[j].range.upperBound
                next = j + 1
                forced = true
                // "five dollars and fifty cents" → $5.50 (1–99 cents, whole dollars only).
                var k = j + 1
                if adjacent(j, k), words[k].text == "and" { k += 1 }
                if text.hasPrefix("$"), !text.contains("."), adjacent(k - 1, k), isNumber(k), case let e = extend(k),
                   adjacent(e - 1, e), ["cent", "cents"].contains(words[e].text),
                   let c = parse(words[k..<e].map(\.text)), !c.ordinal, (1...99).contains(c.value) {
                    text += c.value < 10 ? ".0\(c.value)" : ".\(c.value)"
                    end = words[e].range.upperBound
                    j = e + 1; next = j
                }
            }
            // "minus five" / "negative five" → -5; not in an expression ("ten minus two") or "plus or minus".
            if !ordinal, i > 0, adjacent(i - 1, i), ["minus", "negative"].contains(words[i - 1].text),
               !(i > 1 && adjacent(i - 2, i - 1) && (number[words[i - 2].text] != nil || ["plus", "or"].contains(words[i - 2].text))),
               s[..<words[i - 1].range.lowerBound].last(where: { !$0.isWhitespace })?.isNumber != true {
                text = "-" + text
                forced = true
                signed = true
            }
            var start = words[i].range.lowerBound
            let cue = i > 0 && adjacent(i - 1, i) ? words[i - 1].text : nil
            let hash = s[done..<start].wholeMatch(of: /(?s).*#\h*/) != nil
            if ordinal {
                guard j - i > 1 else { runs.append((i, j, true, nil)); i = j; continue }
                let tail = value % 100
                text += (11...13).contains(tail) ? "th" : [1: "st", 2: "nd", 3: "rd"][value % 10] ?? "th"
            } else if value < 10, !forced, !hash, !cues.contains(cue ?? "") {
                runs.append((i, next, false, nil)); i = j; continue
            }
            if hash { start = s[..<start].lastIndex(of: "#").map { s.index(after: $0) } ?? start }
            else if cue == "q" || cue == "v" { start = words[i - 1].range.upperBound }
            if signed { start = words[i - 1].range.lowerBound }
            runs.append((i, next, ordinal, (start, end, text)))
            done = end
            i = j
        }
        // #125: back off rather than hand the model a half-converted phrase ("20 oh five", "$12 50", "ten twelve and 14").
        // Runs chain when only a comma and/or "and" sits between them (a list), or nothing / "oh" + a digit word does
        // (tight: "twelve dollars fifty", "twenty oh five"). A chain that is tight anywhere, or has a run that stays
        // words, stays words whole. A list that converts throughout keeps its digits: "10, 20 and 30". Ordinals don't chain.
        func link(_ a: Int) -> (list: Bool, tight: Bool) {
            let (x, y) = (runs[a], runs[a + 1])
            guard !x.ordinal, !y.ordinal else { return (false, false) }
            let gap = s[words[x.next - 1].range.upperBound..<words[y.i].range.lowerBound].lowercased()
            if x.next == y.i, adjacent(x.next - 1, y.i) { return (true, true) }
            if x.next + 1 == y.i, words[x.next].text == "oh", adjacent(x.next - 1, x.next), adjacent(x.next, y.i),
               number[words[y.i].text]?.kind == .unit { return (true, true) }
            return (gap.wholeMatch(of: /\s*,?\s*(?:and\s+)?/) != nil, false)
        }
        var a = 0
        while a < runs.count {
            var b = a, tight = false
            while b + 1 < runs.count, case let l = link(b), l.list { tight = tight || l.tight; b += 1 }
            if b > a, tight || runs[a...b].contains(where: { $0.edit == nil }) {
                for k in a...b { runs[k].edit = nil }
            }
            a = b + 1
        }
        var out = ""
        done = s.startIndex
        for case let (start, end, text)? in runs.map(\.edit) {
            out += s[done..<start] + text
            done = end
        }
        return (out + s[done...]).replacing(correctedSmall) { "\(number[$0.1.lowercased()]!.value)" }
    }

    /// #106: a 0–9 word corrected to digits ("three actually 20") goes to digits too: v6 misreads the mixed form and
    /// writes a number never said. Upward only; "30 actually three" already resolves. Cues: actually, no, wait,
    /// sorry, I mean, make that / make it, in any run.
    nonisolated(unsafe) private static let correctedSmall =
        /(?i)\b(zero|one|two|three|four|five|six|seven|eight|nine)(?=[,;]?\s+(?:(?:actually|no|wait|sorry|i mean|make (?:that|it))[,;]?\s+)+[-$]?\d)/

    /// A number word `spokenNumbers` reads ("twelve", "ninety", "thousand", "third"), lowercased.
    static func isNumberWord(_ w: some StringProtocol) -> Bool { number[String(w)] != nil }

    private enum NumberKind { case unit, teen, tens, hundred, scale }

    private static let number: [String: (value: Int, kind: NumberKind, ordinal: Bool)] = {
        var d: [String: (Int, NumberKind, Bool)] = [:]
        let units = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
        let teens = ["ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
        let tens = ["twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
        for (v, w) in units.enumerated() { d[w] = (v, .unit, false) }
        for (v, w) in teens.enumerated() { d[w] = (v + 10, .teen, false); d[w + "th"] = (v + 10, .teen, true) }
        for (v, w) in tens.enumerated() { d[w] = ((v + 2) * 10, .tens, false); d[String(w.dropLast()) + "ieth"] = ((v + 2) * 10, .tens, true) }
        for (w, v) in ["first": 1, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9] {
            d[w] = (v, .unit, true)
        }
        d["twelveth"] = nil; d["twelfth"] = (12, .teen, true)
        d["hundred"] = (100, .hundred, false); d["hundredth"] = (100, .hundred, true)
        for (w, v) in ["thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000] {
            d[w] = (v, .scale, false); d[w + "th"] = (v, .scale, true)
        }
        return d
    }()

    private static let fraction: [String: String] = [
        "zero": "0", "oh": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7",
        "eight": "8", "nine": "9"]

    /// Nouns that make a preceding "N second" a duration, not an ordinal.
    private static let durations: Set<String> = [
        "delay", "timeout", "wait", "pause", "break", "interval", "gap", "lag", "window", "countdown", "cooldown",
        "limit", "mark", "clip", "video", "ad", "spot", "segment", "rule", "sleep", "nap", "buffer", "grace", "warning"]

    private static let cues: Set<String> = ["issue", "number", "version", "v", "page", "step", "room", "item", "pr", "option", "q"]

    nonisolated(unsafe) private static let time: Regex<(Substring, Substring, Substring?, Substring)> = {
        let unit = "one|two|three|four|five|six|seven|eight|nine"
        let minutes = "oh[\\s-]+(?:\(unit))|(?:ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen)"
            + "|(?:twenty|thirty|forty|fifty)(?:[\\s-]+(?:\(unit)))?"
        // Without minutes, "am I" is the verb: "which one am I" (#136).
        return try! Regex("(?i)\\b(\(unit)|ten|eleven|twelve)(?:[\\s-]+(\(minutes))|(?!\\s+am\\s+I\\b))\\s+([ap])(?:\\.m\\.|m\\b)",
                         as: (Substring, Substring, Substring?, Substring).self)
    }()

    /// One number from its words, or nil when they aren't a single number ("twelve fifty", "one two").
    private static func parse(_ ws: [String]) -> (value: Int, ordinal: Bool)? {
        var total = 0, current = 0, last: NumberKind?, lastScale = Int.max, ordinal = false
        for w in ws {
            if w == "and" { continue }  // extend() only lets "and" through after hundred/thousand.
            guard let (v, kind, ord) = (w == "second" ? (2, .unit, true) : number[w]).map({ ($0.value, $0.kind, $0.ordinal) }), !ordinal else { return nil }
            ordinal = ord
            switch (last, kind) {
            case (nil, .unit), (nil, .teen), (nil, .tens): current = v
            case (.tens, .unit), (.hundred, .unit), (.hundred, .teen), (.hundred, .tens),
                 (.scale, .unit), (.scale, .teen), (.scale, .tens):
                guard v > 0 else { return nil }
                current += v
            case (.unit, .hundred), (.teen, .hundred):
                guard current < 100 else { return nil }
                current *= 100
            case (.unit, .scale), (.teen, .scale), (.tens, .scale), (.hundred, .scale):
                guard v < lastScale else { return nil }
                total += current * v; current = 0; lastScale = v
            default: return nil
            }
            last = kind
        }
        return last.map { _ in (total + current, ordinal) }
    }
}
