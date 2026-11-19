import FluidAudio
import Foundation
import PoptalkCore

/// Parakeet TDT v2 speech recognition with per-request CTC vocabulary boosting.
actor Transcriber {
    private let asr: AsrManager
    private let ctcModels: CtcModels
    private(set) var lastRescoreSeconds: Double = 0

    init() async throws {
        let models = try await AsrModels.downloadAndLoad(version: .v2)
        asr = AsrManager()
        try await asr.loadModels(models)
        ctcModels = try await CtcModels.downloadAndLoad(variant: .ctc110m)
    }

    /// - Parameter samples: 16 kHz mono Float32.
    func transcribe(_ samples: [Float], boost: [VocabTerm]) async throws -> String {
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        let result = try await asr.transcribe(samples, decoderState: &state)
        guard !boost.isEmpty else { return result.text }

        let start = Date()
        defer { lastRescoreSeconds = Date().timeIntervalSince(start) }
        let vocab = CustomVocabularyContext(terms: boost.map {
            CustomVocabularyTerm(text: $0.text, weight: $0.weight, aliases: $0.aliases.isEmpty ? nil : $0.aliases)
        })
        // Conservative thresholds: FluidAudio's docs show these avoid replacing correctly heard words.
        let session = try await VocabularyBoostingSession(
            vocabulary: vocab, ctcModels: ctcModels,
            thresholds: .init(cbw: 0, minSimilarity: 0.7))
        let output = await session.rescore(
            text: result.text, tokenTimings: result.tokenTimings ?? [], audioSamples: samples)
        return output?.text ?? result.text
    }
}
