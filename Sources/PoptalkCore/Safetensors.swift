import Foundation

/// The safetensors container: an 8-byte little-endian header length, a JSON header naming each tensor's
/// dtype, shape and byte range (relative to the end of the header), then the tensor bytes.
public enum Safetensors {
    public struct Tensor: Equatable, Sendable {
        public var dtype: String, shape: [Int]
        /// Absolute byte range in the file.
        public var range: Range<Int>
        public var rowBytes: Int { shape.first.map { $0 > 0 ? range.count / $0 : 0 } ?? range.count }
        /// Absolute byte range of row `i` (the first dimension) in the file.
        public func row(_ i: Int) -> Range<Int> {
            let start = range.lowerBound + i * rowBytes
            return start ..< start + rowBytes
        }
    }

    public struct Header: Sendable {
        public var tensors: [String: Tensor]
        public var metadata: [String: String]?
        /// Where tensor data starts: the header's length.
        public var dataStart: Int

        public init(contentsOf url: URL) throws {
            let h = try FileHandle(forReadingFrom: url)
            defer { try? h.close() }
            let size = try h.seekToEnd()
            try h.seek(toOffset: 0)
            guard let prefix = try h.read(upToCount: 8), prefix.count == 8 else { throw Safetensors.error(url, "short file") }
            let n = prefix.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
            guard n < 100_000_000, 8 + n <= size, let json = try h.read(upToCount: Int(n)), json.count == Int(n),
                  let obj = try JSONSerialization.jsonObject(with: json) as? [String: Any]
            else { throw Safetensors.error(url, "bad header") }
            dataStart = 8 + Int(n)
            metadata = obj["__metadata__"] as? [String: String]
            tensors = [:]
            for (name, v) in obj where name != "__metadata__" {
                guard let e = v as? [String: Any], let dtype = e["dtype"] as? String, let shape = e["shape"] as? [Int],
                      let o = e["data_offsets"] as? [Int], o.count == 2, o[0] <= o[1], dataStart + o[1] <= size
                else { throw Safetensors.error(url, "bad entry \(name)") }
                tensors[name] = Tensor(dtype: dtype, shape: shape, range: dataStart + o[0] ..< dataStart + o[1])
            }
        }
    }

    /// Writes the tensors of `src` whose names pass `keep` to `dst`, byte for byte, with the metadata;
    /// then re-reads the header and checks the size.
    public static func copy(from src: URL, to dst: URL, keeping keep: (String) -> Bool) throws {
        let h = try Header(contentsOf: src)
        let kept = h.tensors.filter { keep($0.key) }.sorted { $0.value.range.lowerBound < $1.value.range.lowerBound }
        var json: [String: Any] = [:]
        if let m = h.metadata { json["__metadata__"] = m }
        var offset = 0
        for (name, t) in kept {
            json[name] = ["dtype": t.dtype, "shape": t.shape, "data_offsets": [offset, offset + t.range.count]] as [String: Any]
            offset += t.range.count
        }
        var header = try JSONSerialization.data(withJSONObject: json, options: .sortedKeys)
        header.append(contentsOf: repeatElement(UInt8(ascii: " "), count: (8 - header.count % 8) % 8))  // 8-byte aligned data

        guard FileManager.default.createFile(atPath: dst.path, contents: nil) else { throw error(dst, "can't create") }
        let input = try FileHandle(forReadingFrom: src), out = try FileHandle(forWritingTo: dst)
        defer { try? input.close(); try? out.close() }
        try out.write(contentsOf: withUnsafeBytes(of: UInt64(header.count).littleEndian) { Data($0) })
        try out.write(contentsOf: header)
        for (name, t) in kept {
            try input.seek(toOffset: UInt64(t.range.lowerBound))
            var left = t.range.count
            while left > 0 {
                guard let chunk = try input.read(upToCount: min(left, 64 << 20)), !chunk.isEmpty else { throw error(src, "short read in \(name)") }
                try out.write(contentsOf: chunk)
                left -= chunk.count
            }
        }
        try out.synchronize()
        let check = try Header(contentsOf: dst)
        let size = try FileManager.default.attributesOfItem(atPath: dst.path)[.size] as? Int
        guard check.tensors.count == kept.count, size == check.dataStart + offset else { throw error(dst, "verification failed") }
    }

    static func error(_ url: URL, _ what: String) -> NSError {
        NSError(domain: "Safetensors", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(url.lastPathComponent): \(what)"])
    }
}
