import AppKit
import FluidAudio
import Foundation
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

let app = NSApplication.shared
let delegate = await AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
