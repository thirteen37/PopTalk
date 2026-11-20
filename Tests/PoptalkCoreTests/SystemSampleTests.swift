import Foundation
import Testing
@testable import PoptalkCore

@Test func summaryLineFormatsWallCPULoadThermalAndLowPower() {
    let s = SystemSample(load: 6.24, cpus: 12, thermal: "nominal", lowPower: false, cpuMs: 310.4)
    #expect(s.summary(wallMs: 842.3) == "request 842ms (cpu 310ms) load 6.2/12 thermal nominal lpm off")
    let hot = SystemSample(load: 29, cpus: 10, thermal: "serious", lowPower: true, cpuMs: 0)
    #expect(hot.summary(wallMs: 5000) == "request 5000ms (cpu 0ms) load 29.0/10 thermal serious lpm on")
}

@Test func nowSamplesTheMachineAndEndedGivesCPUSinceCapture() {
    let s = SystemSample.now()
    #expect(s.cpus > 0 && s.load >= 0 && s.cpuMs > 0)
    #expect(["nominal", "fair", "serious", "critical"].contains(s.thermal))
    var x = 0.0
    for i in 0..<2_000_000 { x += Double(i).squareRoot() }  // burn some CPU
    #expect(x > 0)
    let e = s.ended()
    #expect(e.cpuMs > 0 && e.cpuMs < SystemSample.processCPUMs())
    #expect(e.load == s.load && e.thermal == s.thermal)
}

@Test func historyRequestCarriesSystemAndOldLinesStillDecode() throws {
    var r = HistoryRequest(id: UUID(), at: Date(timeIntervalSince1970: 1_700_000_000), app: "Slack",
                           rawTranscript: "x", transcript: "x", provider: "mlx", outcome: .nothing, latency: 1)
    let old = try HistoryStore.encoder.encode(r)
    #expect(!String(decoding: old, as: UTF8.self).contains("system"))
    #expect(try HistoryStore.decoder.decode(HistoryRequest.self, from: old).system == nil)
    r.system = SystemSample(load: 2, cpus: 8, thermal: "fair", lowPower: false, cpuMs: 120)
    let line = try HistoryStore.encoder.encode(r)
    #expect(String(decoding: line, as: UTF8.self)
        .contains(#""system":{"cpuMs":120,"cpus":8,"load":2,"lowPower":false,"thermal":"fair"}"#))
    #expect(try HistoryStore.decoder.decode(HistoryRequest.self, from: line) == r)
}
