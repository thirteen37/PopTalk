import Foundation
import Testing
@testable import PoptalkCore

// #99: real-voice recordings for the speech bench.

private let cases = try! BenchCase.load(jsonl: """
    {"id":"s-a","kind":"dictation","speak":"hello there"}
    {"id":"s-b","kind":"dictation","speak":"see you soon","audio":"bench/audio/b.m4a"}
    {"id":"d-c","kind":"dictation","transcript":"no audio"}
    {"id":"s-d","kind":"dictation","speak":"one more","vocabulary":["Saoirse"],"written":"One more."}
    """)

@Test func audioDirRecordingWinsOverSpeakAndAudio() {
    let have: Set = ["real/s-a.wav", "real/s-b.wav"]
    let src = cases.map { $0.audioSource(audioDir: "real", exists: have.contains) }
    #expect(src == [.real("real/s-a.wav"), .real("real/s-b.wav"), nil, .speak])
    #expect(src.map { $0?.label } == ["real", "real", nil, "speak"])
}

@Test func withoutARecordingFallsBackToTheCaseAudio() {
    let src = cases.map { $0.audioSource(audioDir: "real", exists: { _ in false }) }
    #expect(src == [.speak, .file("bench/audio/b.m4a"), nil, .speak])
    #expect(cases[0].audioSource(audioDir: nil, exists: { _ in true }) == .speak)
}

@Test func recordingSkipsRecordedCasesUnlessRedo() {
    let have: Set = ["real/s-a.wav"]
    #expect(BenchCase.toRecord(cases, dir: "real", redo: false, exists: have.contains).map(\.id) == ["s-b", "s-d"])
    #expect(BenchCase.toRecord(cases, dir: "real", redo: true, exists: have.contains).map(\.id) == ["s-a", "s-b", "s-d"])
}

@Test func decodesVocabularyAndWrittenReference() {
    #expect(cases[3].vocabulary == ["Saoirse"])
    #expect(cases[3].written == "One more.")
    #expect(cases[0].vocabulary == [] && cases[0].written == nil)
}

@Test func wavIs16kMono16BitPCM() {
    let d = WAV.pcm16([0, 1, -1, 2, 0.5])
    func u32(_ o: Int) -> UInt32 { d[o..<o + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) } }
    func u16(_ o: Int) -> UInt16 { UInt16(d[o]) | UInt16(d[o + 1]) << 8 }
    func i16(_ o: Int) -> Int16 { Int16(bitPattern: u16(o)) }
    #expect(d.count == 44 + 10)
    #expect(String(decoding: d[0..<4], as: UTF8.self) == "RIFF" && u32(4) == 36 + 10)
    #expect(String(decoding: d[8..<16], as: UTF8.self) == "WAVEfmt ")
    #expect(u32(16) == 16 && u16(20) == 1 && u16(22) == 1)  // PCM, mono
    #expect(u32(24) == 16_000 && u32(28) == 32_000 && u16(32) == 2 && u16(34) == 16)
    #expect(String(decoding: d[36..<40], as: UTF8.self) == "data" && u32(40) == 10)
    #expect([i16(44), i16(46), i16(48), i16(50), i16(52)] == [0, 32767, -32767, 32767, 16384])  // clipped
}

@Test func speechTableSplitsByAudioSource() {
    func run() -> BenchRun {
        var r = BenchRun(output: "x", action: "insert", vocabOffer: nil, seconds: 1, failures: [])
        r.speech = SpeechRun(reference: "a b", terms: [], raw: "a b", boosted: "a b", final: "a b", boostTerms: 0, asrSeconds: 0, rescoreSeconds: 0)
        return r
    }
    let one = BenchReport(date: "d", provider: [:], cases: [BenchCaseResult(id: "s-a", kind: .dictation, runs: [run()], audio: "speak")])
    #expect(one.table().contains("speech     pass 1/1"))
    let mixed = BenchReport(date: "d", provider: [:], cases: [
        BenchCaseResult(id: "s-a", kind: .dictation, runs: [run()], audio: "real"),
        BenchCaseResult(id: "s-b", kind: .dictation, runs: [run(), run()], audio: "speak"),
    ])
    #expect(mixed.table().contains("speech real  pass 1/1") && mixed.table().contains("speech speak pass 2/2"))
}

@Test func finalWERScoresAgainstTheWrittenText() {
    let s = SpeechRun(reference: "at two no three", finalReference: "At three.", terms: [], raw: "at two no three", boosted: "at two no three",
                      final: "At three.", boostTerms: 0, asrSeconds: 0, rescoreSeconds: 0)
    #expect(s.werRaw == 0 && s.werFinal == 0)
}
