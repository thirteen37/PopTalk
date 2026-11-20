import Foundation
import PoptalkCore
import PoptalkMLX
import PoptalkSpeech

// PoptalkDatagen: batch helpers for fine-tuning data (#21). JSONL in (stdin), JSONL out (stdout).
//   transcribe [--cache DIR]  {id, speak, voice?, rate?, context?} → {id, raw, boosted}
//       `say` → Parakeet TDT v2 → CTC boosting from the context's terms, as in the app; one model load.
//   render                    {id, kind, transcript, selection?, context?, vocabulary?, target?} → {id, messages}
//       The exact production chat (Prompts.dictation / Prompts.edit after Pipeline.stripHesitations; dictation
//       also after Pipeline.dictationPrepass). Dictation targets get Pipeline.spokenNumbers too, so they keep
//       the digits the model sees (#59).
//   teach --model ID          {id, messages} → {id, output}   (in-process MLX, greedy, like the app)
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
            Prompts.dictation(transcript: Pipeline.dictationPrepass(said), context: ctx, vocabulary: it.vocabulary ?? [])
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

default:
    fail("usage: PoptalkDatagen render|transcribe|teach [--model ID] [--cache DIR] < in.jsonl > out.jsonl")
}
