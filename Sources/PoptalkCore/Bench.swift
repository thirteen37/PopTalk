import Foundation

/// One line of `bench/cases.jsonl`. Unknown keys are ignored.
/// A case with `speak` (synthesized with `say`) or `audio` (a recording) starts from audio;
/// its `transcript` defaults to `speak` and is the reference for WER.
public struct BenchCase: Decodable, Sendable {
    public enum Kind: String, Codable, Sendable { case dictation, edit }

    public var id: String
    public var kind: Kind
    public var transcript: String
    public var selection: String?
    public var context: String?
    /// UTF-16 cursor offset into `context` (the AX text), like `ScreenSnapshot.cursorOffset`.
    public var cursor: Int?
    /// OCR'd window text, as captured when the AX text is thin.
    public var ocr: String?
    public var expectAction: String?
    public var expectExact: String?
    public var expectAnyOf: [String]?
    /// Case-sensitive (catches lost casing like "Meal Prep").
    public var mustContain: [String]
    /// Case-insensitive (catches "Thursday" or "presentation" however it's cased).
    public var mustNotContain: [String]
    /// `nil`: not checked. `.some(nil)`: must not offer. `.some(term)`: must offer `term`.
    public var expectVocabOffer: String??
    /// Output length must not exceed this times the selection (edits) or transcript (dictation).
    public var maxLengthRatio: Double?
    /// Text to synthesize, with an optional `say` voice and rate (words per minute).
    public var speak: String?
    public var voice: String?
    public var rate: Int?
    /// Path to a recording, relative to the repo root.
    public var audio: String?
    public var hasAudio: Bool { speak != nil || audio != nil }

    enum CodingKeys: String, CodingKey {
        case id, kind, transcript, selection, context, cursor, ocr, expectAction, expectExact, expectAnyOf
        case mustContain, mustNotContain, expectVocabOffer, maxLengthRatio, speak, voice, rate, audio
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(Kind.self, forKey: .kind)
        speak = try c.decodeIfPresent(String.self, forKey: .speak)
        voice = try c.decodeIfPresent(String.self, forKey: .voice)
        rate = try c.decodeIfPresent(Int.self, forKey: .rate)
        audio = try c.decodeIfPresent(String.self, forKey: .audio)
        transcript = try speak.map { try c.decodeIfPresent(String.self, forKey: .transcript) ?? $0 } ?? c.decode(String.self, forKey: .transcript)
        selection = try c.decodeIfPresent(String.self, forKey: .selection)
        context = try c.decodeIfPresent(String.self, forKey: .context)
        cursor = try c.decodeIfPresent(Int.self, forKey: .cursor)
        ocr = try c.decodeIfPresent(String.self, forKey: .ocr)
        expectAction = try c.decodeIfPresent(String.self, forKey: .expectAction)
        expectExact = try c.decodeIfPresent(String.self, forKey: .expectExact)
        expectAnyOf = try c.decodeIfPresent([String].self, forKey: .expectAnyOf)
        mustContain = try c.decodeIfPresent([String].self, forKey: .mustContain) ?? []
        mustNotContain = try c.decodeIfPresent([String].self, forKey: .mustNotContain) ?? []
        if c.contains(.expectVocabOffer) {
            expectVocabOffer = .some(try c.decodeNil(forKey: .expectVocabOffer) ? nil : c.decode(String.self, forKey: .expectVocabOffer))
        }
        maxLengthRatio = try c.decodeIfPresent(Double.self, forKey: .maxLengthRatio)
    }

    public static func load(jsonl: String) throws -> [BenchCase] {
        try jsonl.components(separatedBy: "\n").enumerated().compactMap { i, line in
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            do { return try JSONDecoder().decode(BenchCase.self, from: Data(line.utf8)) } catch {
                throw LLMError(description: "cases line \(i + 1): \(error)")
            }
        }
    }

    public var request: Request {
        Request(transcript: transcript, selection: selection,
                context: ScreenSnapshot(text: context ?? "", cursorOffset: cursor, ocrText: ocr ?? ""))
    }

    public func score(_ r: PipelineResult, seconds: Double) -> BenchRun {
        let (action, output): (String, String) = switch r.outcome {
        case .nothing: ("nothing", "")
        case let .insert(t, label): (label.contains("raw") ? "raw" : "insert", t)
        case let .replaceSelection(t, label): (["Replaced": "replace", "Corrected": "correct", "Edited": "edit"][label] ?? label, t)
        case let .insertBefore(t): ("insertBefore", t)
        case let .insertAfter(t): ("insertAfter", t)
        case let .error(m): ("error", m)
        }
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let offer = (r.vocabularyOffer ?? r.remembered)?.text
        var f: [String] = []
        if action == "error" { f.append("error: \(text)") }
        if action == "raw" { f.append("raw fallback") }
        if let a = expectAction, Self.family(a) != Self.family(action), action != "error" { f.append("action \(action), expected \(a)") }
        if let e = expectExact, e != text { f.append("not exactly \"\(e)\"") }
        if let any = expectAnyOf, !any.contains(text) { f.append("not any of \(any)") }
        f += mustContain.filter { !text.contains($0) }.map { "missing \"\($0)\"" }
        f += mustNotContain.filter { text.range(of: $0, options: .caseInsensitive) != nil }.map { "contains \"\($0)\"" }
        if let expected = expectVocabOffer, expected != offer {
            let msg = switch (offer, expected) {
            case let (o?, nil): "offered \"\(o)\", expected none"
            case let (nil, e?): "no vocabulary offer, expected \"\(e)\""
            default: "offered \"\(offer!)\", expected \"\(expected!)\""
            }
            f.append(msg)
        }
        let base = (selection ?? transcript).count
        if let ratio = maxLengthRatio, Double(text.count) > ratio * Double(base) {
            f.append("length \(text.count) > \(ratio) × \(base)")
        }
        var run = BenchRun(output: text, action: action, vocabOffer: offer, seconds: seconds, failures: f)
        run.modelAction = r.modelAction
        if let e = expectAction, let m = r.modelAction { run.modelActionOK = Self.family(e) == Self.family(m) }
        return run
    }

