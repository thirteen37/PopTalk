import Foundation
import Testing
@testable import PoptalkCore

// Separate runs in the same minute (e.g. `--filter 'd-*'` then `'e-*'`) overwrote each other.
@Test func resultFileNamesHaveSecondsAndFilterSlug() {
    #expect(BenchReport.fileName(date: "2026-11-19-230801", provider: "lmstudio", model: "google/gemma-4-e4b-audio", filter: "s-*")
        == "2026-11-19-230801-lmstudio-google_gemma-4-e4b-audio-s.json")
    #expect(BenchReport.fileName(date: "d", provider: "apple", model: "core3", filter: "s-fluid*") == "d-apple-core3-s-fluid.json")
    #expect(BenchReport.fileName(date: "d", provider: "apple", model: "core3", filter: nil) == "d-apple-core3.json")
    #expect(BenchReport.fileName(date: "d", provider: "apple", model: "core3", filter: "*") == "d-apple-core3.json")
    #expect(BenchReport.dateFormat.hasSuffix("HHmmss"))
}
