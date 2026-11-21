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
//     [--oracle-terms]   (#75: recase on-screen mustContain terms in the transcript before the LLM; a ceiling)
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

let provider = opt("--provider") ?? "lmstudio"
let baseURL = URL(string: opt("--base-url") ?? "http://localhost:1234/v1")!
let cleanupModel = opt("--cleanup-model") ?? "google/gemma-4-e4b"
let editModel = opt("--edit-model") ?? cleanupModel
let runs = Int(opt("--runs") ?? "3") ?? 3
let appleVariant = opt("--apple-variant")
if provider == "apple", appleVariant == nil { fail("--provider apple needs --apple-variant core3|coreAdvanced3") }

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
let oracleTerms = args.contains("--oracle-terms")
if oracleTerms { meta["oracleTerms"] = "on" }
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

let pipeline = { Pipeline(complete: complete,
                          vocabulary: VocabularyStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("poptalk-bench-\(UUID()).json")),
                          cleanupModel: cleanupModel, editModel: editModel) }

// Warm up (model load, caches), then time a trivial request: a slow one means the server is busy,
// e.g. with orphaned generations from an earlier timed-out client (#4), and timings would be skewed.
_ = await pipeline().run(cases[0].request)
let probeStart = Date()
_ = try? await complete(cleanupModel, [ChatMessage(role: "user", content: "Reply with: ok")], false, 30)
let probe = Date().timeIntervalSince(probeStart)
// ponytail: a fixed 2 s threshold; LM Studio exposes no "busy" endpoint to ask directly.
if probe > 2 { print(String(format: "warning: idle probe took %.1fs; the server may be busy, timings will be noisy", probe)) }

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
        let start = Date()
        let r = await pipeline().run(request)
        var run = c.score(r, seconds: Date().timeIntervalSince(start))
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

let day = DateFormatter()
day.dateFormat = BenchReport.dateFormat
let date = day.string(from: Date())
if provider == "mlx" { meta.merge(["cleanupModel": cleanupModel, "editModel": editModel, "footprintMBAfterRun": "\(MLXProvider.footprintMB())"]) { $1 } }
let report = BenchReport(date: date, provider: meta, cases: results)
let details = report.failureDetails(cases)
print((details.isEmpty ? "\n" : "\n\(details)\n\n") + report.table())

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