    /// #75 oracle: writes each `mustContain` term that is on screen with its exact spelling wherever `transcript`
    /// has it up to case and spacing ("meal prep" → "Meal Prep", "cloud front" → "CloudFront"). It reads the
    /// labels, so it's a ceiling for a screen-term matcher, not a feature.
    public func oracleRecase(_ transcript: String) -> String {
        let screen = (context ?? "") + " " + (ocr ?? "")
        return mustContain.filter { screen.contains($0) }.reduce(transcript) { t, term in
            let chars = term.filter { !$0.isWhitespace }.map { NSRegularExpression.escapedPattern(for: String($0)) }
            guard !chars.isEmpty, let re = try? NSRegularExpression(pattern: #"(?<!\w)"# + chars.joined(separator: #"\s*"#) + #"(?!\w)"#,
                                                                    options: .caseInsensitive) else { return t }
            return re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t),
                                               withTemplate: NSRegularExpression.escapedTemplate(for: term))
        }
    }

    /// replace / correct / edit all replace the selection identically; only the overlay label differs.
    static func family(_ action: String) -> String { ["replace", "correct", "edit"].contains(action) ? "replaceSelection" : action }
}

public struct BenchRun: Codable, Sendable {
    public var output: String
    public var action: String
    public var vocabOffer: String?
    public var seconds: Double
    public var failures: [String]
    /// Only for audio cases; `seconds` is then the LLM stage alone.
    public var speech: SpeechRun? = nil
    /// The edit model's own action before code guards (#54); nil without an edit model reply.
    public var modelAction: String? = nil
    /// `modelAction` is in `expectAction`'s family; nil when either is missing.
    public var modelActionOK: Bool? = nil
    public var passed: Bool { failures.isEmpty }
    /// A guard (insert ask, blank text) changed the model's action family.
    public var overridden: Bool { modelAction.map { BenchCase.family($0) != BenchCase.family(action) } ?? false }

    public init(output: String, action: String, vocabOffer: String?, seconds: Double, failures: [String]) {
        self.output = output
        self.action = action
        self.vocabOffer = vocabOffer
        self.seconds = seconds
        self.failures = failures
    }
}

public struct BenchCaseResult: Codable, Sendable {
    public var id: String
    public var kind: BenchCase.Kind
    public var runs: [BenchRun]
    public init(id: String, kind: BenchCase.Kind, runs: [BenchRun]) {
        self.id = id
        self.kind = kind
        self.runs = runs
    }
}

public struct BenchSummary: Sendable {
    public var kind: BenchCase.Kind
    public var runs: Int, passed: Int, rawFallbacks: Int, errors: Int
    public var median: Double, p90: Double, max: Double
    /// Runs with a scorable model action, how many matched, and how many a guard overrode (#54).
    public var modelActionRuns = 0, modelActionPassed = 0, overrides = 0
}

/// A results file: `bench/results/<date>-<provider>-<model>[-<filter>].json` (see `fileName`).
public struct BenchReport: Codable, Sendable {
    public var date: String
    /// provider, models, Apple variant/contextSize, macOS build, hw.model, …
    public var provider: [String: String]
    public var cases: [BenchCaseResult]

    public init(date: String, provider: [String: String], cases: [BenchCaseResult]) {
        self.date = date
        self.provider = provider
        self.cases = cases
    }

    public func summaries() -> [BenchSummary] {
        [BenchCase.Kind.dictation, .edit].compactMap { kind in
            let runs = cases.filter { $0.kind == kind }.flatMap(\.runs).filter { $0.speech == nil }
            guard !runs.isEmpty else { return nil }
            let t = runs.map(\.seconds).sorted()
            var s = BenchSummary(
                kind: kind, runs: runs.count, passed: runs.filter(\.passed).count,
                rawFallbacks: runs.filter { $0.action == "raw" }.count, errors: runs.filter { $0.action == "error" }.count,
                median: median(t),
                p90: t[Int((0.9 * Double(t.count)).rounded(.up)) - 1], max: t.last!)
            s.modelActionRuns = runs.filter { $0.modelActionOK != nil }.count
            s.modelActionPassed = runs.filter { $0.modelActionOK == true }.count
            s.overrides = runs.filter(\.overridden).count
            return s
        }
    }

