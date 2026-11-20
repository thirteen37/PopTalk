import Foundation
import MLX
import MLXNN
import Testing
import PoptalkCore
@testable import PoptalkMLX

/// E2B's weights where downloaded: the shared Hugging Face cache and PopTalk's text-only copy (#51).
private let cached: [URL] = {
    let fm = FileManager.default
    let snapshots = fm.homeDirectoryForCurrentUser
        .appendingPathComponent(".cache/huggingface/hub/models--mlx-community--gemma-4-e2b-it-4bit/snapshots")
    let full = (try? fm.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: nil)) ?? []
    let text = TextOnlyModel.directory(for: ModelSettings.e2b, appSupport: MLXProvider.appSupport)!
    return (full + [text]).map { $0.appendingPathComponent("model.safetensors") }.filter { fm.fileExists(atPath: $0.path) }
}()

@Test(.enabled(if: !cached.isEmpty, "E2B not downloaded"), arguments: cached)
func mappedPLEMatchesQuantizedEmbedding(url: URL) throws {
    // Lazy: reads only the header; just the three PLE tensors are materialized.
    let all = try loadArrays(url: url)
    let p = MappedPLE.path
    let original = QuantizedEmbedding(weight: all[p + ".weight"]!, scales: all[p + ".scales"]!,
                                      biases: all[p + ".biases"]!, groupSize: 64, bits: 4)
    let mapped = try #require(try MappedPLE(file: url, groupSize: 64, bits: 4))
    #expect(mapped.shape == (262_144, 35 * 256))
    let ids = MLXArray([0, 1, 2, 106, 1000, 50_000, 131_071, 200_000, 262_143] as [Int32]).reshaped(1, 9)
    let a = original(ids), b = mapped(ids)
    #expect(a.shape == [1, 9, 35 * 256])
    #expect(a.shape == b.shape)
    #expect(a.dtype == b.dtype)
    #expect(MLX.arrayEqual(a, b).item(Bool.self))
}

/// A prefill chunk, as `LLMModel.prepare` passes it: a lazy slice of the prompt, hundreds of ids with repeats.
@Test(.enabled(if: !cached.isEmpty, "E2B not downloaded"), arguments: cached)
func mappedPLEMatchesOnABatchedLazyChunk(url: URL) throws {
    let all = try loadArrays(url: url)
    let p = MappedPLE.path
    let original = QuantizedEmbedding(weight: all[p + ".weight"]!, scales: all[p + ".scales"]!,
                                      biases: all[p + ".biases"]!, groupSize: 64, bits: 4)
    let mapped = try #require(try MappedPLE(file: url, groupSize: 64, bits: 4))
    let prompt = MLXRandom.randInt(0 ..< 262_144, [1, 700], key: MLXRandom.key(62)).asType(.int32)
    let chunk = (prompt + 0)[0..., 100 ..< 612]  // unevaluated, like a chunk slice
    let a = original(chunk), b = mapped(chunk)
    #expect(b.shape == [1, 512, 35 * 256])
    #expect(MLX.arrayEqual(a, b).item(Bool.self))
}

// Non-Gemma bases (Qwen3, #68) have no PLE: install changes nothing.
@Test func mappedPLEIsANoOpWithoutPLE() throws {
    let model = Linear(4, 4)
    #expect(try MappedPLE.install(in: model, directory: FileManager.default.temporaryDirectory) == false)
}
