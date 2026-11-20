import Testing
@testable import PoptalkCore

@Test func sharedPrefixCountsLeadingEqualTokens() {
    #expect(sharedPrefix([1, 2, 3, 4], [1, 2, 9, 4]) == 2)
    #expect(sharedPrefix([1, 2, 3], [1, 2, 3, 4, 5]) == 3)
    #expect(sharedPrefix([1, 2, 3], [1, 2, 3]) == 3)
    #expect(sharedPrefix([7], [1]) == 0)
    #expect(sharedPrefix([], [1, 2]) == 0)
}
