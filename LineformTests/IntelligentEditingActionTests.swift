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
        XCTAssertTrue(IntelligentEditingAction.menuBarActions.isEmpty)
    }

    func testRightClickActionsStayMinimal() {
        XCTAssertTrue(IntelligentEditingAction.rightClickActions.isEmpty)
    }

    func testAiComposerReplacesFixedShortcutRail() {
        XCTAssertTrue(IntelligentEditingAction.actionRailActions.isEmpty)
        XCTAssertFalse(IntelligenceInstructionComposerPresentation.usesFixedShortcutButtons)
        XCTAssertEqual(IntelligenceInstructionComposerPresentation.prompt, "Tell AI what to do...")
        XCTAssertEqual(IntelligenceInstructionComposerPresentation.submitSystemImage, "arrow.up")
    }

    func testAiComposerKeepsStableInputAndExplicitInteractiveStates() {
        XCTAssertTrue(IntelligenceInstructionComposerPresentation.animatesSelectionVisibilityChanges)
        XCTAssertTrue(IntelligenceInstructionComposerPresentation.usesStableNativePlaceholder)
        XCTAssertFalse(IntelligenceInstructionComposerPresentation.darkensWhenFocused)
        XCTAssertTrue(IntelligenceInstructionComposerPresentation.showsBorderWhenFocused)
        XCTAssertTrue(IntelligenceInstructionComposerPresentation.showsFocusedBorderBeforeTyping)
        XCTAssertTrue(IntelligenceInstructionComposerPresentation.sendButtonSupportsHoverState)
        XCTAssertGreaterThan(IntelligenceInstructionComposerPresentation.sendButtonHoverBackgroundOpacity, 0.18)
        XCTAssertEqual(IntelligenceInstructionComposerPresentation.sendButtonSize, 30)
        XCTAssertLessThanOrEqual(IntelligenceInstructionComposerPresentation.sendButtonSymbolPointSize, 16)
        XCTAssertTrue(IntelligenceInstructionComposerPresentation.sendButtonUsesFilledAccentBackground)
        XCTAssertTrue(IntelligenceInstructionComposerPresentation.sendButtonUsesWhiteSymbol)
        XCTAssertFalse(IntelligenceInstructionComposerPresentation.usesWhiteCapsuleBackground)
        XCTAssertTrue(IntelligenceInstructionComposerPresentation.usesLightBlueCapsuleBackground)
        XCTAssertTrue(IntelligenceInstructionComposerPresentation.usesNavPillLikeShadow)
    }

    func testAiComposerOwnsLoadingStateBeforeResultReview() {
        XCTAssertTrue(IntelligenceInstructionComposerPresentation.usesInlineLoadingState)
        XCTAssertTrue(IntelligenceInstructionComposerPresentation.usesExistingSkeletonShimmerForLoading)
        XCTAssertTrue(IntelligenceInstructionComposerPresentation.pausesLoadingShimmerForReducedMotion)
        XCTAssertTrue(IntelligenceInstructionComposerPresentation.usesNeutralLoadingChrome)
        XCTAssertFalse(IntelligenceInstructionComposerPresentation.showsLoadingSpinnerInSubmitSlot)
        XCTAssertTrue(IntelligenceInstructionComposerPresentation.loadingStatePreservesCapsuleDimensions)

        XCTAssertFalse(
            IntelligentEditingOptionsPresentation.isVisible(
                isPreparingSuggestion: true,
                hasSuggestions: false
            )
        )
        XCTAssertTrue(
            IntelligentEditingOptionsPresentation.isVisible(
                isPreparingSuggestion: false,
                hasSuggestions: true
            )
        )
    }

    func testAiComposerLoadingShimmerFitsInsideInputSlot() {
        XCTAssertLessThanOrEqual(
            IntelligenceInstructionComposerPresentation.loadingSkeletonGridHeight,
            IntelligenceInstructionComposerPresentation.loadingSkeletonTextSlotHeight
        )
    }

    func testAiComposerLoadingShimmerUsesDenseShortMarks() {
        XCTAssertGreaterThanOrEqual(IntelligenceInstructionComposerPresentation.loadingSkeletonMinimumRows, 4)
        XCTAssertGreaterThanOrEqual(IntelligenceInstructionComposerPresentation.loadingSkeletonColumns, 44)
        XCTAssertLessThanOrEqual(IntelligenceInstructionComposerPresentation.loadingSkeletonBlockHeight, 4)
        XCTAssertLessThanOrEqual(
            IntelligenceInstructionComposerPresentation.loadingSkeletonSpacing,
            2
        )
    }

    @MainActor
    func testAiComposerLoadingShimmerStopsAnimatingWhenReduceMotionIsEnabled() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 52), styleMask: [], backing: .buffered, defer: false)
        let skeletonView = IntelligenceInstructionLoadingSkeletonNSView()
        window.contentView?.addSubview(skeletonView)

        skeletonView.setAnimating(true, reduceMotion: false)
        XCTAssertTrue(skeletonView.isAnimatingForAccessibilityTesting)

        skeletonView.setAnimating(true, reduceMotion: true)
        XCTAssertFalse(skeletonView.isAnimatingForAccessibilityTesting)
    }

    func testAiComposerUsesInvertedDarkAppearanceColors() throws {
        let background = try XCTUnwrap(
            IntelligenceInstructionComposerPresentation.backgroundColor(usesDarkAppearance: true)
                .usingColorSpace(.sRGB)
        )
        let border = try XCTUnwrap(
            IntelligenceInstructionComposerPresentation.borderColor(
                usesDarkAppearance: true,
                isFocused: true
            )
            .usingColorSpace(.sRGB)
        )
        let foreground = try XCTUnwrap(
            IntelligenceInstructionComposerPresentation.foregroundColor(usesDarkAppearance: true)
                .usingColorSpace(.sRGB)
        )
        let buttonFill = try XCTUnwrap(
            IntelligenceInstructionComposerPresentation.sendButtonFillColor(
                usesDarkAppearance: true,
                isHovered: false,
                isEnabled: true
            )
            .usingColorSpace(.sRGB)
        )
        let buttonSymbol = try XCTUnwrap(
            IntelligenceInstructionComposerPresentation.sendButtonSymbolColor(
                usesDarkAppearance: true,
                isEnabled: true
            )
            .usingColorSpace(.sRGB)
        )

        XCTAssertEqual(background.redComponent, 0x23 / 255.0, accuracy: 0.005)
        XCTAssertEqual(background.greenComponent, 0x23 / 255.0, accuracy: 0.005)
        XCTAssertEqual(background.blueComponent, 0x23 / 255.0, accuracy: 0.005)
        XCTAssertGreaterThan(border.redComponent, 0.9)
        XCTAssertGreaterThan(foreground.redComponent, 0.9)
        XCTAssertGreaterThan(buttonFill.redComponent, 0.9)
        XCTAssertLessThan(buttonSymbol.redComponent, 0.1)
    }

    func testAiComposerKeepsLightAppearanceBlueAccentTreatment() throws {
        let background = try XCTUnwrap(
            IntelligenceInstructionComposerPresentation.backgroundColor(usesDarkAppearance: false)
                .usingColorSpace(.sRGB)
        )
        let buttonFill = try XCTUnwrap(
            IntelligenceInstructionComposerPresentation.sendButtonFillColor(
                usesDarkAppearance: false,
                isHovered: false,
                isEnabled: true
            )
            .usingColorSpace(.sRGB)
        )

        XCTAssertGreaterThan(background.redComponent, 0.85)
        XCTAssertGreaterThan(background.greenComponent, 0.9)
        XCTAssertEqual(background.blueComponent, 1.0, accuracy: 0.005)
        XCTAssertLessThan(buttonFill.redComponent, 0.2)
        XCTAssertGreaterThan(buttonFill.blueComponent, 0.7)
    }

    func testAiComposerPlaceholderMeetsAAContrastInLightAndDarkThemes() throws {
        let lightBackground = try XCTUnwrap(
            IntelligenceInstructionComposerPresentation.backgroundColor(usesDarkAppearance: false)
                .usingColorSpace(.sRGB)
        )
        let darkBackground = try XCTUnwrap(
            IntelligenceInstructionComposerPresentation.backgroundColor(usesDarkAppearance: true)
                .usingColorSpace(.sRGB)
        )
        let lightPlaceholder = try XCTUnwrap(
            IntelligenceInstructionComposerPresentation.placeholderColor(usesDarkAppearance: false)
                .usingColorSpace(.sRGB)
        )
        let darkPlaceholder = try XCTUnwrap(
            IntelligenceInstructionComposerPresentation.placeholderColor(usesDarkAppearance: true)
                .usingColorSpace(.sRGB)
        )

        XCTAssertGreaterThanOrEqual(Self.contrastRatio(lightPlaceholder, lightBackground), 4.5)
        XCTAssertGreaterThanOrEqual(Self.contrastRatio(darkPlaceholder, darkBackground), 4.5)
    }

    func testAiComposerUsesRetainedSelectionWhileInputIsFocused() {
        let document = "One selected sentence. Another sentence."
        let selected = SelectionContext(
            text: document,
            selectedRange: NSRange(location: 0, length: 22)
        )
        let collapsed = SelectionContext(
            text: document,
            selectedRange: NSRange(location: 0, length: 0)
        )

        XCTAssertEqual(
            IntelligenceInstructionComposerState.activeSelection(current: collapsed, retained: selected),
            selected
        )
        XCTAssertFalse(
            IntelligenceInstructionComposerState.shouldClearRetainedSelection(
                current: collapsed,
                isFocused: true,
                instruction: "Rewrite this more directly."
            )
        )
        XCTAssertFalse(
            IntelligenceInstructionComposerState.shouldClearRetainedSelection(
                current: collapsed,
                isFocused: false,
                instruction: "Rewrite this more directly."
            )
        )
        XCTAssertTrue(
            IntelligenceInstructionComposerState.shouldClearRetainedSelection(
                current: collapsed,
                isFocused: false,
                instruction: ""
            )
        )
    }

    func testAiComposerPrefersCurrentSelectionOverRetainedSelection() {
        let document = "First selected sentence. Second selected sentence."
        let retained = SelectionContext(
            text: document,
            selectedRange: NSRange(location: 0, length: 24)
        )
        let current = SelectionContext(
            text: document,
            selectedRange: NSRange(location: 25, length: 25)
        )

        XCTAssertEqual(
            IntelligenceInstructionComposerState.activeSelection(current: current, retained: retained),
            current
        )
        XCTAssertFalse(
            IntelligenceInstructionComposerState.shouldClearRetainedSelection(
                current: current,
                isFocused: false,
                instruction: ""
            )
        )
    }

    func testAiComposerStaysVisibleWhileInstructionIsPreparing() {
        let collapsed = SelectionContext(
            text: "Selected text was already sent to AI.",
            selectedRange: NSRange(location: 0, length: 0)
        )

        XCTAssertTrue(
            IntelligenceInstructionComposerState.hasVisibleSelection(
                current: collapsed,
                retained: nil,
                isPreparingSuggestion: true
            )
        )
        XCTAssertFalse(
            IntelligenceInstructionComposerState.hasVisibleSelection(
                current: collapsed,
                retained: nil,
                isPreparingSuggestion: false
            )
        )
    }

    func testStaleOrCanceledIntelligentEditingRequestsCannotPublishResults() {
        let activeRequestID = UUID()

        XCTAssertTrue(
            IntelligentEditingRequestLifecycle.canPublishResult(
                activeRequestID: activeRequestID,
                completingRequestID: activeRequestID,
                isCancelled: false
            )
        )
        XCTAssertFalse(
            IntelligentEditingRequestLifecycle.canPublishResult(
                activeRequestID: nil,
                completingRequestID: activeRequestID,
                isCancelled: false
            )
        )
        XCTAssertFalse(
            IntelligentEditingRequestLifecycle.canPublishResult(
                activeRequestID: UUID(),
                completingRequestID: activeRequestID,
                isCancelled: false
            )
        )
        XCTAssertFalse(
            IntelligentEditingRequestLifecycle.canPublishResult(
                activeRequestID: activeRequestID,
                completingRequestID: activeRequestID,
                isCancelled: true
            )
        )
    }

    func testCustomInstructionsCanRequestMultipleSuggestionsForCreativeEdits() {
        XCTAssertEqual(
            IntelligentEditingPresentationPolicy.optionCount(
                for: .custom("Give me three friendlier alternatives."),
                selectedText: "The deadline cannot move because launch coordination depends on it."
            ),
            3
        )
        XCTAssertEqual(
            IntelligentEditingPresentationPolicy.optionCount(
                for: .custom("Fix grammar only."),
                selectedText: "The editor keep drafts local."
            ),
            1
        )
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

    func testIntelligenceSkeletonMetricsRemainStableForLoadingSurfaces() {
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

    private static func contrastRatio(_ foreground: NSColor, _ background: NSColor) -> CGFloat {
        let foregroundLuminance = relativeLuminance(foreground)
        let backgroundLuminance = relativeLuminance(background)
        return (max(foregroundLuminance, backgroundLuminance) + 0.05)
            / (min(foregroundLuminance, backgroundLuminance) + 0.05)
    }

    private static func relativeLuminance(_ color: NSColor) -> CGFloat {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        return 0.2126 * linearized(rgb.redComponent)
            + 0.7152 * linearized(rgb.greenComponent)
            + 0.0722 * linearized(rgb.blueComponent)
    }

    private static func linearized(_ component: CGFloat) -> CGFloat {
        component <= 0.03928
            ? component / 12.92
            : pow((component + 0.055) / 1.055, 2.4)
    }
}
