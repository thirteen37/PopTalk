import Foundation
import MLX
import MLXNN
import PoptalkCore

/// Gemma 4's per-layer embeddings (PLE, 1.26 GB at 4-bit in E2B) read from the safetensors file instead of
/// GPU memory (#52). Only the current tokens' rows are ever needed, so each call copies them (5,040 B per
/// token) out of a read-only mapping of the file and dequantizes them, the same math as `QuantizedEmbedding`.
/// Clean file-backed pages don't count toward the footprint, and the kernel drops them under pressure.
final class MappedPLE: Embedding {
    static let path = "language_model.model.embed_tokens_per_layer"

    /// On unless `POPTALK_PLE_MMAP=0` or the `mlxMappedPLE` default is false, for A/B runs.
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["POPTALK_PLE_MMAP"] != "0"
            && (UserDefaults.standard.object(forKey: "mlxMappedPLE") as? Bool ?? true)
    }

    private let file: Data
    private let w: Safetensors.Tensor, s: Safetensors.Tensor, b: Safetensors.Tensor
    private let groupSize: Int, bits: Int

    /// Maps PLE out of `url`; nil when the file doesn't hold it as affine-quantized weight/scales/biases.
    init?(file url: URL, groupSize: Int, bits: Int) throws {
        let h = try Safetensors.Header(contentsOf: url)
        guard let w = h.tensors[Self.path + ".weight"], let s = h.tensors[Self.path + ".scales"],
              let b = h.tensors[Self.path + ".biases"], w.dtype == "U32", w.shape.count == 2,
              s.shape == b.shape, s.shape.first == w.shape[0], Self.dtype(s.dtype) != nil, s.dtype == b.dtype
        else { return nil }
        self.file = try Data(contentsOf: url, options: .alwaysMapped)
        (self.w, self.s, self.b, self.groupSize, self.bits) = (w, s, b, groupSize, bits)
        // `weight` is unused; a scalar placeholder keeps the module tree well-formed.
        super.init(weight: MLXArray.zeros([1, 1], type: UInt32.self))
    }

    override var shape: (Int, Int) { (w.shape[0], w.shape[1] * 32 / bits) }

    override func callAsFunction(_ x: MLXArray) -> MLXArray {
        let ids = x.flattened().asArray(Int32.self)
        func rows(_ t: Safetensors.Tensor) -> MLXArray {
            var out = Data(capacity: ids.count * t.rowBytes)
            for id in ids { out.append(file[t.row(Int(id))]) }
            return MLXArray(out, [ids.count, t.shape[1]], dtype: Self.dtype(t.dtype)!)
        }
        return dequantized(rows(w), scales: rows(s), biases: rows(b), groupSize: groupSize, bits: bits)
            .reshaped(x.shape + [-1])
    }

    private static func dtype(_ s: String) -> DType? {
        ["U32": .uint32, "BF16": .bfloat16, "F16": .float16, "F32": .float32][s]
    }

    /// Swaps `model`'s quantized PLE for a `MappedPLE` over whichever safetensors file in `directory` holds
    /// it, then frees the GPU copy. Returns false (changing nothing) for models without a matching PLE.
    static func install(in model: Module, directory: URL) throws -> Bool {
        // The old module must be released before the cache is cleared, so its buffers go back to the OS.
        guard try swap(in: model, directory: directory) else { return false }
        Memory.clearCache()
        return true
    }

    private static func swap(in model: Module, directory: URL) throws -> Bool {
        guard let old = model.namedModules().first(where: { $0.0 == path })?.1 as? QuantizedEmbedding,
              old.mode == .affine, old.biases != nil else { return false }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "safetensors" }
        for url in files {
            guard let mapped = try MappedPLE(file: url, groupSize: old.groupSize, bits: old.bits),
                  mapped.w.shape == old.weight.shape, mapped.s.shape == old.scales.shape else { continue }
            model.update(modules: ModuleChildren.unflattened([(path, mapped)]))
            return true
        }
        return false
    }
}
