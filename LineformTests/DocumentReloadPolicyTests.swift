import XCTest
@testable import Lineform

final class DocumentReloadPolicyTests: XCTestCase {
    func testDirtyDocumentIsNeverReloaded() {
        XCTAssertEqual(
            DocumentReloadPolicy.decide(isDocumentEdited: true, diskText: "new", currentText: "old"),
            .ignoreDirty
        )
    }

    func testUnchangedDiskContentIsIgnored() {
        XCTAssertEqual(
            DocumentReloadPolicy.decide(isDocumentEdited: false, diskText: "same", currentText: "same"),
            .ignoreUnchanged
        )
    }

    func testCleanChangedContentReloads() {
        XCTAssertEqual(
            DocumentReloadPolicy.decide(isDocumentEdited: false, diskText: "new", currentText: "old"),
            .reload
        )
    }

    func testDebounceIntervalIsThreeHundredMilliseconds() {
        XCTAssertEqual(DocumentReloadPolicy.debounceInterval, 0.3, accuracy: 0.0001)
    }

    func testScrollRatioAtTopIsZero() {
        XCTAssertEqual(ProportionalScrollMath.ratio(originY: 0, documentHeight: 1000, viewportHeight: 200), 0, accuracy: 0.0001)
    }

    func testScrollRatioAtBottomIsOne() {
        XCTAssertEqual(ProportionalScrollMath.ratio(originY: 800, documentHeight: 1000, viewportHeight: 200), 1, accuracy: 0.0001)
    }

    func testScrollRatioMidpoint() {
        XCTAssertEqual(ProportionalScrollMath.ratio(originY: 400, documentHeight: 1000, viewportHeight: 200), 0.5, accuracy: 0.0001)
    }

    func testScrollRatioWithNoScrollableRangeIsZero() {
        XCTAssertEqual(ProportionalScrollMath.ratio(originY: 0, documentHeight: 100, viewportHeight: 200), 0, accuracy: 0.0001)
    }

    func testOriginYRoundTripsFromRatio() {
        XCTAssertEqual(ProportionalScrollMath.originY(ratio: 0.5, documentHeight: 1000, viewportHeight: 200), 400, accuracy: 0.0001)
    }

    func testOriginYClampsRatioAboveOne() {
        XCTAssertEqual(ProportionalScrollMath.originY(ratio: 1.5, documentHeight: 1000, viewportHeight: 200), 800, accuracy: 0.0001)
    }
}
