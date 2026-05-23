import XCTest
@testable import Lineform

final class MarkdownDiffTests: XCTestCase {
    func testDiffReportsChangedLinesForAccessibleNavigation() {
        let diff = MarkdownDiff.make(
            original: "One\nTwo\nThree",
            replacement: "One\nSecond\nThree"
        )

        XCTAssertEqual(diff.changes.count, 1)
        XCTAssertEqual(diff.changes.first?.accessibilityLabel, "Changed line 2")
        XCTAssertEqual(diff.summary, "1 changed line")
    }

    func testDiffReportsNoChanges() {
        let diff = MarkdownDiff.make(original: "Same", replacement: "Same")

        XCTAssertTrue(diff.changes.isEmpty)
        XCTAssertEqual(diff.summary, "No text changes")
    }
}
