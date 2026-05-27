import XCTest
@testable import Lineform

final class IntelligentEditingActionTests: XCTestCase {
    func testInitialActionsMatchPhaseSixPlan() {
        XCTAssertEqual(IntelligentEditingAction.allCases.map(\.title), [
            "Proofread",
            "Rewrite",
            "Summarize",
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

    func testMenuBarActionsExposeWritingToolsBeforeLineformSpecificMarkdownCommands() {
        XCTAssertEqual(IntelligentEditingAction.menuBarActions.map(\.title), [
            "Proofread",
            "Rewrite",
            "Summarize",
            "Improve Readability",
            "Make Clearer",
            "Simplify",
            "Shorten",
            "Make Scannable",
            "Turn into Bullets",
            "Clean Markdown"
        ])
    }

    func testRightClickActionsStayMinimal() {
        XCTAssertEqual(IntelligentEditingAction.rightClickActions.map(\.title), ["Clean Markdown"])
    }

    func testContextualActionsPrioritizeMarkdownCleanupForMarkdownHeavySelections() {
        let actions = IntelligentEditingAction.contextualActions(
            for: "# Title\n\n- rough item\n- second item"
        )

        XCTAssertEqual(actions.prefix(3).map(\.title), [
            "Clean Markdown",
            "Make Scannable",
            "Proofread"
        ])
    }

    func testContextualActionsPrioritizeSummariesForLongSelections() {
        let selection = Array(repeating: "This is a longer paragraph with enough words to benefit from summary and structure.", count: 8)
            .joined(separator: " ")

        let actions = IntelligentEditingAction.contextualActions(for: selection)

        XCTAssertEqual(actions.prefix(3).map(\.title), [
            "Summarize",
            "Shorten",
            "Make Scannable"
        ])
    }

    func testContextualActionsPrioritizeClarityForShortProseSelections() {
        let actions = IntelligentEditingAction.contextualActions(
            for: "This sentence feels a little awkward."
        )

        XCTAssertEqual(actions.prefix(3).map(\.title), [
            "Rewrite",
            "Make Clearer",
            "Proofread"
        ])
    }

    func testEachActionHasKeyboardAccess() {
        XCTAssertEqual(Set(IntelligentEditingAction.allCases.map(\.keyEquivalent)).count, IntelligentEditingAction.allCases.count)
        XCTAssertTrue(IntelligentEditingAction.allCases.allSatisfy { !$0.keyEquivalent.isEmpty })
    }
}
