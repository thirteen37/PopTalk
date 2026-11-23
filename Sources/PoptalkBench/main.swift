import Darwin
import Foundation
import FluidAudio
import PoptalkCore
import PoptalkMLX
import PoptalkSpeech

// PoptalkBench: scores Pipeline (cleanup + edits) against bench/cases.jsonl, from the repo root.
//   swift run PoptalkBench [--provider lmstudio|apple|apple-pcc|mlx] [--apple-variant core3|coreAdvanced3]
//     [--base-url URL] [--cleanup-model ID] [--edit-model ID] [--runs 3] [--filter 'e-*'] [--cases FILE] [--out DIR]
//     [--speech-model v2|v3|ultra|bark3Clean|phonon2] [--boost on|off] [--cbw 0] [--min-similarity 0.7]
//     [--dictation-prompt-file F] [--edit-prompt-file F]   (#74: replace the system prompts for this run)
//     [--oracle-terms]   (#75: recase on-screen mustContain terms in the transcript before the LLM; a ceiling)
//     [--recase-terms on|off]   (#75: force the label-free screen-term recaser on or off; default: per model)
//     [--skip-gate on]   (#75: skip the cleanup LLM for clean, Parakeet-cased dictations; runs record skippedLLM)
//     [--hold]   (#43, audio cases: simulate holding the key with live cleanup; prints preview latency and reuse at release)
// --provider raw (#75): no LLM; dictation inserts the pre-passed transcript, scored without the raw-fallback failure.
// Cases with `speak` or `audio` (`--filter 's-*'`) run end to end: Parakeet → CTC boosting from the
// case's context → Pipeline. `speak` audio is cached in bench/audio-cache/.
//   swift run PoptalkBench --compare a.json b.json
Transcriber.quietLogs()
let args = CommandLine.arguments
func opt(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
func fail(_ msg: Any) -> Never { FileHandle.standardError.write(Data("\(msg)\n".utf8)); exit(1) }
func load(_ path: String) -> BenchReport {
    do { return try JSONDecoder().decode(BenchReport.self, from: Data(contentsOf: URL(fileURLWithPath: path))) } catch { fail("\(path): \(error)") }
}

if let i = args.firstIndex(of: "--compare") {
    guard i + 2 < args.count else { fail("usage: PoptalkBench --compare a.json b.json") }
    let (a, b) = (load(args[i + 1]), load(args[i + 2]))
    print("a: \(args[i + 1])\n\(a.table())\n\nb: \(args[i + 2])\n\(b.table())\n")
    let lines = BenchReport.compare(a, b)
    print(lines.isEmpty ? "no per-case changes" : lines.joined(separator: "\n"))
    exit(0)
}

// Warm-up probe (#33): prepares models as the app does, then times rounds 1–4 of ASR + rescore, a
// long-context dictation and an edit. Prefill/gen splits are in the timing log (see Transcriber/MLXProvider).
//   PoptalkBench --warmup-probe [--cleanup-model ID] [--edit-model ID]
if args.contains("--warmup-probe") {
    let cleanup = opt("--cleanup-model") ?? "mlx-community/gemma-4-e2b-it-4bit"
    let edit = opt("--edit-model") ?? "mlx-community/gemma-4-e4b-it-4bit"
    func elapsed(_ start: Date) -> String { String(format: "%.2fs", Date().timeIntervalSince(start)) }
    do {
        let all = try BenchCase.load(jsonl: String(contentsOfFile: "bench/cases.jsonl", encoding: .utf8))
        func find(_ id: String) -> BenchCase { all.first { $0.id == id }! }
        // --dictation a,b,…: cycled per round, to see whether each new prompt length is cold.
        let ds = (opt("--dictation") ?? "d-long-name-before-cursor").split(separator: ",").map { find(String($0)) }
        let (e, s) = (find("e-long-correct-far-name"), find("s-priya-q3"))
        let audio = try Speech.synthesize(s.speak!, voice: s.voice, rate: s.rate, cache: URL(fileURLWithPath: "bench/audio-cache"))
        var t = Date()
        // --idle N: wait N s after preparing, like a user would.
        for id in Set([cleanup, edit]) { try await MLXProvider.prepare(id) { _ in } }
        print("prepare models \(elapsed(t))")
        t = Date()
        let transcriber = try await Transcriber()
        print("transcriber init \(elapsed(t))")
        let complete = try await MLXProvider.make(preload: []).0
        let pipeline = Pipeline(complete: complete,
                                vocabulary: VocabularyStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("poptalk-probe-\(UUID()).json")),
                                cleanupModel: cleanup, editModel: edit)
        let boost = Pipeline.boostTerms(saved: [], context: s.request.context)
        if let idle = opt("--idle").flatMap(Double.init) { try await Task.sleep(for: .seconds(idle)) }
        for round in 1...max(4, 2 * ds.count) {
            let h = try await transcriber.transcribeDetailed(audio, boost: boost)
            t = Date()
            let dr = await pipeline.run(ds[(round - 1) % ds.count].request)
            let ds = elapsed(t)
            t = Date()
            let er = await pipeline.run(e.request)
            print(String(format: "round %d: asr %.2fs rescore(%d terms) %.2fs | dictation %@ %@ | edit %@ %@", round, h.asrSeconds, boost.count,
                         h.rescoreSeconds, ds, "\(dr.outcome)".contains("raw") ? "RAW" : "ok", elapsed(t), "\(er.outcome)".hasPrefix("error") ? "ERR" : "ok"))
        }
    } catch { fail(error) }
    exit(0)
}

