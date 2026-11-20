import XCTest
@testable import LineformCore

final class LineformDesignTests: XCTestCase {
    /// The desktop values (spec §7), and the literals `FloatingCardChrome` used on `main`
    /// before they moved here. Both apps read these, so a change is a visual change on the Mac.
    func testDesignValuesAreTheDesktopValues() {
        XCTAssertEqual(LineformDesign.Radius.modal, 20)
        XCTAssertEqual(LineformDesign.Radius.card, 14)
        XCTAssertEqual(LineformDesign.Radius.floatingCard, 12)
        XCTAssertEqual(LineformDesign.Radius.row, 8)
        XCTAssertEqual(LineformDesign.Radius.button, 7)

        XCTAssertEqual(LineformDesign.Motion.hover, 0.12)
        XCTAssertEqual(LineformDesign.Motion.standard, 0.24)

        // FloatingCardChrome on main: `cornerRadius: 12`, `.strokeBorder(...)` (default 1pt) in
        // `Color.white.opacity(0.12)` / `Color.black.opacity(0.08)`, and
        // `.shadow(color: .black.opacity(dark ? 0.45 : 0.16), radius: 18, y: 6)`.
        XCTAssertEqual(LineformDesign.FloatingCard.radius, 12)
        XCTAssertEqual(LineformDesign.FloatingCard.hairlineWidth, 1)
        XCTAssertEqual(LineformDesign.FloatingCard.hairlineOpacityDark, 0.12)
        XCTAssertEqual(LineformDesign.FloatingCard.hairlineOpacityLight, 0.08)
        XCTAssertEqual(LineformDesign.FloatingCard.shadowRadius, 18)
        XCTAssertEqual(LineformDesign.FloatingCard.shadowOpacityDark, 0.45)
        XCTAssertEqual(LineformDesign.FloatingCard.shadowOpacityLight, 0.16)
        XCTAssertEqual(LineformDesign.FloatingCard.shadowOffset, CGSize(width: 0, height: 6))
    }
}
