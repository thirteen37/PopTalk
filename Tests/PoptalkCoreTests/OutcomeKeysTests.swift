import Foundation
import Testing
@testable import PoptalkCore

@Test func undoWindowDefaultsAndClamps() {
    let d = UserDefaults(suiteName: "poptalk-test-\(UUID())")!
    #expect(OutcomeKeys.undoWindow(d) == 5)
    d.set(9, forKey: OutcomeKeys.undoWindowKey); #expect(OutcomeKeys.undoWindow(d) == 9)
    d.set(0, forKey: OutcomeKeys.undoWindowKey); #expect(OutcomeKeys.undoWindow(d) == 2)
    d.set(99, forKey: OutcomeKeys.undoWindowKey); #expect(OutcomeKeys.undoWindow(d) == 15)
}