// History replay: runs dictation requests through Pipeline with an MLX cleanup model, as the app would.
//   PoptalkBench --replay in.jsonl out.jsonl --cleanup-model ID
// in: {id, transcript, app, window, ax, ocr, vocabulary: [String]} per line; out: {id, label, output, reply?, user?, seconds}.
// Prints counts only: the inputs and outputs are history content and stay in the files.
if let i = args.firstIndex(of: "--replay") {
    struct In: Decodable { var id, transcript, app, window, ax, ocr: String; var vocabulary: [String] }
    struct Out: Encodable { var id, label, output: String; var reply, user: String?; var seconds: Double }
    guard i + 2 < args.count, let model = opt("--cleanup-model") else { fail("usage: PoptalkBench --replay in.jsonl out.jsonl --cleanup-model ID") }
    do {
        let lines = try String(contentsOfFile: args[i + 1], encoding: .utf8).split(separator: "\n")
        let complete = try await MLXProvider.make(preload: [model]).0
        for w in Prompts.warmup { _ = try? await complete(model, w, false, 60) }
        FileManager.default.createFile(atPath: args[i + 2], contents: nil, attributes: [.posixPermissions: 0o600])
        let out = try FileHandle(forWritingTo: URL(fileURLWithPath: args[i + 2]))
        let start = Date(), saved = VocabularyStore()
        for (n, line) in lines.enumerated() {
            let r = try JSONDecoder().decode(In.self, from: Data(line.utf8))
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("poptalk-replay-\(UUID())")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let store = VocabularyStore(url: dir.appendingPathComponent("v.json"))
            // The prompt lists term texts only; aliases come from today's saved vocabulary.
            for t in r.vocabulary { try store.add(saved.terms.first { $0.text == t } ?? VocabTerm(text: t)) }
            let calls = ModelCallRecorder()
            let p = Pipeline(complete: calls.wrap(complete), vocabulary: store, cleanupModel: model, editModel: model)
            let t = Date()
            let res = await p.run(Request(transcript: r.transcript, selection: nil,
                                          context: ScreenSnapshot(appName: r.app, windowTitle: r.window, text: r.ax, ocrText: r.ocr)))
            try? FileManager.default.removeItem(at: dir)
            let (label, output): (String, String) = switch res.outcome {
            case let .insert(s, l): (l, s)
            case .nothing: ("Nothing", "")
            default: ("other", "")
            }
            let o = Out(id: r.id, label: label, output: output, reply: calls.call?.reply,
                        user: calls.call?.messages.last?.content, seconds: Date().timeIntervalSince(t))
            try out.write(contentsOf: JSONEncoder().encode(o) + Data([0x0A]))
            if (n + 1) % 25 == 0 { print("\(n + 1)/\(lines.count) \(Int(Date().timeIntervalSince(start)))s footprint \(MLXProvider.footprintMB()) MB") }
        }
        try out.close()
        print(String(format: "done %d in %.0fs; footprint %d MB", lines.count, Date().timeIntervalSince(start), MLXProvider.footprintMB()))
    } catch { fail(error) }
    exit(0)
}

