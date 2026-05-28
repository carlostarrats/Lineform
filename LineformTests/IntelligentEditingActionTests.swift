import XCTest
@testable import Lineform

final class IntelligentEditingActionTests: XCTestCase {
    func testInitialActionsMatchPhaseSixPlan() {
        XCTAssertEqual(IntelligentEditingAction.allCases.map(\.title), [
            "Proofread",
            "Rewrite",
            "Summarize",
            "Make Shorter",
            "Clean Markdown",
        ])
    }

    func testMenuBarActionsStayConcreteForMarkdownTextEditing() {
        XCTAssertEqual(IntelligentEditingAction.menuBarActions.map(\.title), [
            "Proofread",
            "Rewrite",
            "Summarize",
            "Make Shorter",
            "Clean Markdown"
        ])
    }

    func testRightClickActionsStayMinimal() {
        XCTAssertTrue(IntelligentEditingAction.rightClickActions.isEmpty)
    }

    func testActionRailActionsMatchWriteModeSelectedTextWorkflow() {
        XCTAssertEqual(IntelligentEditingAction.actionRailActions.map(\.title), [
            "Clean Markdown",
            "Proofread",
            "Rewrite",
            "Make Shorter"
        ])
    }

    func testActionRailLabelsStayShortEnoughForBottomDock() {
        XCTAssertEqual(IntelligentEditingAction.actionRailActions.map(\.railDisplayTitle), [
            "Clean",
            "Proofread",
            "Rewrite",
            "Shorten"
        ])
    }

    func testActionRailIconsUseConcreteActionMetaphors() {
        XCTAssertEqual(IntelligentEditingAction.cleanMarkdown.railSystemImage, "paintbrush.pointed")
        XCTAssertEqual(IntelligentEditingAction.proofread.railSystemImage, "eye")
    }

    func testContextualActionsPrioritizeMarkdownCleanupForMarkdownHeavySelections() {
        let actions = IntelligentEditingAction.contextualActions(
            for: "# Title\n\n- rough item\n- second item"
        )

        XCTAssertEqual(actions.prefix(3).map(\.title), [
            "Clean Markdown",
            "Proofread",
            "Rewrite"
        ])
    }

    func testContextualActionsPrioritizeConcreteCompressionForLongSelections() {
        let selection = Array(repeating: "This is a longer paragraph with enough words to benefit from summary and structure.", count: 8)
            .joined(separator: " ")

        let actions = IntelligentEditingAction.contextualActions(for: selection)

        XCTAssertEqual(actions.prefix(3).map(\.title), [
            "Make Shorter",
            "Summarize",
            "Proofread"
        ])
    }

    func testContextualActionsPrioritizeRewriteForShortProseSelections() {
        let actions = IntelligentEditingAction.contextualActions(
            for: "This sentence feels a little awkward."
        )

        XCTAssertEqual(actions.prefix(3).map(\.title), [
            "Rewrite",
            "Proofread",
            "Make Shorter"
        ])
    }

    func testEachActionHasKeyboardAccess() {
        XCTAssertEqual(Set(IntelligentEditingAction.allCases.map(\.keyEquivalent)).count, IntelligentEditingAction.allCases.count)
        XCTAssertTrue(IntelligentEditingAction.allCases.allSatisfy { !$0.keyEquivalent.isEmpty })
    }

    func testSuggestionReviewControlsIncludeRetryBeforeFinalDecision() {
        XCTAssertEqual(IntelligentEditingReviewControls.buttonTitles, [
            "Try Again",
            "Reject",
            "Accept"
        ])
        XCTAssertTrue(IntelligentEditingReviewControls.usesPointingHandCursor)
        XCTAssertTrue(IntelligentEditingReviewControls.usesAppKitCursorRect)
        XCTAssertTrue(IntelligentEditingReviewControls.reassertsPointingHandCursorWhileHovered)
        XCTAssertTrue(IntelligentEditingReviewControls.cursorRectFillsControlBounds)
    }

    func testShortSelectionsUseThreeLineformOwnedOptions() {
        XCTAssertEqual(
            IntelligentEditingPresentationPolicy.optionCount(for: "This sentence needs a cleaner shape."),
            3
        )
    }

    func testTinySelectionsUseSingleSuggestionToAvoidPromptPlaceholderOptions() {
        XCTAssertEqual(IntelligentEditingPresentationPolicy.optionCount(for: "editor"), 1)
        XCTAssertEqual(IntelligentEditingPresentationPolicy.optionCount(for: "better title"), 1)
    }