    public func table() -> String {
        let rows = summaries().map {
            String(format: "%@ %3d/%-3d %5.0f%%  %6.2fs %6.2fs %6.2fs  %4d %4d", $0.kind.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0),
                   $0.passed, $0.runs, 100 * Double($0.passed) / Double($0.runs), $0.median, $0.p90, $0.max, $0.rawFallbacks, $0.errors)
                // Model action (#54): the edit model's own pick vs expectAction, and guard overrides.
                + ($0.kind == .dictation ? "" : String(format: "  %3d/%-3d %5.0f%%  %4d", $0.modelActionPassed, $0.modelActionRuns,
                                                       100 * Double($0.modelActionPassed) / Double(Swift.max($0.modelActionRuns, 1)), $0.overrides))
        }
        let lm = rows.isEmpty ? nil : (["kind       pass        %   median    p90    max   raw  err  model        %   ovr"] + rows).joined(separator: "\n")
        return [lm, speechTable()].compactMap { $0 }.joined(separator: "\n\n")
    }

    /// Failing cases, with each distinct output across runs and how often it occurred.
    public func failureDetails(_ cases: [BenchCase]) -> String {
        let byID = Dictionary(cases.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return self.cases.filter { $0.runs.contains { !$0.passed } }.map { r in
            let c = byID[r.id]
            var lines = ["✗ \(r.id): \(r.runs.filter(\.passed).count)/\(r.runs.count)  \"\(c?.transcript ?? "")\""
                + (c?.selection.map { " | selection \"\($0)\"" } ?? "")]
            var seen: [String: (Int, BenchRun)] = [:], order: [String] = []
            for run in r.runs {
                let key = run.action + "\u{0}" + run.output + "\u{0}" + (run.modelAction ?? "")
                if seen[key] == nil { order.append(key) }
                seen[key, default: (0, run)].0 += 1
            }
            for key in order {
                let (n, run) = seen[key]!
                lines.append("    \(n)× \(run.action)" + (run.overridden ? " (model \(run.modelAction!))" : "") + ": \"\(run.output)\""
                    + (run.vocabOffer.map { " offer \"\($0)\"" } ?? ""))
                if !run.passed { lines.append("       " + run.failures.joined(separator: "; ")) }
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    /// Lines describing what changed from `a` to `b`: metadata warnings, then per-case pass-rate changes.
    public static func compare(_ a: BenchReport, _ b: BenchReport) -> [String] {
        var lines = Set(a.provider.keys).union(b.provider.keys).sorted().compactMap { k -> String? in
            guard ["provider", "variant", "cleanupModel", "editModel", "quantization", "speechModel", "boost", "cbw", "minSimilarity"].contains(k), a.provider[k] != b.provider[k] else { return nil }
            return "warning: \(k) differs: \(a.provider[k] ?? "-") vs \(b.provider[k] ?? "-")"
        }
        let bByID = Dictionary(b.cases.map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x })
        let aIDs = Set(a.cases.map(\.id))
        for ca in a.cases {
            guard let cb = bByID[ca.id] else { lines.append("only in a: \(ca.id)"); continue }
            let ra = Double(ca.runs.filter(\.passed).count) / Double(max(ca.runs.count, 1))
            let rb = Double(cb.runs.filter(\.passed).count) / Double(max(cb.runs.count, 1))
            guard ra != rb else { continue }
            lines.append("\(rb < ra ? "regressed" : "improved ") \(ca.id): \(ca.runs.filter(\.passed).count)/\(ca.runs.count) → \(cb.runs.filter(\.passed).count)/\(cb.runs.count)")
        }
        lines += b.cases.filter { !aIDs.contains($0.id) }.map { "only in b: \($0.id)" }
        // Run by run: at temperature 0 a change that shouldn't affect outputs (e.g. the prompt cache, #42) must match.
        let pairs = a.cases.compactMap { ca in bByID[ca.id].map { (ca.id, zip(ca.runs, $0.runs)) } }
            .flatMap { id, runs in runs.enumerated().map { ("\(id)#\($0.offset + 1)", $0.element.0, $0.element.1) } }
        let differ = pairs.filter { $0.1.output != $0.2.output || $0.1.action != $0.2.action }.map(\.0)
        lines.append(differ.isEmpty ? "outputs identical in \(pairs.count)/\(pairs.count) runs"
                     : "outputs differ in \(differ.count)/\(pairs.count) runs: " + differ.joined(separator: " "))
        if let sa = a.summaries().first(where: { $0.kind == .edit }), let sb = b.summaries().first(where: { $0.kind == .edit }) {
            let (ma, mb) = ("\(sa.modelActionPassed)/\(sa.modelActionRuns)", "\(sb.modelActionPassed)/\(sb.modelActionRuns)")
            if ma != mb { lines.append("edit model action \(ma) → \(mb)") }
            if sa.overrides != sb.overrides { lines.append("edit guard overrides \(sa.overrides) → \(sb.overrides)") }
        }
        return lines + compareSpeech(a, b)
    }
}