let provider = opt("--provider") ?? "lmstudio"
let baseURL = URL(string: opt("--base-url") ?? "http://localhost:1234/v1")!
let cleanupModel = opt("--cleanup-model") ?? "google/gemma-4-e4b"
let editModel = opt("--edit-model") ?? cleanupModel
let runs = Int(opt("--runs") ?? "3") ?? 3
let appleVariant = opt("--apple-variant")
if provider == "apple", appleVariant == nil { fail("--provider apple needs --apple-variant core3|coreAdvanced3") }
// Candidate system prompts (#74, GEPA): replace the dictation / edit system prompt, E4B's own included, for this run.
var promptFiles: [String: String] = [:]
for (flag, key) in [("--dictation-prompt-file", "dictationPrompt"), ("--edit-prompt-file", "editPrompt")] {
    guard let path = opt(flag) else { continue }
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fail("\(flag): can't read \(path)") }
    if key == "dictationPrompt" { Prompts.dictationSystem = text; Prompts.e4bDictationSystem = text }
    else { Prompts.editSystem = text; Prompts.e4bEditSystem = text }
    promptFiles[key] = path
}

let cases: [BenchCase]
do {
    cases = try BenchCase.load(jsonl: String(contentsOfFile: opt("--cases") ?? "bench/cases.jsonl", encoding: .utf8))
        .filter { c in opt("--filter").map { fnmatch($0, c.id, 0) == 0 } ?? true }
} catch { fail(error) }
guard !cases.isEmpty else { fail("no cases match") }

var meta: [String: String]
let complete: Pipeline.Complete
do {
    // mlx: cleanup/edit models are Hugging Face ids or local MLX directories, loaded in-process.
    (complete, meta) = provider == "raw" ? ({ _, _, _, _ in throw LLMError(description: "raw: no LLM") }, [:])
        : provider == "mlx" ? try await MLXProvider.make(preload: [cleanupModel, editModel])
        : try Providers.make(provider, baseURL: baseURL, appleVariant: appleVariant)
} catch { fail(error) }
meta["provider"] = provider
meta["runs"] = "\(runs)"
meta.merge(promptFiles) { $1 }
let oracleTerms = args.contains("--oracle-terms")
if oracleTerms { meta["oracleTerms"] = "on" }
if let v = opt("--recase-terms") { Pipeline.recaseOverride = v != "off" }
meta["recaseTerms"] = Pipeline.recaseOverride ?? Pipeline.recasesTerms(cleanupModel) ? "on" : "off"
let skipGate = opt("--skip-gate") == "on"
var features = DictationFeatures()
features.skipGate = skipGate
if skipGate { meta["skipGate"] = "on" }
meta["macOS"] = ProcessInfo.processInfo.operatingSystemVersionString
var size = 0
sysctlbyname("hw.model", nil, &size, nil, 0)
var hw = [UInt8](repeating: 0, count: size)
sysctlbyname("hw.model", &hw, &size, nil, 0)
meta["hwModel"] = String(decoding: hw.prefix { $0 != 0 }, as: UTF8.self)
if provider == "lmstudio" {
    meta["cleanupModel"] = cleanupModel
    meta["editModel"] = editModel
    // LM Studio's native REST API reports the quantization of the loaded model.
    let info = baseURL.deletingLastPathComponent().appendingPathComponent("api/v0/models/\(cleanupModel)")
    if let (data, _) = try? await URLSession.shared.data(from: info),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        meta["quantization"] = json["quantization"] as? String
    }
}

