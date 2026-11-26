import Foundation
import PoptalkCore
import PoptalkMLX
import PoptalkSpeech

// PoptalkDatagen: batch helpers for fine-tuning data (#21). JSONL in (stdin), JSONL out (stdout).
//   transcribe [--cache DIR]  {id, speak, voice?, rate?, context?} → {id, raw, boosted}
//       `say` → Parakeet TDT v2 → CTC boosting from the context's terms, as in the app; one model load.
//   render                    {id, kind, transcript, selection?, context?, vocabulary?, target?} → {id, messages}
//       The exact production chat (Prompts.dictation / Prompts.edit after Pipeline.stripHesitations; dictation
//       also after Pipeline.dictationPrepass, through Pipeline.dictationMessages: short ones get no screen text, #124).
//       Dictation targets get Pipeline.spokenNumbers too, so they keep the digits the model sees (#59).
//   teach --model ID          {id, messages} → {id, output}   (in-process MLX, greedy, like the app)
//   pipeline --model ID       {id, transcript, selection?, context?, vocabulary?} → {id, label, output, reply?, rejectedBy?}
//       The app's Pipeline end to end with the model's own prompts (E4B: its dictation prompt, D, and edit prompt) and
//       guards; `rejectedBy` names the guard that made a dictation reply a raw fallback (E2B v6 teacher, #103).
// `context` is {appName?, windowTitle?, text?, cursorOffset?, ocrText?}, mirroring ScreenSnapshot.
Transcriber.quietLogs()
let args = CommandLine.arguments
func opt(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
func fail(_ msg: Any) -> Never { FileHandle.standardError.write(Data("\(msg)\n".utf8)); exit(1) }

struct Context: Codable {
    var appName: String?, windowTitle: String?, text: String?, cursorOffset: Int?, ocrText: String?
    var snapshot: ScreenSnapshot {
        ScreenSnapshot(appName: appName ?? "", windowTitle: windowTitle ?? "", text: text ?? "", cursorOffset: cursorOffset, ocrText: ocrText ?? "")
    }
}

struct Item: Codable {
    var id: String
    var kind: String?
    var transcript: String?
    var selection: String?
    var context: Context?
    var vocabulary: [VocabTerm]?
    var target: String?
    var speak: String?
    var voice: String?
    var rate: Int?
    var messages: [ChatMessage]?
}

let enc = JSONEncoder()
enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
func emit(_ obj: some Encodable) {
    guard let d = try? enc.encode(obj) else { fail("encode failed") }
    FileHandle.standardOutput.write(d + Data("\n".utf8))
}

var items: [Item] = []
while let line = readLine(strippingNewline: true) {
    guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
    do { items.append(try JSONDecoder().decode(Item.self, from: Data(line.utf8))) } catch { fail("line \(items.count + 1): \(error)") }
}

switch args.dropFirst().first {
case "render":
    struct Out: Encodable { var id: String; var messages: [ChatMessage] }
    for it in items {
        let ctx = it.context?.snapshot ?? ScreenSnapshot()
        let said = Pipeline.stripHesitations(it.transcript ?? "")
        let isEdit = !(it.selection ?? "").isEmpty
        var m = if isEdit {
            Prompts.edit(instruction: said, selection: it.selection!, context: ctx, vocabulary: it.vocabulary ?? [])
        } else {
            Pipeline.dictationMessages(model: ModelSettings.e2b, transcript: Pipeline.dictationPrepass(said), context: ctx,
                                       vocabulary: it.vocabulary ?? [])
        }
        if let t = it.target { m.append(ChatMessage(role: "assistant", content: isEdit ? t : Pipeline.spokenNumbers(t))) }
        emit(Out(id: it.id, messages: m))
    }

case "transcribe":
    struct Out: Encodable { var id: String; var raw: String; var boosted: String }
    let cache = URL(fileURLWithPath: opt("--cache") ?? "training/out/audio-cache")
    do {
        let t = try await Transcriber(version: .v2)
        for (i, it) in items.enumerated() {
            guard let speak = it.speak else { fail("\(it.id): no speak") }
            let audio: [Float]
            do { audio = try Speech.synthesize(speak, voice: it.voice, rate: it.rate, cache: cache) } catch {
                FileHandle.standardError.write(Data("skip \(it.id): \(error)\n".utf8)); continue
            }
            let boost = Pipeline.boostTerms(saved: it.vocabulary ?? [], context: it.context?.snapshot ?? ScreenSnapshot())
            let r = try await t.transcribeDetailed(audio, boost: boost)
            emit(Out(id: it.id, raw: r.raw, boosted: r.text))
            if i % 100 == 0 { FileHandle.standardError.write(Data("\(i)/\(items.count)\n".utf8)) }
        }
    } catch { fail(error) }

case "teach":
    struct Out: Encodable { var id: String; var output: String }
    guard let model = opt("--model") else { fail("teach needs --model") }
    do {
        let (complete, _) = try await MLXProvider.make(preload: [model])
        for it in items {
            emit(Out(id: it.id, output: (try? await complete(model, it.messages ?? [], true, 60)) ?? ""))
        }
    } catch { fail(error) }

case "pipeline":
    struct Out: Encodable { var id, label, output: String; var reply, rejectedBy: String? }
    guard let model = opt("--model") else { fail("pipeline needs --model") }
    do {
        let complete = try await MLXProvider.make(preload: [model]).0
        for w in Prompts.warmup { _ = try? await complete(model, w, false, 60) }
        for (i, it) in items.enumerated() {
            // A fresh vocabulary per item: the item's terms only, and an edit's "remember" can't leak into the next.
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("poptalk-datagen-\(UUID())")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let store = VocabularyStore(url: dir.appendingPathComponent("v.json"))
            for t in it.vocabulary ?? [] { try store.add(t) }
            let calls = ModelCallRecorder()
            // Generous deadlines: a teacher is judged on its reply, not on the app's latency budget.
            let p = Pipeline(complete: calls.wrap(complete), vocabulary: store, cleanupModel: model, editModel: model,
                             cleanupTimeout: 30, editTimeout: 60)
            let res = await p.run(Request(transcript: it.transcript ?? "", selection: it.selection, context: it.context?.snapshot ?? ScreenSnapshot()))
            try? FileManager.default.removeItem(at: dir)
            let (label, output): (String, String) = switch res.outcome {
            case let .insert(s, l): (l, s)
            case let .replaceSelection(s, l): (l, s)
            case let .insertBefore(s): ("insertBefore", s)
            case let .insertAfter(s): ("insertAfter", s)
            case .nothing: ("Nothing", "")
            case let .error(m): ("error", m)
            }
            emit(Out(id: it.id, label: label, output: output, reply: calls.call?.reply, rejectedBy: res.rejectedBy))
            if i % 100 == 0 { FileHandle.standardError.write(Data("\(i)/\(items.count)\n".utf8)) }
        }
    } catch { fail(error) }

default:
    fail("usage: PoptalkDatagen render|transcribe|teach|pipeline [--model ID] [--cache DIR] < in.jsonl > out.jsonl")
}
