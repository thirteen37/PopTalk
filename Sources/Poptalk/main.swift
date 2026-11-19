import AppKit
import FluidAudio
import Foundation
import FoundationModels
import PoptalkCore

// Debug entry point: Poptalk --transcribe <file> [boost terms…]
let args = CommandLine.arguments
if args.count >= 3, args[1] == "--transcribe" {
    let samples = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: args[2]))
    let terms = args.dropFirst(3).map { VocabTerm(text: $0) }
    let t = try await Transcriber()
    let start = Date()
    let text = try await t.transcribe(samples, boost: terms)
    print(text)
    print(String(format: "total %.2fs, rescore %.3fs, %d terms",
                 Date().timeIntervalSince(start), await t.lastRescoreSeconds, terms.count))
    exit(0)
}

// Debug entry point: Poptalk --pipeline <transcript> [--selection <text>] [--context <screen text>]
if args.count >= 3, args[1] == "--pipeline" {
    func opt(_ name: String) -> String? { args.firstIndex(of: name).map { args[$0 + 1] } }
    Settings.register()
    let client = LLMClient(baseURL: Settings.baseURL)
    var complete: Pipeline.Complete = { try await client.complete(model: $0, messages: $1, json: $2, timeout: $3) }
    // -provider apple-pcc: Apple's larger Private Cloud Compute model (macOS 27+). Off-device.
    if UserDefaults.standard.string(forKey: "provider") == "apple-pcc", #available(macOS 27, *) {
        let pcc = PrivateCloudComputeLanguageModel()
        guard case .available = pcc.availability else { print("PCC unavailable: \(pcc.availability)"); exit(1) }
        complete = { _, messages, _, _ in
            let session = LanguageModelSession(model: pcc, instructions: messages.first { $0.role == "system" }?.content ?? "")
            do { return try await session.respond(to: messages.last!.content, options: GenerationOptions(temperature: 0)).content }
            catch { FileHandle.standardError.write(Data("PCC error: \(error)\n".utf8)); throw error }
        }
    }
    // -provider apple: Apple Intelligence on-device model (FoundationModels), for comparison.
    if UserDefaults.standard.string(forKey: "provider") == "apple", #available(macOS 26, *) {
        guard case .available = SystemLanguageModel.default.availability else {
            print("Apple Intelligence unavailable: \(SystemLanguageModel.default.availability)"); exit(1)
        }
        complete = { _, messages, _, _ in
            let session = LanguageModelSession(instructions: messages.first { $0.role == "system" }?.content ?? "")
            return try await session.respond(to: messages.last!.content, options: GenerationOptions(temperature: 0)).content
        }
    }
    let pipeline = Pipeline(
        complete: complete,
        vocabulary: VocabularyStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("poptalk-debug-vocab.json")),
        cleanupModel: Settings.cleanupModel, editModel: Settings.editModel)
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