let audioCases = cases.filter(\.hasAudio)
let boostOn = (opt("--boost") ?? "on") != "off"
let cbw = Float(opt("--cbw") ?? "0") ?? 0
let minSimilarity = Float(opt("--min-similarity") ?? "0.7") ?? 0.7
var transcriber: Transcriber?
var samples: [String: [Float]] = [:]
if !audioCases.isEmpty {
    let speechModel = opt("--speech-model") ?? ModelSettings.defaults["speechModel"]!
    guard let version = Transcriber.version(speechModel) else {
        fail("--speech-model must be one of " + ModelSettings.speechModels.map(\.id).joined(separator: "|"))
    }
    meta["speechModel"] = speechModel
    meta["boost"] = boostOn ? "on" : "off"
    meta["cbw"] = "\(cbw)"
    meta["minSimilarity"] = "\(minSimilarity)"
    do {
        let cache = URL(fileURLWithPath: "bench/audio-cache")
        for c in audioCases {
            samples[c.id] = try c.audio.map { try Speech.load(URL(fileURLWithPath: $0)) }
                ?? Speech.synthesize(c.speak!, voice: c.voice, rate: c.rate, cache: cache)
        }
        transcriber = try await Transcriber(version: version)
        // Warm up: the first pass compiles and loads the CoreML models.
        _ = try await transcriber!.transcribeDetailed(samples[audioCases[0].id]!, boost: [VocabTerm(text: "Poptalk")])
    } catch { fail(error) }
}

let pipeline = { (calls: ModelCallRecorder?) in
    Pipeline(complete: calls?.wrap(complete) ?? complete,
             vocabulary: VocabularyStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("poptalk-bench-\(UUID()).json")),
             cleanupModel: cleanupModel, editModel: editModel, features: features)
}

// Warm up (model load, caches), then time a trivial request: a slow one means the server is busy,
// e.g. with orphaned generations from an earlier timed-out client (#4), and timings would be skewed.
_ = await pipeline(nil).run(cases[0].request)
let probeStart = Date()
_ = try? await complete(cleanupModel, [ChatMessage(role: "user", content: "Reply with: ok")], false, 30)
let probe = Date().timeIntervalSince(probeStart)
// ponytail: a fixed 2 s threshold; LM Studio exposes no "busy" endpoint to ask directly.
if probe > 2 { print(String(format: "warning: idle probe took %.1fs; the server may be busy, timings will be noisy", probe)) }

let hold = args.contains("--hold")
/// --hold: speculative runs per dictation, preview seconds (tick → cleaned result), and per release whether the
/// last speculative result was reused, the pipeline seconds that saves, and whether it equals the fresh result.
var holdStats = (runs: [Int](), preview: [Double](), release: [(hit: Bool, seconds: Double, same: Bool?)]())
var results: [BenchCaseResult] = []
for c in cases {
    var caseRuns: [BenchRun] = []
    for _ in 0..<runs {
        var request = c.request
        var heard: Transcription?
        var boost: [VocabTerm] = []
        if let transcriber, let audio = samples[c.id] {
            boost = boostOn ? Pipeline.boostTerms(saved: [], context: request.context) : []
            do { heard = try await transcriber.transcribeDetailed(audio, boost: boost, cbw: cbw, minSimilarity: minSimilarity) }
            catch { fail("\(c.id): \(error)") }
            request = Request(transcript: heard!.text, selection: request.selection, context: request.context)
        }
        if oracleTerms, c.kind == .dictation { request.transcript = c.oracleRecase(request.transcript) }
        // --hold (#43): first the hold, as the app runs it: growing prefixes at 500 ms ticks, then 0.6 s of
        // silence before release; a speculative run at each pause. Release (`request`) hears the audio plus the silence.
        var held: (request: Request, result: PipelineResult)?
        if hold, let transcriber, let audio = samples[c.id] {
            let full = audio + [Float](repeating: 0, count: 9_600)
            var previous: String?
            for end in stride(from: 8_000, through: full.count, by: 8_000) {
                let prefix = Array(full[..<end])
                guard AudioGate.hasSpeech(prefix) else { continue }
                let tick = Date()
                guard let text = try? await transcriber.transcribeDetailed(prefix, boost: boost).text else { continue }
                defer { previous = text }
                guard LivePreview.shouldRun(text, lastRun: held?.request.transcript, previous: previous,
                                            paused: LivePreview.paused(prefix), edit: request.selection != nil) else { continue }
                var p = pipeline(nil)
                p.remembers = false
                let spec = Request(transcript: text, selection: request.selection, context: request.context)
                held = (spec, await LivePreview.$speculative.withValue(true) { await p.run(spec) })
                holdStats.preview.append(Date().timeIntervalSince(tick))
            }
            holdStats.runs.append(holdStats.preview.count - holdStats.runs.reduce(0, +))
            do { heard = try await transcriber.transcribeDetailed(full, boost: boost, cbw: cbw, minSimilarity: minSimilarity) }
            catch { fail("\(c.id): \(error)") }
            request.transcript = heard!.text
        }
        let start = Date()
        let calls = ModelCallRecorder()
        let r = await pipeline(calls).run(request)
        if hold, samples[c.id] != nil {
            let reused = held.flatMap { LivePreview.sameInput($0.request, request) ? LivePreview.reusable($0.result) : nil }
            holdStats.release.append((reused != nil, Date().timeIntervalSince(start), reused.map { $0 == r }))
        }
        var run = c.score(r, seconds: Date().timeIntervalSince(start))
        // A dictation reply the code changed or rejected (restoreMarks, fidelity guards), to see why.
        if c.kind == .dictation, let reply = calls.call?.reply?.trimmingCharacters(in: .whitespacesAndNewlines), reply != run.output {
            run.modelReply = reply
        }
        if provider == "raw" { run.failures.removeAll { $0 == "raw fallback" } }
        if let heard {
            run.speech = SpeechRun(reference: c.transcript, terms: c.mustContain, raw: heard.raw, boosted: heard.text, final: run.output,
                                   boostTerms: boost.count, asrSeconds: heard.asrSeconds, rescoreSeconds: heard.rescoreSeconds)
        }
        caseRuns.append(run)
    }
    print("\(caseRuns.allSatisfy(\.passed) ? "✓" : "✗") \(c.id)  \(caseRuns.filter(\.passed).count)/\(runs)"
        + (caseRuns[0].speech.map { "  heard \"\($0.raw)\"" + ($0.boosted == $0.raw ? "" : " → boosted \"\($0.boosted)\"") } ?? ""))
    results.append(BenchCaseResult(id: c.id, kind: c.kind, runs: caseRuns))
}

