import Foundation

// Real-voice speech bench (#99): `PoptalkBench --record` writes `DIR/<id>.wav`; `--audio-dir DIR` reads it back.
extension BenchCase {
    public enum AudioSource: Equatable, Sendable {
        /// A recording in `--audio-dir`.
        case real(String)
        /// The case's own `audio` file.
        case file(String)
        /// Synthesized from `speak`.
        case speak

        public var label: String {
            switch self {
            case .real: "real"
            case .file: "file"
            case .speak: "speak"
            }
        }
    }

    /// `audioDir/<id>.wav` when it exists, else the case's `audio`, else `speak`; nil for a text case.
    public func audioSource(audioDir: String?, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> AudioSource? {
        guard hasAudio else { return nil }
        if let audioDir, case let path = BenchCase.recording(id, dir: audioDir), exists(path) { return .real(path) }
        return audio.map(AudioSource.file) ?? .speak
    }

    public static func recording(_ id: String, dir: String) -> String { (dir as NSString).appendingPathComponent("\(id).wav") }

    /// Cases with a script to read, minus those already recorded in `dir` unless `redo`, so a session resumes.
    public static func toRecord(_ cases: [BenchCase], dir: String, redo: Bool,
                                exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [BenchCase] {
        cases.filter { $0.speak != nil && (redo || !exists(recording($0.id, dir: dir))) }
    }
}

public enum WAV {
    /// 16-bit PCM mono WAV of `samples` (−1…1, clipped), 16 kHz by default as Parakeet expects.
    public static func pcm16(_ samples: [Float], sampleRate: Int = 16_000) -> Data {
        var d = Data()
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { d.append(contentsOf: $0) } }
        let bytes = 2 * samples.count
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
        d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
        u32(sampleRate); u32(2 * sampleRate); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        for s in samples { withUnsafeBytes(of: Int16((max(-1, min(1, s)) * 32767).rounded()).littleEndian) { d.append(contentsOf: $0) } }
        return d
    }
}
