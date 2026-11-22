import CoreGraphics
import XCTest
@testable import LineformCore

/// The typewriter maths, moved from `LineformTextView.typewriterScrollOrigin(for:visibleBounds:)`.
final class TypewriterScrollTests: XCTestCase {
    func testCentresTheCaretLineAndKeepsTheHorizontalOrigin() {
        let origin = TypewriterScroll.origin(
            for: CGRect(x: 40, y: 900, width: 600, height: 20),
            visibleBounds: CGRect(x: 12, y: 300, width: 800, height: 600),
            contentHeight: 5_000
        )
        XCTAssertEqual(origin, CGPoint(x: 12, y: 610)) // midY 910 − 300
    }

    func testNeverScrollsAboveTheTop() {
        let origin = TypewriterScroll.origin(
            for: CGRect(x: 0, y: 10, width: 600, height: 20),
            visibleBounds: CGRect(x: 0, y: 0, width: 800, height: 600),
            contentHeight: 5_000
        )
        XCTAssertEqual(origin.y, 0)
    }

    func testNeverScrollsPastTheEndOfTheContent() {
        let origin = TypewriterScroll.origin(
            for: CGRect(x: 0, y: 980, width: 600, height: 20),
            visibleBounds: CGRect(x: 0, y: 0, width: 800, height: 600),
            contentHeight: 1_000
        )
        XCTAssertEqual(origin.y, 400) // 1000 − 600, not 990 − 300 = 690
    }

    /// With no content limit it is exactly the Mac's formula: `max(0, midY − height / 2)`.
    func testUnboundedContentMatchesTheMacFormula() {
        let line = CGRect(x: 0, y: 4_000, width: 600, height: 20)
        let visible = CGRect(x: 5, y: 0, width: 800, height: 600)
        let origin = TypewriterScroll.origin(for: line, visibleBounds: visible, contentHeight: .greatestFiniteMagnitude)
        XCTAssertEqual(origin, CGPoint(x: 5, y: max(0, line.midY - visible.height / 2)))
    }
}
