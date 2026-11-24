import Foundation
import MLX
import MLXNN
import PoptalkCore

/// Gemma 4's per-layer embeddings (PLE, 1.59 GB at 4-bit in E4B) read from the safetensors file instead of
/// GPU memory (#52). Only the current tokens' rows are ever needed. The three PLE tensors are wrapped, without
/// a copy, over private mappings of the file; each call gathers its rows on MLX's CPU stream and dequantizes
/// them on the GPU: the same ops on the same bytes as `QuantizedEmbedding`, so the output is bit-identical.
/// Clean file-backed pages don't count toward the footprint, and the kernel drops them under pressure.
///
/// The gather is a graph op, so the token ids never come back to the host (#62): the GPU waits on the CPU
/// stream through an event, and the next step's graph is built while the current one runs, as with PLE on
/// the GPU. Reading the ids on the host (the first version) cost a sync per decode step and prefill chunk.
/// The tables must stay off the GPU: a GPU gather over the same mappings was as fast, but Metal wired all
/// 1.26 GB while they were bound (system wired memory rose; `phys_footprint` didn't show it).
// ponytail: MLX's residency sets would wire these buffers as well if a wired limit were set (Poptalk passes
// no `WiredMemoryTicket`); if one is ever added, check `vm_stat` wired memory.
final class MappedPLE: Embedding {
    static let path = "language_model.model.embed_tokens_per_layer"

    /// On unless `POPTALK_PLE_MMAP=0` or the `mlxMappedPLE` default is false, for A/B runs.
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["POPTALK_PLE_MMAP"] != "0"
            && (UserDefaults.standard.object(forKey: "mlxMappedPLE") as? Bool ?? true)
    }

    private let w: MLXArray, s: MLXArray, b: MLXArray
    private let groupSize: Int, bits: Int

    /// Maps PLE out of `url`; nil when the file doesn't hold it as affine-quantized weight/scales/biases.
    init?(file url: URL, groupSize: Int, bits: Int) throws {
        let h = try Safetensors.Header(contentsOf: url)
        guard let w = h.tensors[Self.path + ".weight"], let s = h.tensors[Self.path + ".scales"],
              let b = h.tensors[Self.path + ".biases"], w.dtype == "U32", w.shape.count == 2,
              s.shape == b.shape, s.shape.first == w.shape[0], Self.dtype(s.dtype) != nil, s.dtype == b.dtype
        else { return nil }
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw CocoaError(.fileReadUnknown, userInfo: [NSURLErrorKey: url]) }
        defer { close(fd) }
        (self.w, self.s, self.b) = (try Self.map(w, fd, url), try Self.map(s, fd, url), try Self.map(b, fd, url))
        (self.groupSize, self.bits) = (groupSize, bits)
        // `weight` is unused; a scalar placeholder keeps the module tree well-formed.
        super.init(weight: MLXArray.zeros([1, 1], type: UInt32.self))
    }

    /// `t` over its own page-aligned private mapping (Metal only wraps page-aligned memory), never written.
    /// Every op on it runs on the CPU stream, so the GPU never binds it.
    private static func map(_ t: Safetensors.Tensor, _ fd: Int32, _ url: URL) throws -> MLXArray {
        let page = Int(getpagesize())
        let start = t.range.lowerBound / page * page
        let length = (t.range.upperBound - start + page - 1) / page * page
        guard let p = mmap(nil, length, PROT_READ | PROT_WRITE, MAP_PRIVATE, fd, off_t(start)), p != MAP_FAILED
        else { throw CocoaError(.fileReadUnknown, userInfo: [NSURLErrorKey: url]) }
        let raw = MLXArray(rawPointer: p, [length], dtype: .uint8) { munmap(p, length) }
        let skip = t.range.lowerBound - start
        let a = raw[skip ..< skip + t.range.count, stream: .cpu].view(dtype: dtype(t.dtype)!, stream: .cpu)
            .reshaped(t.shape, stream: .cpu)
        eval(a)
        return a
    }

    override var shape: (Int, Int) { (w.dim(0), w.dim(1) * 32 / bits) }

    override func callAsFunction(_ x: MLXArray) -> MLXArray {
        let ids = x.flattened()
        func rows(_ t: MLXArray) -> MLXArray { t.take(ids, axis: 0, stream: .cpu) }
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
