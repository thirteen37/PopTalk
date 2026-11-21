import Foundation
import Testing
@testable import PoptalkCore

private let t0 = Date(timeIntervalSince1970: 1000)

/// Feeds (press, release) times; returns each press's `editLast` and each release's `tap`.
private func run(_ holds: [(TimeInterval, TimeInterval)]) -> [(edit: Bool, tap: Bool)] {
    var g = TapHold()
    return holds.map { down, up in
        let edit = g.press(at: t0 + down)
        return (edit, g.release(from: t0 + down, at: t0 + up))
    }
}

@Test func tapThenHoldEditsLast() {
    let r = run([(0, 0.1), (0.4, 2)])
    #expect(r[0] == (false, true))  // a tap: cancelled
    #expect(r[1] == (true, false))  // pressed within 0.4 s of the tap's release, then held
}

@Test func plainPressesDictate() {
    let r = run([(0, 2), (2.1, 4), (4.1, 4.15), (4.6, 6)])
    #expect(r[0] == (false, false))
    #expect(r[1] == (false, false))  // soon after a hold, not a tap
    #expect(r[2] == (false, true))
    #expect(r[3] == (false, false))  // too long after the tap
}

@Test func tapCountsOnce() {
    let r = run([(0, 0.1), (0.2, 1.5), (1.6, 3)])
    #expect(r[1].edit)
    #expect(!r[2].edit)  // the hold used up the tap
}
