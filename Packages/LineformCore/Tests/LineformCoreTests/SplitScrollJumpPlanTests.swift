import XCTest
@testable import LineformCore

/// Moved from the Mac's `LiveReloadScrollTests` with `SplitScrollJumpPlan`.
final class SplitScrollJumpPlanTests: XCTestCase {
    func testSplitJumpUsesOnePhysicalSourceWhenLinkedAndBothPanesWhenUnlinked() {
        let range = NSRange(location: 420, length: 12)

        let linked = SplitScrollJumpPlan(range: range, isLinked: true)
        XCTAssertEqual(linked.editorRange, range)
        XCTAssertNil(linked.previewRange)

        let unlinked = SplitScrollJumpPlan(range: range, isLinked: false)
        XCTAssertEqual(unlinked.editorRange, range)
        XCTAssertEqual(unlinked.previewRange, range)
    }
}
