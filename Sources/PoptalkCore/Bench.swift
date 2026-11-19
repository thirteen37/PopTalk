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
        if let a = expectAction, a != action, action != "error" { f.append("action \(action), expected \(a)") }
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
        return BenchRun(output: text, action: action, vocabOffer: offer, seconds: seconds, failures: f)
    }
}

public struct BenchRun: Codable, Sendable {
    public var output: String
    public var action: String
    public var vocabOffer: String?
    public var seconds: Double
    public var failures: [String]
    /// Only for audio cases; `seconds` is then the LLM stage alone.
    public var speech: SpeechRun? = nil
    public var passed: Bool { failures.isEmpty }

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
}

/// A results file: `bench/results/<date>-<provider>-<model>.json`.
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
            return BenchSummary(
                kind: kind, runs: runs.count, passed: runs.filter(\.passed).count,
                rawFallbacks: runs.filter { $0.action == "raw" }.count, errors: runs.filter { $0.action == "error" }.count,
                median: median(t),
                p90: t[Int((0.9 * Double(t.count)).rounded(.up)) - 1], max: t.last!)
        }
    }

    public func table() -> String {
        let rows = summaries().map {
            String(format: "%@ %3d/%-3d %5.0f%%  %6.2fs %6.2fs %6.2fs  %4d %4d", $0.kind.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0),
                   $0.passed, $0.runs, 100 * Double($0.passed) / Double($0.runs), $0.median, $0.p90, $0.max, $0.rawFallbacks, $0.errors)
        }
        let lm = rows.isEmpty ? nil : (["kind       pass        %   median    p90    max   raw  err"] + rows).joined(separator: "\n")
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
                let key = run.action + "\u{0}" + run.output
                if seen[key] == nil { order.append(key) }
                seen[key, default: (0, run)].0 += 1
            }
            for key in order {
                let (n, run) = seen[key]!
                lines.append("    \(n)× \(run.action): \"\(run.output)\"" + (run.vocabOffer.map { " offer \"\($0)\"" } ?? ""))
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
        return lines + compareSpeech(a, b)
    }
}
