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

    static func error(_ url: URL, _ what: String) -> NSError {
        NSError(domain: "Safetensors", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(url.lastPathComponent): \(what)"])
    }
}
