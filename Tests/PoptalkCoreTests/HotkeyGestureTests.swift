import Foundation
import Testing
@testable import PoptalkCore

private let t0 = Date(timeIntervalSince1970: 1000)

private enum Event { case down(TimeInterval), up(TimeInterval), key }

/// Feeds right-⌥ presses, releases and other keys; returns what each release was (nil: cancelled).
private func run(_ events: [Event]) -> [HotkeyGesture.Release?] {
    var g = HotkeyGesture()
    var out: [HotkeyGesture.Release?] = []
    for e in events {
        switch e {
        case .down(let t): g.press(at: t0 + t)
        case .up(let t): out.append(g.release(at: t0 + t))
        case .key: _ = g.otherKey()
        }
    }
    return out
}

@Test func singleTap() {
    #expect(run([.down(0), .up(0.1)]) == [.tap])
}

@Test func doubleTapInWindow() {
    #expect(run([.down(0), .up(0.1), .down(0.45), .up(0.55)]) == [.tap, .doubleTap])
}

@Test func secondTapTooLate() {
    #expect(run([.down(0), .up(0.1), .down(0.6), .up(0.7)]) == [.tap, .tap])
}

@Test func tapThenHoldEditsTheLastInsert() {
    #expect(run([.down(0), .up(0.1), .down(0.3), .up(2)]) == [.tap, .editHold])
}

@Test func tapThenLateHoldIsAPlainHold() {
    #expect(run([.down(0), .up(0.1), .down(0.6), .up(2)]) == [.tap, .hold])
}

@Test func otherKeyDuringTapThenHoldCancels() {
    #expect(run([.down(0), .up(0.1), .down(0.3), .key, .up(2)]) == [.tap, nil])
}

@Test func secondPressSplitsAtTheTapThreshold() {
    #expect(run([.down(0), .up(0.1), .down(0.25), .up(0.549)]) == [.tap, .doubleTap])
    #expect(run([.down(0), .up(0.1), .down(0.25), .up(0.551)]) == [.tap, .editHold])
}

// A deliberate tap often lasts 150-300 ms; no real dictation is that short.
@Test func slowTapsStillTap() {
    #expect(run([.down(0), .up(0.2)]) == [.tap])
    #expect(run([.down(0), .up(0.28)]) == [.tap])
    #expect(run([.down(0), .up(0.31)]) == [.hold])
}

@Test func slowDoubleTapUndoes() {
    #expect(run([.down(0), .up(0.2), .down(0.4), .up(0.68)]) == [.tap, .doubleTap])
    #expect(run([.down(0), .up(0.28), .down(0.5), .up(0.7)]) == [.tap, .doubleTap])
}

@Test func secondPressIsKnownAtPress() {
    var g = HotkeyGesture()
    let first = g.press(at: t0)
    _ = g.release(at: t0 + 0.1)
    let second = g.press(at: t0 + 0.3)
    #expect(!first && second)
}

@Test func holdResetsTheSequence() {
    #expect(run([.down(0), .up(2), .down(2.1), .up(2.2), .down(2.3), .up(2.4)]) == [.hold, .tap, .doubleTap])
    #expect(run([.down(0), .up(0.1), .down(0.2), .up(2), .down(2.1), .up(2.2)]) == [.tap, .editHold, .tap])
}

@Test func otherKeyBetweenTapsResets() {
    #expect(run([.down(0), .up(0.1), .key, .down(0.3), .up(0.4)]) == [.tap, .tap])
}

@Test func threeTapsStartANewSequence() {
    let taps: [Event] = (0..<4).flatMap { i in [Event.down(Double(i) * 0.3), .up(Double(i) * 0.3 + 0.1)] }
    #expect(run(taps) == [.tap, .doubleTap, .tap, .doubleTap])
}

@Test func otherKeyDuringHoldCancelsOnce() {
    var g = HotkeyGesture()
    let idle = g.otherKey()  // nothing pressed
    g.press(at: t0)
    let (first, again) = (g.otherKey(), g.otherKey())  // the second: already cancelled
    let (released, unpressed) = (g.release(at: t0 + 1), g.release(at: t0 + 2))
    #expect(!idle && first && !again)
    #expect(released == nil && unpressed == nil)
}

@Test func repeatedPressIsIgnored() {
    var g = HotkeyGesture()
    g.press(at: t0)
    g.press(at: t0 + 0.1)  // a second "down" while held keeps the first press
    let r = g.release(at: t0 + 0.35)  // 0.25 s after the repeat: a tap had it replaced the press
    #expect(r == .hold)
}

// #111: a tap accepts a showing offer only once the double-tap window has passed with nothing else pressed.
@Test func singleTapWithOfferAcceptsAfterTheWindow() {
    var g = HotkeyGesture()
    g.press(at: t0)
    let tap = g.release(at: t0 + 0.1)
    let (early, settled, again) = (g.tapSettled(at: t0 + 0.3), g.tapSettled(at: t0 + 0.6), g.tapSettled(at: t0 + 0.7))
    #expect(tap == .tap)
    #expect(!early && settled && !again)  // once
}

@Test func doubleTapWithOfferUndoesWithoutAccepting() {
    var g = HotkeyGesture()
    g.press(at: t0)
    _ = g.release(at: t0 + 0.1)
    g.press(at: t0 + 0.3)
    let settled = g.tapSettled(at: t0 + 0.6)
    let second = g.release(at: t0 + 0.4)
    let later = g.tapSettled(at: t0 + 1)
    #expect(!settled && second == .doubleTap && !later)
}

@Test func tapThenHoldWithOfferEditsWithoutAccepting() {
    var g = HotkeyGesture()
    g.press(at: t0)
    _ = g.release(at: t0 + 0.1)
    g.press(at: t0 + 0.3)
    let settled = g.tapSettled(at: t0 + 0.6)
    let second = g.release(at: t0 + 2)
    let later = g.tapSettled(at: t0 + 3)
    #expect(!settled && second == .editHold && !later)
}

@Test func singleTapCancelsAtOnce() {
    var g = HotkeyGesture()
    g.press(at: t0)
    let tap = g.release(at: t0 + 0.1)  // decided at the release: the cancel doesn't wait for the window
    #expect(tap == .tap)
}

@Test func otherKeyAfterTapDropsTheAccept() {
    var g = HotkeyGesture()
    g.press(at: t0)
    _ = g.release(at: t0 + 0.1)
    _ = g.otherKey()
    let settled = g.tapSettled(at: t0 + 0.6)
    #expect(!settled)
}
