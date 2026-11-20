import Foundation
import Testing
@testable import PoptalkCore

@Test func busyMarkerPathIsFixedUnderCaches() {
    #expect(BusyMarker.url(home: URL(fileURLWithPath: "/Users/x")).path == "/Users/x/Library/Caches/io.lyx.poptalk/busy")
}

@Test func busyMarkerHoldsPidWhileSetAndIsGoneWhenCleared() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("busy")
    BusyMarker.set(true, at: url)
    #expect(try String(contentsOf: url, encoding: .utf8) == "\(getpid())\n")
    BusyMarker.set(false, at: url)
    #expect(!FileManager.default.fileExists(atPath: url.path))
    BusyMarker.set(false, at: url)  // clearing an absent marker is fine
}