if hold, !holdStats.release.isEmpty {
    func median(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.sorted()[xs.count / 2] }
    let hits = holdStats.release.filter(\.hit)
    print(String(format: "\nhold: %.1f speculative runs per dictation; preview median %.2fs, max %.2fs; reuse %d/%d; "
                 + "release pipeline median %.2fs (saved on a hit); reused = fresh result %d/%d",
                 Double(holdStats.runs.reduce(0, +)) / Double(holdStats.runs.count), median(holdStats.preview),
                 holdStats.preview.max() ?? 0, hits.count, holdStats.release.count, median(holdStats.release.map(\.seconds)),
                 hits.filter { $0.same == true }.count, hits.count))
}

let day = DateFormatter()
day.dateFormat = BenchReport.dateFormat
let date = day.string(from: Date())
if provider == "mlx" { meta.merge(["cleanupModel": cleanupModel, "editModel": editModel, "footprintMBAfterRun": "\(MLXProvider.footprintMB())"]) { $1 } }
let report = BenchReport(date: date, provider: meta, cases: results)
let details = report.failureDetails(cases)
print((details.isEmpty ? "\n" : "\n\(details)\n\n") + report.table())
if skipGate {
    let skipped = results.filter { $0.runs.contains { $0.skippedLLM == true } }
    print("\nskip gate: \(skipped.count)/\(results.filter { $0.kind == .dictation }.count) dictation cases skipped the LLM: "
        + skipped.map { "\($0.id)\($0.runs.allSatisfy(\.passed) ? "" : " ✗")" }.joined(separator: ", "))
}

let model = (provider == "lmstudio" || provider == "mlx" ? cleanupModel + (editModel == cleanupModel ? "" : "+" + editModel) : appleVariant ?? "default") + (audioCases.isEmpty ? "" : "-audio")
let dir = URL(fileURLWithPath: opt("--out") ?? "bench/results")
let file = dir.appendingPathComponent(BenchReport.fileName(date: date, provider: provider, model: model, filter: opt("--filter")))
do {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try enc.encode(report).write(to: file)
    print("\nwrote \(file.path)")
} catch { fail(error) }
