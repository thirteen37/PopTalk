import Foundation
import MLX
import MLXNN
import Testing
@testable import PoptalkMLX

/// E2B's weights in the shared Hugging Face cache, if downloaded.
private let cached: URL? = {
    let snapshots = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cache/huggingface/hub/models--mlx-community--gemma-4-e2b-it-4bit/snapshots")
    return (try? FileManager.default.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: nil))?
        .map { $0.appendingPathComponent("model.safetensors") }
        .first { FileManager.default.fileExists(atPath: $0.path) }
}()

@Test(.enabled(if: cached != nil, "E2B not in the Hugging Face cache"))
func mappedPLEMatchesQuantizedEmbedding() throws {
    let url = cached!
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
