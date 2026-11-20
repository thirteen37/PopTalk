import AppKit
import FluidAudio
import Foundation
import PoptalkCore
import PoptalkMLX
import PoptalkSpeech

// Debug entry point: Poptalk --transcribe <file> [boost terms…]
let args = CommandLine.arguments
if args.count >= 3, args[1] == "--transcribe" {
    let samples = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: args[2]))
    // With the app's aliases (`boostTerms`), so this hears what the app does.
    let terms = Pipeline.boostTerms(saved: args.dropFirst(3).map { VocabTerm(text: $0) }, context: ScreenSnapshot(), fromScreen: false)
    let t = try await Transcriber()
    let start = Date()
    let text = try await t.transcribe(samples, boost: terms).text
    print(text)
    print(String(format: "total %.2fs, rescore %.3fs, %d terms",
                 Date().timeIntervalSince(start), await t.lastRescoreSeconds, terms.count))
    exit(0)
}

// Debug entry point: Poptalk --pipeline <transcript> [--selection <text>] [--context <screen text>]
if args.count >= 3, args[1] == "--pipeline" {
    func opt(_ name: String) -> String? { args.firstIndex(of: name).map { args[$0 + 1] } }
    Settings.register()
    // Uses the saved settings; override with -provider mlx (in-process; -mlxCleanupModel/-mlxEditModel are
    //   Hugging Face ids, local MLX directories, or LoRA adapter directories) | lmstudio (-lmstudioCleanupModel/-lmstudioEditModel) | apple.
    let sel = Settings.selection
    let provider = sel.provider
    let complete: Pipeline.Complete
    do {
        var meta: [String: String]
        (complete, meta) = provider == "mlx" ? try await MLXProvider.make(preload: sel.mlxModels)
            : try Providers.make(provider, baseURL: Settings.baseURL)
        if provider == "mlx" { print("loaded in \(meta["loadSeconds"]!)s, footprint \(meta["footprintMB"]!) MB") }
    }
    catch { print(error); exit(1) }
    let pipeline = Pipeline(
        complete: complete,
        vocabulary: VocabularyStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("poptalk-debug-vocab.json")),
        cleanupModel: sel.cleanupModel, editModel: sel.editModel)
    let ctx = opt("--context").map { ScreenSnapshot(text: $0) } ?? ScreenSnapshot()
    let start = Date()
    let r = await pipeline.run(Request(transcript: args[2], selection: opt("--selection"), context: ctx))
    print(r.outcome, r.vocabularyOffer.map { "offer: \($0)" } ?? "", String(format: "(%.2fs)", Date().timeIntervalSince(start)))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