    func testOnlyRewriteUsesMultipleCreativeOptions() {
        let selection = "The editor keep files local and dont upload drafts."

        XCTAssertEqual(
            IntelligentEditingPresentationPolicy.optionCount(for: .proofread, selectedText: selection),
            1
        )
        XCTAssertEqual(
            IntelligentEditingPresentationPolicy.optionCount(for: .shorten, selectedText: selection),
            1
        )
        XCTAssertEqual(
            IntelligentEditingPresentationPolicy.optionCount(for: .summarize, selectedText: selection),
            1
        )
        XCTAssertEqual(
            IntelligentEditingPresentationPolicy.optionCount(for: .cleanMarkdown, selectedText: "-  item\n-    item"),
            1
        )
        XCTAssertEqual(
            IntelligentEditingPresentationPolicy.optionCount(for: .rewrite, selectedText: selection),
            3
        )
    }

    func testSelectionsAtOneHundredWordsUseOneReviewSuggestion() {
        let selection = Array(repeating: "word", count: 100).joined(separator: " ")

        XCTAssertEqual(IntelligentEditingPresentationPolicy.optionCount(for: selection), 1)
    }

    func testShortOptionPanelUsesCompactInlinePresentation() {
        XCTAssertNil(IntelligentEditingOptionsPresentation.previewLineLimit)
        XCTAssertFalse(IntelligentEditingOptionsPresentation.truncatesCompactSuggestions)
        XCTAssertEqual(IntelligentEditingOptionsPresentation.compactPreviewFontSize, 16)
        XCTAssertEqual(IntelligentEditingOptionsPresentation.optionChipSize, 36)
        XCTAssertEqual(IntelligentEditingOptionsPresentation.optionChipCornerRadius, 10)
        XCTAssertEqual(IntelligentEditingOptionsPresentation.compactMaximumWidth, 560)
        XCTAssertEqual(IntelligentEditingOptionsPresentation.expandedMaximumWidth, 900)
        XCTAssertTrue(IntelligentEditingOptionsPresentation.usesSingleVisibleSuggestion)
        XCTAssertTrue(IntelligentEditingOptionsPresentation.usesNestedPreviewCard)
        XCTAssertEqual(IntelligentEditingOptionsPresentation.regenerateSystemImage, "arrow.clockwise")
        XCTAssertTrue(IntelligentEditingOptionsPresentation.controlsUsePointingHandCursor)
        XCTAssertTrue(IntelligentEditingOptionsPresentation.controlsUseAppKitCursorRect)
        XCTAssertTrue(IntelligentEditingOptionsPresentation.controlsReassertPointingHandCursorWhileHovered)
        XCTAssertTrue(IntelligentEditingOptionsPresentation.controlCursorRectFillsControlBounds)
    }

    func testIntelligenceLoadingPanelUsesSkeletonBeforeResultsArrive() {
        XCTAssertTrue(IntelligentEditingOptionsPresentation.showsLoadingSkeleton)
        XCTAssertEqual(IntelligentEditingOptionsPresentation.loadingSkeletonMinimumRows, 9)
        XCTAssertEqual(IntelligentEditingOptionsPresentation.loadingSkeletonCompactColumns, 20)
        XCTAssertEqual(IntelligentEditingOptionsPresentation.loadingSkeletonExpandedColumns, 24)
        XCTAssertEqual(IntelligentEditingOptionsPresentation.loadingAnswerSurfaceMinimumHeight, 188)
    }

    func testLongSuggestionsPromoteToExpandedReviewSurface() {
        let longSuggestion = Array(repeating: "word", count: 600).joined(separator: " ")

        XCTAssertEqual(IntelligentEditingOptionsPresentation.presentation(for: longSuggestion), .expandedReview)
        XCTAssertEqual(IntelligentEditingOptionsPresentation.presentation(for: "Short replacement."), .anchoredPopover)
    }

    func testAnchoredPopoverPlacementStaysInsideViewport() {
        let placement = IntelligentEditingOverlayPlacement.placement(
            anchorRect: CGRect(x: 10, y: 40, width: 80, height: 24),
            containerSize: CGSize(width: 640, height: 480),
            replacementText: "Short replacement."
        )

        XCTAssertEqual(placement.width, 560)
        XCTAssertNil(placement.bodyHeight)
        XCTAssertGreaterThanOrEqual(placement.position.x - placement.width / 2, 24)
    }

    func testLongReviewPlacementUsesExpandedScrollableBody() {
        let longSuggestion = Array(repeating: "word", count: 600).joined(separator: " ")
        let placement = IntelligentEditingOverlayPlacement.placement(
            anchorRect: CGRect(x: 360, y: 120, width: 240, height: 40),
            containerSize: CGSize(width: 1_000, height: 760),
            replacementText: longSuggestion
        )

        XCTAssertEqual(placement.width, 900)
        XCTAssertEqual(placement.bodyHeight, 380)
    }
}
