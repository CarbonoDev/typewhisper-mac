import XCTest
@testable import TypeWhisper

/// Pure tests for where the floating call controls sit and how big they are on a given screen.
final class MeetCallControlLayoutTests: XCTestCase {
    private let builtIn = MeetCallControlScreenFacts(isBuiltIn: true, name: "Built-in Retina Display", physicalWidthMM: 345)
    private let monitor = MeetCallControlScreenFacts(isBuiltIn: false, name: "Studio Display", physicalWidthMM: 597)
    private let sidecar = MeetCallControlScreenFacts(isBuiltIn: false, name: "Sidecar Display", physicalWidthMM: nil)

    // MARK: - Size

    func testAFixedSizeIgnoresTheScreen() {
        for screen in [builtIn, monitor, sidecar] {
            XCTAssertEqual(MeetCallControlMetrics.scale(for: .regular, on: screen), 1)
            XCTAssertEqual(MeetCallControlMetrics.scale(for: .large, on: screen), 1.5)
            XCTAssertEqual(MeetCallControlMetrics.scale(for: .extraLarge, on: screen), 2)
        }
    }

    func testAutomaticIsLargerOnlyOnATabletSizedExternalDisplay() {
        XCTAssertEqual(MeetCallControlMetrics.scale(for: .automatic, on: builtIn), 1)
        XCTAssertEqual(MeetCallControlMetrics.scale(for: .automatic, on: monitor), 1)
        XCTAssertEqual(MeetCallControlMetrics.scale(for: .automatic, on: sidecar), MeetCallControlMetrics.tabletScale)

        // An iPad that reports its physical size but an unhelpful name is still a tablet.
        let unnamedTablet = MeetCallControlScreenFacts(isBuiltIn: false, name: "Display", physicalWidthMM: 262)
        XCTAssertTrue(MeetCallControlMetrics.looksLikeTablet(unnamedTablet))
        // A small built-in panel is the Mac itself, and a display that reports nothing is unknown.
        let smallLaptop = MeetCallControlScreenFacts(isBuiltIn: true, name: "Built-in Display", physicalWidthMM: 286)
        XCTAssertFalse(MeetCallControlMetrics.looksLikeTablet(smallLaptop))
        let unknown = MeetCallControlScreenFacts(isBuiltIn: false, name: "Display", physicalWidthMM: nil)
        XCTAssertFalse(MeetCallControlMetrics.looksLikeTablet(unknown))
    }

    func testEveryDimensionGrowsWithTheScale() {
        let regular = MeetCallControlMetrics(scale: 1)
        let double = MeetCallControlMetrics(scale: 2)
        XCTAssertEqual(regular.puckDiameter, 44)
        XCTAssertEqual(double.puckDiameter, 88)
        XCTAssertEqual(double.panelSize.width, regular.panelSize.width * 2)
        XCTAssertEqual(double.reach, regular.reach * 2)
        // The widest pill (mic + two extra buttons) still fits inside the panel.
        for metrics in [regular, double] {
            let pill = 2 * metrics.shadowMargin + 2 * metrics.pillPadding + metrics.puckDiameter
                + 2 * (metrics.secondaryDiameter + metrics.spacing)
            XCTAssertLessThanOrEqual(pill, metrics.panelSize.width)
        }
    }

    // MARK: - Position

    func testOriginAndAnchorAreInversesOnBothSides() {
        let metrics = MeetCallControlMetrics(scale: 1.5)
        let anchor = CGPoint(x: 900, y: 420)
        for trailing in [false, true] {
            let origin = metrics.origin(forAnchor: anchor, trailingAligned: trailing)
            XCTAssertEqual(metrics.anchor(forOrigin: origin, trailingAligned: trailing), anchor)
        }
        // Trailing-aligned, the panel extends to the left of the button instead of to the right.
        XCTAssertLessThan(
            metrics.origin(forAnchor: anchor, trailingAligned: true).x,
            metrics.origin(forAnchor: anchor, trailingAligned: false).x
        )
    }

    func testTheSameRelativeSpotIsFoundOnAScreenOfAnotherSize() {
        let laptop = CGRect(x: 0, y: 0, width: 1512, height: 944)
        let ipad = CGRect(x: 1512, y: 100, width: 1366, height: 1000)
        let position = MeetCallControlPosition(anchor: CGPoint(x: 1134, y: 236), in: laptop)
        XCTAssertEqual(position.fx, 0.75, accuracy: 0.001)
        XCTAssertEqual(position.fy, 0.25, accuracy: 0.001)

        let onIPad = position.anchor(in: ipad, reach: 40)
        XCTAssertEqual(onIPad.x, 1512 + 0.75 * 1366, accuracy: 0.5)
        XCTAssertEqual(onIPad.y, 100 + 0.25 * 1000, accuracy: 0.5)
    }

    func testAPositionAtTheEdgeKeepsTheWholeButtonOnScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let corner = MeetCallControlPosition(fx: 1, fy: 0).anchor(in: screen, reach: 60)
        XCTAssertEqual(corner, CGPoint(x: 940, y: 60))
        // A point outside the screen (a display that went away) is pulled back in.
        let outside = MeetCallControlPosition(anchor: CGPoint(x: -500, y: 5000), in: screen)
        XCTAssertEqual(outside.anchor(in: screen, reach: 60), CGPoint(x: 60, y: 740))
    }

    func testPositionsRoundTripThroughTheirStoredFormAndRejectJunk() {
        let position = MeetCallControlPosition(fx: 0.3125, fy: 0.875)
        XCTAssertEqual(MeetCallControlPosition(encoded: position.encoded), position)
        XCTAssertNil(MeetCallControlPosition(encoded: nil))
        XCTAssertNil(MeetCallControlPosition(encoded: "464"))
        XCTAssertNil(MeetCallControlPosition(encoded: "left,top"))
        // Out-of-range values are clamped rather than trusted.
        XCTAssertEqual(MeetCallControlPosition(encoded: "7,-3"), MeetCallControlPosition(fx: 1, fy: 0))
    }
}
