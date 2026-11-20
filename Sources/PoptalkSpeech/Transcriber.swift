import CryptoKit
import FluidAudio
import Foundation
import os
import PoptalkCore

/// One recognition pass: the unboosted TDT text, the boosted text, and how long each stage took.
public struct Transcription: Sendable {
    public var raw: String
    public var text: String
    public var asrSeconds: Double
    public var rescoreSeconds: Double
}

/// Parakeet TDT speech recognition with per-request CTC vocabulary boosting.
public actor Transcriber {
    private let asr: AsrManager
    private let ctcModels: CtcModels
    public private(set) var lastRescoreSeconds: Double = 0

    /// - Parameter version: Parakeet TDT `v2` (English, the app's default) or `v3` (multilingual).
    public init(version: AsrModelVersion = .v2) async throws {
        Self.quietLogs()
        let models = try await AsrModels.downloadAndLoad(version: version)
        asr = AsrManager()
        try await asr.loadModels(models)
        ctcModels = try await CtcModels.downloadAndLoad(variant: .ctc110m)
    }

    /// Drops FluidAudio's debug and info logs, which include transcripts (the rescorer's
    /// "Final: …" and each replacement), from stderr and the unified log. Warnings and errors stay.
    public static func quietLogs() {
        AppLogger.minimumLevel = .warning
    }

    /// - Parameter samples: 16 kHz mono Float32.
    public func transcribe(_ samples: [Float], boost: [VocabTerm]) async throws -> Transcription {
        let t = try await transcribeDetailed(samples, boost: boost)
        // Timing only (no text).
        Logger(subsystem: "io.lyx.poptalk", category: "timing").info(
            "asr \(Double(samples.count) / 16_000, format: .fixed(precision: 1))s audio: \(t.asrSeconds, format: .fixed(precision: 2))s, rescore \(boost.count) terms \(t.rescoreSeconds, format: .fixed(precision: 2))s")
        return t
    }

    /// Conservative default thresholds: FluidAudio's docs show these avoid replacing correctly heard words.
    public func transcribeDetailed(_ samples: [Float], boost: [VocabTerm],
                                   cbw: Float = 0, minSimilarity: Float = 0.7) async throws -> Transcription {
        let asrStart = Date()
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        let result = try await asr.transcribe(samples, decoderState: &state)
        let asrSeconds = Date().timeIntervalSince(asrStart)
        guard !boost.isEmpty else { return Transcription(raw: result.text, text: result.text, asrSeconds: asrSeconds, rescoreSeconds: 0) }

        let start = Date()
        let vocab = CustomVocabularyContext(terms: boost.map {
            CustomVocabularyTerm(text: $0.text, weight: $0.weight, aliases: $0.aliases.isEmpty ? nil : $0.aliases)
        })
        let session = try await VocabularyBoostingSession(
            vocabulary: vocab, ctcModels: ctcModels,
            thresholds: .init(cbw: cbw, minSimilarity: minSimilarity))
        let output = await session.rescore(
            text: result.text, tokenTimings: result.tokenTimings ?? [], audioSamples: samples)
        lastRescoreSeconds = Date().timeIntervalSince(start)
        return Transcription(raw: result.text, text: Pipeline.splitFused(output?.text ?? result.text, terms: boost), asrSeconds: asrSeconds, rescoreSeconds: lastRescoreSeconds)
    }
}

struct SayError: Error, CustomStringConvertible { var description: String }

/// Text-to-speech test audio via `say`, for benchmarks and training data (#21).
public enum Speech {
    /// Synthesizes `text` into `cache` (once per text, voice and rate) and returns 16 kHz mono samples.
    public static func synthesize(_ text: String, voice: String? = nil, rate: Int? = nil, cache: URL) throws -> [Float] {
        let key = SHA256.hash(data: Data([text, voice ?? "", rate.map(String.init) ?? ""].joined(separator: "\u{0}").utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
        let file = cache.appendingPathComponent("\(key).aiff")
        if !FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            let say = Process()
            say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = (voice.map { ["-v", $0] } ?? []) + (rate.map { ["-r", "\($0)"] } ?? []) + ["-o", file.path, "--", text]
            try say.run()
            say.waitUntilExit()
            guard say.terminationStatus == 0 else {
                try? FileManager.default.removeItem(at: file)
                throw SayError(description: "say failed (\(say.terminationStatus)) for voice \(voice ?? "default")")
            }
        }
        return try load(file)
    }

    /// Any audio file AVFoundation reads, as 16 kHz mono samples.
    public static func load(_ url: URL) throws -> [Float] { try AudioConverter().resampleAudioFile(url) }
}
