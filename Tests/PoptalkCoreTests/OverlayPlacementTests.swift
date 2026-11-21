import CoreGraphics
import Testing
@testable import PoptalkCore

private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
private let size = CGSize(width: 300, height: 50)

@Test func defaultsToBottomCentre() {
    #expect(OverlayPlacement.frame(size: size, visible: screen, field: nil, anchor: nil)
            == CGRect(x: 350, y: 50, width: 300, height: 50))
}

@Test func usesRememberedAnchorRelativeToTheScreen() {
    let second = CGRect(x: 1000, y: 200, width: 1000, height: 800)
    #expect(OverlayPlacement.frame(size: size, visible: second, field: nil, anchor: CGPoint(x: 200, y: 600))
            == CGRect(x: 1050, y: 800, width: 300, height: 50))
}

@Test func clampsAnOffScreenAnchor() {
    #expect(OverlayPlacement.frame(size: size, visible: screen, field: nil, anchor: CGPoint(x: -500, y: 2000))
            == CGRect(x: 0, y: 750, width: 300, height: 50))
}

@Test func ignoresAFieldItDoesNotCover() {
    let field = CGRect(x: 100, y: 400, width: 200, height: 20)
    #expect(OverlayPlacement.frame(size: size, visible: screen, field: field, anchor: nil).minY == 50)
}

@Test func movesAboveACoveredField() {
    let field = CGRect(x: 400, y: 60, width: 200, height: 20)
    #expect(OverlayPlacement.frame(size: size, visible: screen, field: field, anchor: nil)
            == CGRect(x: 350, y: 80 + OverlayPlacement.margin, width: 300, height: 50))
}

@Test func aNearMissCountsAsCovering() {
    let field = CGRect(x: 400, y: 102, width: 200, height: 20)  // 2 pt above the overlay
    #expect(OverlayPlacement.frame(size: size, visible: screen, field: field, anchor: nil).minY == 122 + OverlayPlacement.margin)
}

@Test func goesToTheTopWhenAboveTheFieldDoesNotFit() {
    let field = CGRect(x: 0, y: 40, width: 1000, height: 740)
    #expect(OverlayPlacement.frame(size: size, visible: screen, field: field, anchor: nil).maxY == 800 - OverlayPlacement.margin)
}

@Test func avoidsTheFieldFromARememberedSpot() {
    let field = CGRect(x: 0, y: 500, width: 1000, height: 30)
    let f = OverlayPlacement.frame(size: size, visible: screen, field: field, anchor: CGPoint(x: 500, y: 490))
    #expect(f == CGRect(x: 350, y: 530 + OverlayPlacement.margin, width: 300, height: 50))
}

@Test func convertsAccessibilityToAppKitCoordinates() {
    // AX: top-left origin of the primary screen, y down. AppKit: bottom-left, y up.
    #expect(OverlayPlacement.appKit(CGRect(x: 10, y: 100, width: 50, height: 20), primaryHeight: 800)
            == CGRect(x: 10, y: 680, width: 50, height: 20))
}

@Test func anchorRoundTripsThroughAFrame() {
    let second = CGRect(x: 1000, y: 200, width: 1000, height: 800)
    let f = CGRect(x: 1050, y: 800, width: 300, height: 50)
    #expect(OverlayPlacement.anchor(of: f, visible: second) == CGPoint(x: 200, y: 600))
}

// #82: wrapped text grows the overlay upward; once it reaches the field, it moves above it.
@Test func aTallerOverlayMovesAboveTheFieldItGrowsInto() {
    let field = CGRect(x: 400, y: 200, width: 200, height: 20)
    #expect(OverlayPlacement.frame(size: size, visible: screen, field: field, anchor: nil).minY == 50)
    #expect(OverlayPlacement.frame(size: CGSize(width: 640, height: 190), visible: screen, field: field, anchor: nil)
            == CGRect(x: 180, y: 220 + OverlayPlacement.margin, width: 640, height: 190))
}
