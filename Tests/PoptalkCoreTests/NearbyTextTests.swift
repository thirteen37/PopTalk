import CoreGraphics
import Testing
@testable import PoptalkCore

/// 0 window ─┬─ 1 thread ─┬─ 3 "Alice: hi"
///           │            └─ 4 "Bob: ship it"
///           └─ 2 composer ─┬─ 5 field (focused) "draft"
///                          └─ 6 "Send"
/// 9 ─┬─ 7 "label" ─ 8 "nested"
///     └─ 10 (focused)
private let kids: [Int: [Int]] = [0: [1, 2], 1: [3, 4], 2: [5, 6], 9: [7, 10], 7: [8]]
private let texts: [Int: String] = [3: "Alice: hi", 4: "Bob: ship it", 5: "draft", 6: "Send", 7: "label", 8: "nested"]
private let parents: [Int: Int] = { var p: [Int: Int] = [:]; for (k, v) in kids { for c in v { p[c] = k } }; return p }()

private func walk(_ start: Int = 5, maxUp: Int = 8, maxDepth: Int = 8, maxNodes: Int = 100, maxChars: Int = 1000,
                  expired: @escaping () -> Bool = { false }) -> [String] {
    NearbyText.collect(from: start, maxUp: maxUp, maxDepth: maxDepth, maxNodes: maxNodes, maxChars: maxChars,
                       parent: { parents[$0] }, visit: { (texts[$0], kids[$0] ?? []) }, expired: expired)
}

@Test func nearestSiblingsFirstThenOuterRings() {
    #expect(walk() == ["Send", "Alice: hi", "Bob: ship it"])
}

@Test func climbIsCapped() {
    #expect(walk(maxUp: 1) == ["Send"])
}

@Test func depthIsCapped() {
    #expect(walk(maxDepth: 0) == ["Send"])  // ring 2 children of 1 are one level below its root
}

@Test func nodeBudgetStopsTheWalk() {
    #expect(walk(maxNodes: 3) == ["Send"])  // ancestor 2, its child 6, ancestor 0
}

@Test func charBudgetStopsTheWalk() {
    #expect(walk(maxChars: 12) == ["Send", "Alice: h"])  // the overflowing text is cut, then the walk stops
}

@Test func expiryStopsTheWalk() {
    #expect(walk(expired: { true }).isEmpty)
}

@Test func doesNotDescendIntoTextNodes() {
    #expect(walk(10) == ["label"])
}

@Test func ocrCropIsBandAroundFieldInWindowCoordinates() {
    let window = CGRect(x: 100, y: 100, width: 800, height: 1000)
    let field = CGRect(x: 150, y: 900, width: 700, height: 60)
    #expect(NearbyText.ocrCrop(field: field, window: window) == CGRect(x: 0, y: 200, width: 800, height: 800))
}

@Test func ocrCropClampsToWindow() {
    let window = CGRect(x: 0, y: 0, width: 800, height: 600)
    let field = CGRect(x: 10, y: 50, width: 300, height: 30)
    #expect(NearbyText.ocrCrop(field: field, window: window) == CGRect(x: 0, y: 0, width: 800, height: 230))
}

@Test func ocrCropFallsBackToWholeWindow() {
    let window = CGRect(x: 0, y: 0, width: 800, height: 600)
    #expect(NearbyText.ocrCrop(field: nil, window: window) == CGRect(x: 0, y: 0, width: 800, height: 600))
    #expect(NearbyText.ocrCrop(field: CGRect(x: 2000, y: 2000, width: 10, height: 10), window: window)
        == CGRect(x: 0, y: 0, width: 800, height: 600))
}

@Test func ocrWhenFieldOrSurroundingsAreThin() {
    #expect(NearbyText.needsOCR(fieldChars: 10, nearbyChars: 5000))
    #expect(NearbyText.needsOCR(fieldChars: 5000, nearbyChars: 10))  // long compose box, thread not in AX
    #expect(!NearbyText.needsOCR(fieldChars: 5000, nearbyChars: 5000))
}
