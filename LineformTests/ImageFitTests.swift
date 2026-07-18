import XCTest
@testable import Lineform

final class ImageFitTests: XCTestCase {
    func testMaxHeightCeilingAtLargeViewport() {
        XCTAssertEqual(ImageFit.maxHeight(visibleViewportHeight: 1200), 500, accuracy: 0.001)
    }

    func testMaxHeightShrinksOnSmallerWindow() {
        XCTAssertEqual(ImageFit.maxHeight(visibleViewportHeight: 600), 420, accuracy: 0.001)
    }

    func testMaxHeightFloorAtVeryShortViewport() {
        XCTAssertEqual(ImageFit.maxHeight(visibleViewportHeight: 200), 240, accuracy: 0.001)
    }

    func testLandscapeFitsToColumnWidthWellUnderCap() {
        let fitted = ImageFit.size(for: CGSize(width: 1600, height: 900), in: CGSize(width: 700, height: 500))
        XCTAssertEqual(fitted.width, 700, accuracy: 0.001)
        XCTAssertLessThan(fitted.height, 500)
        XCTAssertEqual(fitted.height, 393.75, accuracy: 0.01)
    }

    func testTallPortraitCapsAtMaxHeightAndIsNarrowerThanColumn() {
        let fitted = ImageFit.size(for: CGSize(width: 600, height: 1200), in: CGSize(width: 700, height: 500))
        XCTAssertEqual(fitted.height, 500, accuracy: 0.001)
        XCTAssertLessThan(fitted.width, 700)
        XCTAssertEqual(fitted.width, 250, accuracy: 0.01)
    }

    func testSmallImageReturnsNativeSizeNoUpscale() {
        let fitted = ImageFit.size(for: CGSize(width: 120, height: 80), in: CGSize(width: 700, height: 500))
        XCTAssertEqual(fitted.width, 120, accuracy: 0.001)
        XCTAssertEqual(fitted.height, 80, accuracy: 0.001)
    }
}
