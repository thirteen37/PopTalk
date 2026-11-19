import Darwin
import Foundation
import PoptalkCore

// PoptalkBench: scores Pipeline (cleanup + edits) against bench/cases.jsonl, from the repo root.
//   swift run PoptalkBench [--provider lmstudio|apple|apple-pcc] [--apple-variant core3|coreAdvanced3]
//     [--base-url URL] [--cleanup-model ID] [--edit-model ID] [--runs 3] [--filter 'e-*'] [--cases FILE] [--out DIR]
//   swift run PoptalkBench --compare a.json b.json
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
do { (complete, meta) = try Providers.make(provider, baseURL: baseURL, appleVariant: appleVariant) } catch { fail(error) }
meta["provider"] = provider
meta["runs"] = "\(runs)"
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
        let start = Date()
        let r = await pipeline().run(c.request)
        caseRuns.append(c.score(r, seconds: Date().timeIntervalSince(start)))
    }
    print("\(caseRuns.allSatisfy(\.passed) ? "✓" : "✗") \(c.id)  \(caseRuns.filter(\.passed).count)/\(runs)")
    results.append(BenchCaseResult(id: c.id, kind: c.kind, runs: caseRuns))
}

let day = DateFormatter()
day.dateFormat = "yyyy-MM-dd-HHmm"
let date = day.string(from: Date())
let report = BenchReport(date: date, provider: meta, cases: results)
let details = report.failureDetails(cases)
print((details.isEmpty ? "\n" : "\n\(details)\n\n") + report.table())

let model = provider == "lmstudio" ? cleanupModel + (editModel == cleanupModel ? "" : "+" + editModel) : appleVariant ?? "default"
let dir = URL(fileURLWithPath: opt("--out") ?? "bench/results")
let file = dir.appendingPathComponent("\(date)-\(provider)-\(model.replacingOccurrences(of: "/", with: "_")).json")
do {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try enc.encode(report).write(to: file)
    print("\nwrote \(file.path)")
} catch { fail(error) }
