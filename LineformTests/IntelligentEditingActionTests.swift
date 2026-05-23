import XCTest
@testable import Lineform

final class IntelligentEditingActionTests: XCTestCase {
    func testInitialActionsMatchPhaseSixPlan() {
        XCTAssertEqual(IntelligentEditingAction.allCases.map(\.title), [
            "Improve Readability",
            "Make Clearer",
            "Simplify",
            "Shorten",
            "Fix Grammar",
            "Make Scannable",
            "Turn into Bullets",
            "Clean Markdown",
        ])
    }

    func testEachActionHasKeyboardAccess() {
        XCTAssertEqual(Set(IntelligentEditingAction.allCases.map(\.keyEquivalent)).count, IntelligentEditingAction.allCases.count)
        XCTAssertTrue(IntelligentEditingAction.allCases.allSatisfy { !$0.keyEquivalent.isEmpty })
    }
}
