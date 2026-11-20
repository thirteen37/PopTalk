import Foundation
import Testing
@testable import PoptalkCore

/// A safetensors file with `tensors` (name, shape, bytes) as U8, in order, plus metadata.
func safetensorsFile(_ tensors: [(String, [Int], [UInt8])], metadata: [String: String] = ["format": "mlx"]) -> URL {
    var header: [String: Any] = ["__metadata__": metadata]
    var body = Data(), offset = 0
    for (name, shape, bytes) in tensors {
        header[name] = ["dtype": "U8", "shape": shape, "data_offsets": [offset, offset + bytes.count]]
        body.append(contentsOf: bytes)
        offset += bytes.count
    }
    let json = try! JSONSerialization.data(withJSONObject: header, options: .sortedKeys)
    var file = Data()
    withUnsafeBytes(of: UInt64(json.count).littleEndian) { file.append(contentsOf: $0) }
    file.append(json)
    file.append(body)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).safetensors")
    try! file.write(to: url)
    return url
}

@Test func safetensorsHeaderGivesAbsoluteTensorRanges() throws {
    let url = safetensorsFile([("a", [2, 3], [1, 2, 3, 4, 5, 6]), ("b", [4], [7, 8, 9, 10])])
    let h = try Safetensors.Header(contentsOf: url)
    let file = try Data(contentsOf: url)
    #expect(h.tensors.count == 2)
    #expect(h.tensors["a"]?.shape == [2, 3])
    #expect(h.tensors["a"]?.dtype == "U8")
    #expect(h.metadata == ["format": "mlx"])
    #expect(file[h.tensors["b"]!.range] == Data([7, 8, 9, 10]))
}

@Test func safetensorsRowRangeIsOneRowOfTheTensor() throws {
    let url = safetensorsFile([("pad", [3], [0, 0, 0]), ("t", [3, 4], Array(0 ..< 12))])
    let h = try Safetensors.Header(contentsOf: url)
    let file = try Data(contentsOf: url)
    let t = h.tensors["t"]!
    #expect(t.rowBytes == 4)
    #expect(file[t.row(0)] == Data([0, 1, 2, 3]))
    #expect(file[t.row(2)] == Data([8, 9, 10, 11]))
}

@Test func safetensorsRejectsGarbage() {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).safetensors")
    try! Data([255, 255, 255, 255, 255, 255, 255, 255, 1]).write(to: url)
    #expect(throws: (any Error).self) { try Safetensors.Header(contentsOf: url) }
}
