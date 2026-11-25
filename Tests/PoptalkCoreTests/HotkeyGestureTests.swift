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

@Test func tapThenHold() {
    #expect(run([.down(0), .up(0.1), .down(0.3), .up(2)]) == [.tap, .hold])
}

@Test func holdResetsTheSequence() {
    #expect(run([.down(0), .up(2), .down(2.1), .up(2.2), .down(2.3), .up(2.4)]) == [.hold, .tap, .doubleTap])
    #expect(run([.down(0), .up(0.1), .down(0.2), .up(2), .down(2.1), .up(2.2)]) == [.tap, .hold, .tap])
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
    let r = g.release(at: t0 + 0.2)
    #expect(r == .hold)
}
