import AppKit
import SwiftUI
import XCTest
@testable import Lineform

final class EditorDisplayModeTests: XCTestCase {
    func testEditorSearchFindsCaseInsensitiveMatchesInDocumentOrder() {
        let matches = EditorSearchResolver.matches(
            in: "Find this, then find this again.",
            query: "find"
        )

        XCTAssertEqual(matches, [
            NSRange(location: 0, length: 4),
            NSRange(location: 16, length: 4)
        ])
    }

    func testEditorSearchNavigationWrapsBetweenMatches() {
        let matches = [
            NSRange(location: 4, length: 5),
            NSRange(location: 18, length: 5),
            NSRange(location: 30, length: 5)
        ]

        XCTAssertEqual(EditorSearchResolver.nextIndex(after: nil, matchCount: matches.count), 0)
        XCTAssertEqual(EditorSearchResolver.nextIndex(after: 2, matchCount: matches.count), 0)
        XCTAssertEqual(EditorSearchResolver.previousIndex(before: nil, matchCount: matches.count), 2)
        XCTAssertEqual(EditorSearchResolver.previousIndex(before: 0, matchCount: matches.count), 2)
    }

    func testEditorSearchRefreshDoesNotNavigateDuringPassiveDocumentEdits() {
        let matches = EditorSearchResolver.matches(in: "alpha beta alpha", query: "alpha")

        let result = EditorSearchResolver.refreshState(
            currentActiveIndex: 0,
            matches: matches,
            selectFirstWhenNeeded: false,
            navigatesToActiveMatch: false
        )

        XCTAssertEqual(result.activeIndex, 0)
        XCTAssertNil(result.requestedSelection)
    }

    func testEditorSearchRefreshNavigatesWhenRequestedByQueryOrArrow() {
        let matches = EditorSearchResolver.matches(in: "alpha beta alpha", query: "alpha")

        let result = EditorSearchResolver.refreshState(
            currentActiveIndex: nil,
            matches: matches,
            selectFirstWhenNeeded: true,
            navigatesToActiveMatch: true
        )

        XCTAssertEqual(result.activeIndex, 0)
        XCTAssertEqual(result.requestedSelection, matches[0])
    }

    func testEditorSearchVisibleMatchesIncludesOnlyVisibleAndActiveRanges() {
        let ranges = [
            NSRange(location: 0, length: 3),
            NSRange(location: 50, length: 3),
            NSRange(location: 120, length: 3)
        ]

        let visible = EditorSearchResolver.visibleMatches(
            ranges,
            activeRange: ranges[0],
            visibleCharacterRange: NSRange(location: 45, length: 20)
        )

        XCTAssertEqual(visible, [ranges[0], ranges[1]])
    }

    func testEditorSearchIgnoresEmptyAndWhitespaceQueries() {
        XCTAssertTrue(EditorSearchResolver.matches(in: "Anything", query: "").isEmpty)
        XCTAssertTrue(EditorSearchResolver.matches(in: "Anything", query: "   ").isEmpty)
        XCTAssertNil(EditorSearchResolver.nextIndex(after: nil, matchCount: 0))
        XCTAssertNil(EditorSearchResolver.previousIndex(before: nil, matchCount: 0))
    }

    func testEditorSearchAccessibilitySummarizesMatchPosition() {
        XCTAssertEqual(
            EditorSearchResolver.accessibilitySummary(query: "line", matchCount: 3, activeIndex: 1),
            "Search for line. 3 matches. Result 2 of 3."
        )
        XCTAssertEqual(
            EditorSearchResolver.accessibilitySummary(query: "line", matchCount: 0, activeIndex: nil),
            "Search for line. No matches."
        )
        XCTAssertNil(EditorSearchResolver.accessibilitySummary(query: "   ", matchCount: 0, activeIndex: nil))
    }

    func testEditorSearchToolbarUsesSeparateNativeFieldPresentation() {
        XCTAssertTrue(EditorSearchToolbarPresentation.usesNativeSearchableToolbarItem)
        XCTAssertTrue(EditorSearchToolbarPresentation.preservesSystemToolbarButtonGroup)
        XCTAssertTrue(EditorSearchToolbarPresentation.usesSeparateVisualCapsule)
        XCTAssertFalse(EditorSearchToolbarPresentation.embedsNavigationControlsInSearchField)
        XCTAssertTrue(EditorSearchToolbarPresentation.usesNativeSearchClearButton)
        XCTAssertFalse(EditorSearchToolbarPresentation.showsNavigationControlsWhenQueryIsEmpty)
        XCTAssertTrue(EditorSearchToolbarPresentation.usesSystemSearchFieldSizing)
    }

    func testDisplayModesStaySmallAndOrdered() {
        XCTAssertEqual(EditorDisplayMode.allCases, [.write, .read, .split])
        XCTAssertEqual(EditorDisplayMode.allCases.map(\.title), ["Write", "Read", "Preview"])
    }

    @MainActor
    func testReadModeHidesStatusBarForCleanReading() {
        XCTAssertTrue(EditorStatusBar.isVisible(in: .write))
        XCTAssertFalse(EditorStatusBar.isVisible(in: .read))
        XCTAssertTrue(EditorStatusBar.isVisible(in: .split))
    }

    func testMarkdownBasicsHelpShowsOnlyInWritingModes() {
        XCTAssertTrue(EditorToolbarVisibility.showsMarkdownBasics(in: .write))
        XCTAssertFalse(EditorToolbarVisibility.showsMarkdownBasics(in: .read))
        XCTAssertTrue(EditorToolbarVisibility.showsMarkdownBasics(in: .split))
    }

    @MainActor
    func testMarkdownBasicsExamplesCoverCommonFormatting() {
        XCTAssertEqual(MarkdownBasicsModal.title, "Info")
        XCTAssertEqual(
            MarkdownBasicsModal.examples.map(\.syntax),
            ["# Title", "## Section", "**bold**", "_italic_", "- bullet", "`code`", "[link](https://example.com)"]
        )
        XCTAssertEqual(MarkdownBasicsModal.sections.map(\.title), ["Markdown Basics", "AI Editing"])
        XCTAssertTrue(MarkdownBasicsModal.usesRowSeparators)
        XCTAssertFalse(MarkdownBasicsModal.usesMonospacedExampleFont)
        XCTAssertTrue(MarkdownBasicsModal.supportsEscapeDismissal)
        XCTAssertEqual(MarkdownBasicsModal.contentWidth, 560)
        XCTAssertFalse(MarkdownBasicsModal.sections.flatMap(\.rows).contains { row in
            row.detail.localizedCaseInsensitiveContains("git")
                || row.detail.localizedCaseInsensitiveContains("privacy")
                || row.detail.localizedCaseInsensitiveContains("file")
        })
    }

    @MainActor
    func testMarkdownGuideTextMeetsAAContrast() {
        let background = NSColor(
            calibratedRed: MarkdownBasicsModal.backgroundWhiteComponent,
            green: MarkdownBasicsModal.backgroundWhiteComponent,
            blue: MarkdownBasicsModal.backgroundWhiteComponent,
            alpha: 1
        )
        let primary = NSColor(
            calibratedRed: MarkdownBasicsModal.textRedComponent,
            green: MarkdownBasicsModal.textRedComponent,
            blue: MarkdownBasicsModal.textRedComponent,
            alpha: 1
        )
        let secondaryComponent = MarkdownBasicsModal.textRedComponent * MarkdownBasicsModal.secondaryTextOpacity
            + MarkdownBasicsModal.backgroundWhiteComponent * (1 - MarkdownBasicsModal.secondaryTextOpacity)
        let secondary = NSColor(
            calibratedRed: secondaryComponent,
            green: secondaryComponent,
            blue: secondaryComponent,
            alpha: 1
        )

        XCTAssertGreaterThanOrEqual(Self.contrastRatio(primary, background), 4.5)
        XCTAssertGreaterThanOrEqual(Self.contrastRatio(secondary, background), 4.5)
    }

    func testToolbarButtonsUseSeparateNativePresentationModels() {
        XCTAssertEqual(EditorToolbarAction.primaryActions(in: .write), [.intelligence, .markdownBasics, .readingExperience])
        XCTAssertEqual(EditorToolbarAction.primaryActions(in: .read), [.readingExperience])
        XCTAssertEqual(EditorToolbarAction.primaryActions(in: .split), [.markdownBasics, .readingExperience])
        XCTAssertEqual(EditorAuxiliaryPresentation.readingExperience.kind, .nativeInspector)
        XCTAssertEqual(EditorAuxiliaryPresentation.markdownBasics.kind, .centeredModal)
        XCTAssertEqual(EditorAuxiliaryPresentation.readingExperience.accessibilityLabel, "Reading Experience Inspector")
        XCTAssertEqual(EditorAuxiliaryPresentation.markdownBasics.accessibilityLabel, "Markdown Basics")
        XCTAssertEqual(EditorAuxiliaryPresentation.readingExperience.idealWidth, 320)
        XCTAssertNil(EditorAuxiliaryPresentation.markdownBasics.idealWidth)
    }

    func testIntelligenceRailIsVisuallyScopedToWriteModeButPreservesToggleState() {
        XCTAssertTrue(IntelligenceActionRailPresentation.isVisible(isEnabled: true, hasSelection: true, displayMode: .write))
        XCTAssertFalse(IntelligenceActionRailPresentation.isVisible(isEnabled: true, hasSelection: false, displayMode: .write))
        XCTAssertFalse(IntelligenceActionRailPresentation.isVisible(isEnabled: true, hasSelection: true, displayMode: .read))
        XCTAssertFalse(IntelligenceActionRailPresentation.isVisible(isEnabled: true, hasSelection: true, displayMode: .split))
        XCTAssertFalse(IntelligenceActionRailPresentation.isVisible(isEnabled: false, hasSelection: true, displayMode: .write))
    }

    func testIntelligenceRailUsesBottomCenteredBlueLabeledDock() {
        XCTAssertEqual(IntelligenceActionRailPresentation.placement, .bottomCenter)
        XCTAssertEqual(IntelligenceActionRailPresentation.bottomInset, 30)
        XCTAssertEqual(IntelligenceActionRailPresentation.transitionStyle, .fadeAndMoveUp)
        XCTAssertEqual(IntelligenceActionRailPresentation.animationDuration, 0.24, accuracy: 0.01)
        XCTAssertEqual(IntelligenceActionRailPresentation.entranceYOffset, 10)
        XCTAssertTrue(IntelligenceActionRailPresentation.usesHorizontalLayout)
        XCTAssertTrue(IntelligenceActionRailPresentation.showsActionLabels)
        XCTAssertEqual(IntelligenceActionRailPresentation.buttonWidth, 88)
        XCTAssertEqual(IntelligenceActionRailPresentation.buttonHeight, 52)
        XCTAssertEqual(IntelligenceActionRailPresentation.backgroundAlpha, 1.0, accuracy: 0.01)
        XCTAssertTrue(IntelligenceActionRailPresentation.supportsHoverState)
        XCTAssertFalse(IntelligenceActionRailPresentation.hoverFeedbackRequiresEnabledAction)
        XCTAssertLessThanOrEqual(IntelligenceActionRailPresentation.hoverBackgroundRedComponent, 0.80)
        XCTAssertLessThan(
            IntelligenceActionRailPresentation.hoverBackgroundRedComponent,
            IntelligenceActionRailPresentation.backgroundRedComponent
        )
        XCTAssertEqual(IntelligenceActionRailPresentation.borderOpacity, 0.55, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(IntelligenceActionRailPresentation.hoverBorderOpacity, 0.95)
        XCTAssertGreaterThan(
            IntelligenceActionRailPresentation.hoverBorderOpacity,
            IntelligenceActionRailPresentation.borderOpacity
        )
        XCTAssertEqual(IntelligenceActionRailPresentation.shadowRadius, 5)
        XCTAssertEqual(IntelligenceActionRailPresentation.shadowYOffset, 1)
        XCTAssertTrue(IntelligenceActionRailPresentation.usesAccentTint)
    }

    func testIntelligenceRailButtonsTemporarilyOwnCursorOnHover() {
        XCTAssertTrue(IntelligenceActionRailPresentation.usesRestoringHoverCursor)
        XCTAssertTrue(IntelligenceActionRailPresentation.usesAppKitCursorRect)
        XCTAssertTrue(IntelligenceActionRailPresentation.usesAppKitHoverTracking)
        XCTAssertTrue(IntelligenceActionRailPresentation.reassertsHoverCursorOnEnter)
        XCTAssertEqual(IntelligenceActionRailPresentation.hoverCursor, .pointingHand)
        XCTAssertTrue(IntelligenceActionRailPresentation.restoresPreviousCursorOnExit)
        XCTAssertTrue(IntelligenceActionRailPresentation.restoresPreviousCursorOnDisappear)
    }

    func testIntelligenceToolbarToggleUsesFilledNativePressedState() {
        XCTAssertTrue(IntelligenceToolbarTogglePresentation.usesNativeToolbarButtonShell)
        XCTAssertNil(IntelligenceToolbarTogglePresentation.outerButtonWidth)
        XCTAssertEqual(IntelligenceToolbarTogglePresentation.iconFillDiameter, 20)
        XCTAssertEqual(IntelligenceToolbarTogglePresentation.fillOpacityWhenOn, 1.0, accuracy: 0.01)
        XCTAssertTrue(IntelligenceToolbarTogglePresentation.usesWhiteIconWhenOn)
        XCTAssertGreaterThan(
            IntelligenceToolbarTogglePresentation.iconOpacityWhenOn,
            IntelligenceToolbarTogglePresentation.iconOpacityWhenOff
        )
    }

    func testToolbarPressedStateCoversInfoAndInspectorButtons() {
        XCTAssertEqual(
            EditorToolbarPressedState.activeActions(
                isIntelligenceRailEnabled: true,
                isShowingMarkdownBasics: false,
                isShowingReadingInspector: false
            ),
            [.intelligence]
        )
        XCTAssertEqual(
            EditorToolbarPressedState.activeActions(
                isIntelligenceRailEnabled: false,
                isShowingMarkdownBasics: true,
                isShowingReadingInspector: true
            ),
            [.markdownBasics, .readingExperience]
        )
        XCTAssertTrue(EditorToolbarPressedState.usesFilledActiveIcon)
        XCTAssertTrue(EditorToolbarPressedState.usesWhiteActiveIcon)
    }

    func testToolbarActiveButtonsReplaceSymbolsWithCloseAction() {
        XCTAssertTrue(EditorToolbarPressedState.replacesActiveSymbolWithCloseAction)
        XCTAssertEqual(EditorToolbarPressedState.closeSystemImage, "xmark")
        XCTAssertEqual(EditorToolbarPressedState.closeSymbolScale, 0.67, accuracy: 0.01)
        XCTAssertEqual(EditorToolbarPressedState.openSymbolTransition, .replaceOffUp)
        XCTAssertEqual(EditorToolbarPressedState.closeSymbolTransition, .instant)

        for action in EditorToolbarAction.allCases {
            XCTAssertEqual(EditorToolbarPressedState.displaySystemImage(for: action, isActive: false), action.systemImage)
            XCTAssertEqual(EditorToolbarPressedState.displaySystemImage(for: action, isActive: true), "xmark")
            XCTAssertEqual(EditorToolbarPressedState.displaySymbolScale(for: action, isActive: false), 1.0, accuracy: 0.01)
            XCTAssertEqual(EditorToolbarPressedState.displaySymbolScale(for: action, isActive: true), 0.67, accuracy: 0.01)
        }
    }

    @MainActor
    func testMarkdownBasicsModalHasExplicitAndOutsideDismissal() {
        XCTAssertTrue(MarkdownBasicsModal.showsCloseButton)
        XCTAssertTrue(MarkdownBasicsModal.dismissesWhenClickingOutside)
    }

    @MainActor
    func testMarkdownBasicsModalKeepsBackdropAnimationAndCloseHoverPolish() {
        XCTAssertGreaterThanOrEqual(MarkdownBasicsOverlay.scrimOpacity, 0.28)
        XCTAssertEqual(MarkdownBasicsOverlay.scrimTransitionStyle, .instant)
        XCTAssertEqual(MarkdownBasicsModal.transitionStyle, .fadeAndMoveUp)
        XCTAssertEqual(MarkdownBasicsModal.entranceYOffset, 10)
        XCTAssertTrue(MarkdownBasicsModal.usesThemeIndependentLightChrome)
        XCTAssertGreaterThan(MarkdownBasicsModal.backgroundWhiteComponent, 0.9)
        XCTAssertLessThan(MarkdownBasicsModal.textRedComponent, 0.2)
        XCTAssertGreaterThan(MarkdownBasicsModal.closeHoverFillOpacity, MarkdownBasicsModal.closeRestingFillOpacity)
        XCTAssertEqual(MarkdownBasicsModal.animationDuration, 0.24, accuracy: 0.01)
    }

    func testReadingInspectorUsesNativeInspectorChrome() {
        XCTAssertEqual(EditorAuxiliaryPresentation.readingExperience.presenter, .systemInspector)
        XCTAssertEqual(EditorAuxiliaryPresentation.readingExperience.transitionStyle, .systemInspector)
        XCTAssertNil(EditorAuxiliaryPresentation.readingExperience.animationDuration)
    }

    func testReadingInspectorUsesSingleLayoutAnimationWithoutTextParallax() {
        XCTAssertFalse(EditorInspectorTextResponse.smoothsHorizontalInsetChanges)
        XCTAssertFalse(EditorInspectorTextResponse.usesPresentationLayerHorizontalSmoothing)
        XCTAssertFalse(EditorInspectorTextResponse.preservesVerticalAnchorDuringPresentationSmoothing)
        XCTAssertFalse(EditorInspectorTextResponse.usesExplicitPresentationOffsetAnimation)
        XCTAssertFalse(EditorInspectorTextResponse.allowsImplicitContentAnimationDuringPresentationSmoothing)
        XCTAssertEqual(EditorInspectorTextResponse.transitionDuration, 0.18, accuracy: 0.01)
        XCTAssertLessThanOrEqual(
            EditorInspectorTextResponse.horizontalInsetAnimationDuration,
            EditorInspectorTextResponse.transitionDuration
        )
        XCTAssertEqual(
            EditorInspectorTextResponse.presentationOffsetAnimationDuration,
            EditorInspectorTextResponse.transitionDuration,
            accuracy: 0.01
        )
        XCTAssertEqual(EditorInspectorTextResponse.presentationOffsetDistance, 0)
        XCTAssertEqual(
            EditorInspectorTextResponse.presentationOffset(opening: true, reduceMotion: false),
            0
        )
        XCTAssertEqual(
            EditorInspectorTextResponse.presentationOffset(opening: false, reduceMotion: false),
            0
        )
        XCTAssertEqual(
            EditorInspectorTextResponse.presentationOffset(opening: true, reduceMotion: true),
            0
        )
    }

    @MainActor
    func testEditorVisibleTextDoesNotJumpVerticallyWhenOutlineDrawerOpens() throws {
        let harness = try makeEditorDrawerHarness()
        let textView = try XCTUnwrap(harness.hostingView.descendants(ofType: LineformTextView.self).first)
        let trackedRange = try XCTUnwrap(textView.visibleCharacterRangeForLayoutPreservation())
        let scrollView = try XCTUnwrap(textView.enclosingScrollView)
        let trackedYBefore = try trackedCharacterY(
            NSRange(location: trackedRange.location, length: 1),
            in: textView,
            relativeTo: harness.window
        )
        let scrollFrameBefore = scrollView.convert(scrollView.bounds, to: nil)
        let textFrameBefore = textView.convert(textView.bounds, to: nil)
        let scrollOriginBefore = scrollView.contentView.bounds.origin

        LineformAppNotification.toggleOutline.post(
            object: LineformAppNotification.Payload(windowNumber: harness.window.windowNumber)
        )
        let maximumAnimatedDelta = try maximumTrackedYDelta(
            NSRange(location: trackedRange.location, length: 1),
            in: textView,
            baselineY: trackedYBefore,
            duration: 0.45
        )

        let trackedYAfter = try trackedCharacterY(
            NSRange(location: trackedRange.location, length: 1),
            in: textView,
            relativeTo: harness.window
        )
        let scrollFrameAfter = scrollView.convert(scrollView.bounds, to: nil)
        let textFrameAfter = textView.convert(textView.bounds, to: nil)
        let scrollOriginAfter = scrollView.contentView.bounds.origin
        XCTAssertEqual(
            trackedYAfter,
            trackedYBefore,
            accuracy: 1.0,
            """
            scrollFrame: \(scrollFrameBefore) -> \(scrollFrameAfter)
            textFrame: \(textFrameBefore) -> \(textFrameAfter)
            scrollOrigin: \(scrollOriginBefore) -> \(scrollOriginAfter)
            """
        )
        XCTAssertLessThanOrEqual(maximumAnimatedDelta, 1.0)
    }

    @MainActor
    func testEditorVisibleTextDoesNotJumpVerticallyWhenReadingInspectorOpens() throws {
        let harness = try makeEditorDrawerHarness()
        let textView = try XCTUnwrap(harness.hostingView.descendants(ofType: LineformTextView.self).first)
        let trackedRange = try XCTUnwrap(textView.visibleCharacterRangeForLayoutPreservation())
        let scrollView = try XCTUnwrap(textView.enclosingScrollView)
        let trackedYBefore = try trackedCharacterY(
            NSRange(location: trackedRange.location, length: 1),
            in: textView,
            relativeTo: harness.window
        )
        let scrollFrameBefore = scrollView.convert(scrollView.bounds, to: nil)
        let textFrameBefore = textView.convert(textView.bounds, to: nil)
        let scrollOriginBefore = scrollView.contentView.bounds.origin

        LineformAppNotification.showReadingExperience.post(
            object: LineformAppNotification.Payload(windowNumber: harness.window.windowNumber)
        )
        let maximumAnimatedDelta = try maximumTrackedYDelta(
            NSRange(location: trackedRange.location, length: 1),
            in: textView,
            baselineY: trackedYBefore,
            duration: 0.45
        )

        let trackedYAfter = try trackedCharacterY(
            NSRange(location: trackedRange.location, length: 1),
            in: textView,
            relativeTo: harness.window
        )
        let scrollFrameAfter = scrollView.convert(scrollView.bounds, to: nil)
        let textFrameAfter = textView.convert(textView.bounds, to: nil)
        let scrollOriginAfter = scrollView.contentView.bounds.origin
        XCTAssertEqual(
            trackedYAfter,
            trackedYBefore,
            accuracy: 1.0,
            """
            scrollFrame: \(scrollFrameBefore) -> \(scrollFrameAfter)
            textFrame: \(textFrameBefore) -> \(textFrameAfter)
            scrollOrigin: \(scrollOriginBefore) -> \(scrollOriginAfter)
            """
        )
        XCTAssertLessThanOrEqual(maximumAnimatedDelta, 1.0)
    }

    @MainActor
    func testScrolledEditorVisibleTextDoesNotJumpVerticallyWhenOutlineDrawerOpens() throws {
        try assertScrolledEditorVisibleTextDoesNotJumpVerticallyWhenDrawerOpens(.outline)
    }

    @MainActor
    func testScrolledEditorVisibleTextDoesNotJumpVerticallyWhenReadingInspectorOpens() throws {
        try assertScrolledEditorVisibleTextDoesNotJumpVerticallyWhenDrawerOpens(.readingInspector)
    }

    @MainActor
    func testReflowingEditorDoesNotScrollUpWhenOutlineDrawerOpens() throws {
        try assertScrolledEditorDoesNotScrollUpWhenDrawerOpens(.outline, text: Self.reflowingDrawerTestDocument)
    }

    @MainActor
    func testReflowingEditorDoesNotScrollUpWhenReadingInspectorOpens() throws {
        try assertScrolledEditorDoesNotScrollUpWhenDrawerOpens(.readingInspector, text: Self.reflowingDrawerTestDocument)
    }

    @MainActor
    func testReadingInspectorOpeningDoesNotSnapTextColumnToFinalPosition() throws {
        let samples = try horizontalTextColumnMotionSamples(whenOpening: .readingInspector)
        let totalDistance = Self.horizontalMotionTotalDistance(samples)
        let distinctIntermediatePositions = Self.distinctIntermediateMotionPositions(samples)

        XCTAssertGreaterThan(totalDistance, 40, "The fixture must exercise visible horizontal text movement.")
        XCTAssertGreaterThanOrEqual(
            distinctIntermediatePositions,
            2,
            "Reading inspector text motion did not expose enough intermediate positions: \(samples)"
        )
    }

    func testLightReaderThemesForceLightWindowChromeAfterDarkThemes() {
        XCTAssertEqual(EditorWindowChrome.appearanceName(usesDarkChrome: false), .aqua)
        XCTAssertEqual(EditorWindowChrome.appearanceName(usesDarkChrome: true), .darkAqua)
        XCTAssertNotNil(EditorWindowChrome.appearance(usesDarkChrome: false))
        XCTAssertNotNil(EditorWindowChrome.appearance(usesDarkChrome: true))
    }

    @MainActor
    func testEditorMinimumWidthAllowsOutlineAndInspectorWithoutForcingWideWindow() {
        XCTAssertLessThanOrEqual(EditorLayout.minimumContentWidth, 360)

        let combinedMinimumWidth = EditorLayout.minimumContentWidth
            + OutlineSidebarView.minimumColumnWidth
            + (EditorAuxiliaryPresentation.readingExperience.minimumWidth ?? 0)

        XCTAssertLessThanOrEqual(combinedMinimumWidth, 860)
    }

    func testReadModeUsesSameTextColumnWidthAsWriteMode() {
        var profile = ReadingProfile.original
        profile.columnWidth = 680
        profile.marginWidth = 48

        XCTAssertEqual(EditorReadingLayout.textColumnMaxWidth(for: profile), 680)
    }

    func testReadAndWriteModesUseSameHorizontalInsetForSameWidth() {
        var profile = ReadingProfile.original
        profile.columnWidth = 820
        profile.marginWidth = 40

        XCTAssertEqual(EditorReadingLayout.horizontalInset(forContainerWidth: 1_200, profile: profile), 190)
        XCTAssertEqual(EditorReadingLayout.horizontalInset(forContainerWidth: 700, profile: profile), 40)
    }

    func testStatusBarFormatsCountsWithEmDash() {
        XCTAssertEqual(
            EditorStatusFormatter.statisticsText(wordCount: 304, characterCount: 2345),
            "304 words — 2345 characters"
        )

        XCTAssertEqual(
            EditorStatusFormatter.statusText(
                wordCount: 304,
                characterCount: 2345,
                isPreparingSuggestion: true,
                intelligentEditingStatus: nil
            ),
            "304 words — 2345 characters"
        )
    }

    func testStatusBarKeepsOnlyFailureMessagesAwayFromCounts() {
        let hiddenRoutineMessages = [
            "Preparing suggestion",
            "Select text to use Intelligence.",
            "1 option ready.",
            "3 options ready.",
            "Suggestion expired after edits.",
            "Suggestion accepted.",
            "Suggestion canceled.",
            "Suggestion rejected."
        ]

        for message in hiddenRoutineMessages {
            XCTAssertNil(
                EditorStatusFormatter.statusMessage(
                    isPreparingSuggestion: message == "Preparing suggestion",
                    intelligentEditingStatus: message == "Preparing suggestion" ? nil : message
                ),
                message
            )
        }

        XCTAssertEqual(
            EditorStatusFormatter.statisticsText(wordCount: 263, characterCount: 1874),
            "263 words — 1874 characters"
        )
    }

    func testStatusBarSanitizesTechnicalIntelligenceFailureMessages() {
        let message = EditorStatusFormatter.statusMessage(
            isPreparingSuggestion: false,
            intelligentEditingStatus: "Apple Intelligence returned an unusable replacement (unchangedTransformOutput; fallback rejected: none available): Lineform"
        )

        XCTAssertEqual(message, "Suggestion unavailable.")
        XCTAssertFalse(message?.contains("unchangedTransformOutput") ?? true)
        XCTAssertFalse(message?.contains("fallback rejected") ?? true)
    }

    func testStatusBarTruncatesLongMessagesWithEllipsis() {
        let message = EditorStatusFormatter.statusMessage(
            isPreparingSuggestion: false,
            intelligentEditingStatus: "Apple Intelligence is unavailable. \(String(repeating: "Long message ", count: 20))"
        )

        XCTAssertEqual(message?.last, "…")
        XCTAssertLessThanOrEqual(message?.count ?? 0, EditorStatusFormatter.maximumStatusMessageLength)
    }

    func testStatusBarWarningAmberMeetsAAContrast() throws {
        let lightAmber = try XCTUnwrap(EditorStatusBar.warningAmberColor(usesDarkChrome: false).usingColorSpace(.sRGB))
        let darkAmber = try XCTUnwrap(EditorStatusBar.warningAmberColor(usesDarkChrome: true).usingColorSpace(.sRGB))
        let lightBackground = try XCTUnwrap(LineformColors.originalBackground.usingColorSpace(.sRGB))
        let darkBackground = try XCTUnwrap(LineformColors.darkControlBackground.usingColorSpace(.sRGB))

        XCTAssertGreaterThanOrEqual(Self.contrastRatio(lightAmber, lightBackground), 4.5)
        XCTAssertGreaterThanOrEqual(Self.contrastRatio(darkAmber, darkBackground), 4.5)
    }

    func testStatusIndicatorShowsAvailableWhenIntelligenceIsReady() {
        XCTAssertEqual(
            EditorStatusFormatter.statusIndicator(
                isPreparingSuggestion: false,
                intelligentEditingStatus: nil,
                intelligenceAvailability: .available
            ),
            EditorStatusIndicator(text: "AI available", tone: .available)
        )
        XCTAssertEqual(
            EditorStatusIndicator(text: "AI available", tone: .available).accessibilityText,
            "Status: AI available"
        )
    }

    func testStatusIndicatorShowsWarningBeforeAvailableHealth() {
        XCTAssertEqual(
            EditorStatusFormatter.statusIndicator(
                isPreparingSuggestion: false,
                intelligentEditingStatus: "Suggestion took too long.",
                intelligenceAvailability: .available
            ),
            EditorStatusIndicator(text: "Suggestion took too long.", tone: .warning)
        )
        XCTAssertEqual(
            EditorStatusIndicator(text: "Suggestion took too long.", tone: .warning).accessibilityText,
            "Warning: Suggestion took too long."
        )
    }

    func testStatusIndicatorCollapsesAppleAvailabilityToNotEnabled() {
        XCTAssertEqual(
            EditorStatusFormatter.statusIndicator(
                isPreparingSuggestion: false,
                intelligentEditingStatus: "Apple Intelligence is turned off in System Settings.",
                intelligenceAvailability: .unavailable("Apple Intelligence is turned off in System Settings.")
            ),
            EditorStatusIndicator(text: "AI not enabled", tone: .warning)
        )
    }

    func testStatusMetadataCombinesLastSaveAndCountsOnRight() {
        XCTAssertEqual(
            EditorStatusFormatter.metadataText(
                lastSavedDisplay: EditorStatusFormatter.LastSavedDisplay(label: "Last save", detail: "3:54 PM"),
                statisticsText: "363 words — 1948 characters"
            ),
            "Last save: 3:54 PM  |  363 words — 1948 characters"
        )
    }

    func testStatusBarFormatsLastSavedTimeAndDate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))

        let now = try XCTUnwrap(DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 5,
            day: 26,
            hour: 10,
            minute: 30
        ).date)
        let today = try XCTUnwrap(DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 5,
            day: 26,
            hour: 9,
            minute: 5
        ).date)
        let earlierDate = try XCTUnwrap(DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 5,
            day: 25,
            hour: 14,
            minute: 6
        ).date)

        XCTAssertEqual(EditorStatusFormatter.lastSavedText(for: nil, now: now, calendar: calendar), "Not saved yet")
        XCTAssertEqual(EditorStatusFormatter.lastSavedText(for: today, now: now, calendar: calendar), "Last save 9:05 AM")
        XCTAssertEqual(EditorStatusFormatter.lastSavedText(for: earlierDate, now: now, calendar: calendar), "Last save May 25, 2026 at 2:06 PM")

        XCTAssertEqual(
            EditorStatusFormatter.lastSavedDisplay(for: today, now: now, calendar: calendar),
            EditorStatusFormatter.LastSavedDisplay(label: "Last save", detail: "9:05 AM")
        )
        XCTAssertEqual(
            EditorStatusFormatter.lastSavedDisplay(for: earlierDate, now: now, calendar: calendar),
            EditorStatusFormatter.LastSavedDisplay(label: "Last save", detail: "May 25, 2026 at 2:06 PM")
        )
    }

    @MainActor
    func testStatusBarDoesNotDrawTopSeparator() {
        XCTAssertFalse(EditorStatusBar.showsTopSeparator)
        XCTAssertFalse(EditorStatusBar.lastSavedDetailUsesPrimaryForeground)
        XCTAssertEqual(EditorStatusBar.horizontalInset, 28)
        XCTAssertEqual(EditorStatusBar.statusMessageMaximumWidth, 520)
        XCTAssertEqual(EditorStatusBar.statusDotDiameter, 7)
    }

    @MainActor
    func testModeSegmentUsesFixedNeutralSelectionMetrics() throws {
        XCTAssertEqual(EditorModeSegmentedControl.segmentWidth, 78)
        XCTAssertEqual(EditorModeSegmentedControl.segmentHeight, 30)
        XCTAssertEqual(EditorModeSegmentedControl.selectedFillRedComponent, 0.86, accuracy: 0.01)
        XCTAssertEqual(EditorModeSegmentedControl.backgroundFillRedComponent, 1.0, accuracy: 0.01)
        XCTAssertEqual(EditorModeSegmentedControl.textFillRedComponent, 0.18, accuracy: 0.01)
        let expectedDarkControl = try XCTUnwrap(LineformColors.darkControlBackground.usingColorSpace(.sRGB))
        XCTAssertEqual(EditorModeSegmentedControl.darkBackgroundFillRedComponent, expectedDarkControl.redComponent, accuracy: 0.005)
        XCTAssertLessThan(EditorModeSegmentedControl.darkSelectedFillRedComponent, 0.25)
        XCTAssertGreaterThan(EditorModeSegmentedControl.darkTextFillRedComponent, 0.85)
        XCTAssertEqual(EditorModeSegmentedControl.shadowRadius, 5)
        XCTAssertEqual(EditorModeSegmentedControl.hitAreaWidth, EditorModeSegmentedControl.segmentWidth)
        XCTAssertEqual(EditorModeSegmentedControl.hitAreaHeight, EditorModeSegmentedControl.segmentHeight)
    }

    @MainActor
    func testModeSegmentLiquidBridgeSpansBetweenStates() {
        let writeOffset = EditorModeSegmentedControl.segmentOffset(for: .write)
        let readOffset = EditorModeSegmentedControl.segmentOffset(for: .read)
        let splitOffset = EditorModeSegmentedControl.segmentOffset(for: .split)

        XCTAssertEqual(EditorModeSegmentedControl.liquidPillOffset(from: .write, to: .split), writeOffset)
        XCTAssertEqual(
            EditorModeSegmentedControl.liquidPillWidth(from: .write, to: .split),
            splitOffset - writeOffset + EditorModeSegmentedControl.segmentWidth
        )

        XCTAssertEqual(EditorModeSegmentedControl.liquidPillOffset(from: .split, to: .read), readOffset)
        XCTAssertEqual(
            EditorModeSegmentedControl.liquidPillWidth(from: .split, to: .read),
            splitOffset - readOffset + EditorModeSegmentedControl.segmentWidth
        )
    }

    @MainActor
    func testReduceMotionDisablesCustomEditorMotion() {
        XCTAssertTrue(EditorMotionPolicy.supportsReduceMotion)
        XCTAssertEqual(EditorMotionPolicy.effectiveDuration(0.24, reduceMotion: false), 0.24, accuracy: 0.01)
        XCTAssertEqual(EditorMotionPolicy.effectiveDuration(0.24, reduceMotion: true), 0, accuracy: 0.01)
        XCTAssertTrue(EditorMotionPolicy.usesAnimatedTransitions(reduceMotion: false))
        XCTAssertFalse(EditorMotionPolicy.usesAnimatedTransitions(reduceMotion: true))
        XCTAssertTrue(EditorModeSegmentedControl.usesReduceMotionForLiquidBridge)
    }

    @MainActor
    private func assertScrolledEditorVisibleTextDoesNotJumpVerticallyWhenDrawerOpens(_ drawer: EditorDrawerKind) throws {
        let harness = try makeEditorDrawerHarness(text: Self.longDrawerTestDocument)
        let textView = try XCTUnwrap(harness.hostingView.descendants(ofType: LineformTextView.self).first)
        let scrollView = try XCTUnwrap(textView.enclosingScrollView)
        let startingOrigin = NSPoint(x: 0, y: 520)
        scrollView.contentView.setBoundsOrigin(startingOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        runMainLoop(for: 0.1)

        let trackedRange = try XCTUnwrap(textView.visibleCharacterRangeForLayoutPreservation())
        let trackedCharacter = NSRange(location: trackedRange.location, length: 1)
        let trackedYBefore = try trackedCharacterY(trackedCharacter, in: textView, relativeTo: harness.window)
        let scrollOriginBefore = scrollView.contentView.bounds.origin

        switch drawer {
        case .outline:
            LineformAppNotification.toggleOutline.post(
                object: LineformAppNotification.Payload(windowNumber: harness.window.windowNumber)
            )
        case .readingInspector:
            LineformAppNotification.showReadingExperience.post(
                object: LineformAppNotification.Payload(windowNumber: harness.window.windowNumber)
            )
        }

        let maximumAnimatedTrackedYDelta = try maximumTrackedYDelta(
            trackedCharacter,
            in: textView,
            baselineY: trackedYBefore,
            duration: 0.45
        )
        let trackedYAfter = try trackedCharacterY(trackedCharacter, in: textView, relativeTo: harness.window)
        let scrollOriginAfter = scrollView.contentView.bounds.origin

        XCTAssertEqual(
            trackedYAfter,
            trackedYBefore,
            accuracy: 1.0,
            "scrollOrigin: \(scrollOriginBefore) -> \(scrollOriginAfter)"
        )
        XCTAssertLessThanOrEqual(maximumAnimatedTrackedYDelta, 1.0)
    }

    @MainActor
    private func assertScrolledEditorDoesNotScrollUpWhenDrawerOpens(_ drawer: EditorDrawerKind, text: String) throws {
        let harness = try makeEditorDrawerHarness(text: text)
        let textView = try XCTUnwrap(harness.hostingView.descendants(ofType: LineformTextView.self).first)
        let scrollView = try XCTUnwrap(textView.enclosingScrollView)
        let startingOrigin = NSPoint(x: 0, y: 520)
        scrollView.contentView.setBoundsOrigin(startingOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        runMainLoop(for: 0.1)
        let scrollOriginBefore = scrollView.contentView.bounds.origin.y

        switch drawer {
        case .outline:
            LineformAppNotification.toggleOutline.post(
                object: LineformAppNotification.Payload(windowNumber: harness.window.windowNumber)
            )
        case .readingInspector:
            LineformAppNotification.showReadingExperience.post(
                object: LineformAppNotification.Payload(windowNumber: harness.window.windowNumber)
            )
        }

        let maximumScrollOriginDelta = maximumScrollOriginYDelta(
            in: scrollView,
            baselineY: scrollOriginBefore,
            duration: 0.45
        )
        let scrollOriginAfter = scrollView.contentView.bounds.origin.y

        XCTAssertEqual(scrollOriginAfter, scrollOriginBefore, accuracy: 1.0)
        XCTAssertLessThanOrEqual(maximumScrollOriginDelta, 1.0)
    }

    @MainActor
    private func horizontalTextColumnMotionSamples(
        whenOpening drawer: EditorDrawerKind,
        duration: TimeInterval = 0.45,
        interval: TimeInterval = 0.015
    ) throws -> [CGFloat] {
        let harness = try makeEditorDrawerHarness()
        let textView = try XCTUnwrap(harness.hostingView.descendants(ofType: LineformTextView.self).first)
        var samples = [try textColumnMinX(in: textView)]

        switch drawer {
        case .outline:
            LineformAppNotification.toggleOutline.post(
                object: LineformAppNotification.Payload(windowNumber: harness.window.windowNumber)
            )
        case .readingInspector:
            LineformAppNotification.showReadingExperience.post(
                object: LineformAppNotification.Payload(windowNumber: harness.window.windowNumber)
            )
        }

        let deadline = Date(timeIntervalSinceNow: duration)
        while Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: interval))
            samples.append(try textColumnMinX(in: textView))
        }

        return samples
    }

    @MainActor
    private func makeEditorDrawerHarness(text: String? = nil) throws -> EditorDrawerHarness {
        var document = LineformDocument(
            text: text ?? Self.shortDrawerTestDocument
        )
        let editor = EditorContainerView(
            document: Binding(
                get: { document },
                set: { document = $0 }
            )
        )
        let hostingView = NSHostingView(rootView: editor)
        hostingView.frame = NSRect(x: 0, y: 0, width: 1_080, height: 720)

        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        runMainLoop(for: 0.3)
        _ = try XCTUnwrap(hostingView.descendants(ofType: LineformTextView.self).first)
        return EditorDrawerHarness(window: window, hostingView: hostingView)
    }

    private static let shortDrawerTestDocument = """
            # Features

            Native macOS document with AppKit and TextKit.

            Real Markdown files that remain portable.

            Write, Read, and Preview modes for drafting.

            Markdown outline navigation from document headings.

            Reading controls for type size, line height, paragraph spacing, margins, column width, themes, focus, and ruler.

            Apple Books-style reader themes, with accessibility adjustments layered on top.

            Native Writing Tools and Apple Intelligence selected-text editing.

            ## Requirements

            - Xcode with macOS SDK support
            - Swift 6
            - Plain UTF-8 Markdown and text file handling
            """

    private static let longDrawerTestDocument = (0..<72)
        .map { index in
            """
            ## Section \(index + 1)

            This is a stable paragraph for testing drawer layout in a longer writing session. It has enough words to wrap at ordinary editor widths without being so long that one line dominates the viewport.

            The editor should slide sideways when a drawer opens. The visible text should not jump upward while the outline or reading controls appear.
            """
        }
        .joined(separator: "\n\n")

    private static let reflowingDrawerTestDocument = (0..<48)
        .map { index in
            """
            ## Reflow Section \(index + 1)

            This deliberately long editor line sits above or inside the viewport and will rewrap when a side drawer narrows the writing canvas, which is the case that can make the visible text appear to jump upward during drawer presentation.
            """
        }
        .joined(separator: "\n\n")

    @MainActor
    private func trackedCharacterY(
        _ characterRange: NSRange,
        in textView: LineformTextView,
        relativeTo window: NSWindow
    ) throws -> CGFloat {
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let textContainer = try XCTUnwrap(textView.textContainer)
        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: characterRange,
            actualCharacterRange: nil
        )
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        rect.origin.x += textView.textContainerOrigin.x
        rect.origin.y += textView.textContainerOrigin.y
        return textView.convert(rect, to: nil).midY
    }

    @MainActor
    private func textColumnMinX(in textView: LineformTextView) throws -> CGFloat {
        _ = try XCTUnwrap(textView.window)
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let textContainer = try XCTUnwrap(textView.textContainer)
        layoutManager.ensureLayout(for: textContainer)

        let rect = NSRect(
            x: textView.textContainerOrigin.x,
            y: textView.textContainerOrigin.y,
            width: 1,
            height: 1
        )
        return textView.convert(rect, to: nil).minX
    }

    private static func horizontalMotionTotalDistance(_ samples: [CGFloat]) -> CGFloat {
        guard let first = samples.first, let last = samples.last else {
            return 0
        }

        return abs(last - first)
    }

    private static func distinctIntermediateMotionPositions(_ samples: [CGFloat]) -> Int {
        guard
            let first = samples.first,
            let last = samples.last,
            abs(first - last) > 1
        else {
            return 0
        }

        let lowerBound = min(first, last) + 1
        let upperBound = max(first, last) - 1
        return Set(
            samples
                .dropFirst()
                .dropLast()
                .filter { $0 > lowerBound && $0 < upperBound }
                .map { Int($0.rounded()) }
        ).count
    }

    @MainActor
    private func maximumTrackedYDelta(
        _ characterRange: NSRange,
        in textView: LineformTextView,
        baselineY: CGFloat,
        duration: TimeInterval,
        interval: TimeInterval = 0.03
    ) throws -> CGFloat {
        let window = try XCTUnwrap(textView.window)
        var maximumDelta: CGFloat = 0
        let deadline = Date(timeIntervalSinceNow: duration)

        while Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: interval))
            let currentY = try trackedCharacterY(characterRange, in: textView, relativeTo: window)
            maximumDelta = max(maximumDelta, abs(currentY - baselineY))
        }

        return maximumDelta
    }

    @MainActor
    private func maximumScrollOriginYDelta(
        in scrollView: NSScrollView,
        baselineY: CGFloat,
        duration: TimeInterval,
        interval: TimeInterval = 0.03
    ) -> CGFloat {
        var maximumDelta: CGFloat = 0
        let deadline = Date(timeIntervalSinceNow: duration)

        while Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: interval))
            maximumDelta = max(maximumDelta, abs(scrollView.contentView.bounds.origin.y - baselineY))
        }

        return maximumDelta
    }

    @MainActor
    private func maximumTrackedYAndScrollOriginDelta(
        _ characterRange: NSRange,
        in textView: LineformTextView,
        scrollView: NSScrollView,
        baselineY: CGFloat,
        baselineScrollOriginY: CGFloat,
        duration: TimeInterval,
        interval: TimeInterval = 0.03
    ) throws -> (trackedY: CGFloat, scrollOriginY: CGFloat) {
        let window = try XCTUnwrap(textView.window)
        var maximumTrackedDelta: CGFloat = 0
        var maximumScrollOriginDelta: CGFloat = 0
        let deadline = Date(timeIntervalSinceNow: duration)

        while Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: interval))
            let currentY = try trackedCharacterY(characterRange, in: textView, relativeTo: window)
            maximumTrackedDelta = max(maximumTrackedDelta, abs(currentY - baselineY))
            maximumScrollOriginDelta = max(
                maximumScrollOriginDelta,
                abs(scrollView.contentView.bounds.origin.y - baselineScrollOriginY)
            )
        }

        return (maximumTrackedDelta, maximumScrollOriginDelta)
    }

    private func runMainLoop(for duration: TimeInterval) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: duration))
    }

    private static func contrastRatio(_ foreground: NSColor, _ background: NSColor) -> CGFloat {
        let foregroundLuminance = relativeLuminance(foreground)
        let backgroundLuminance = relativeLuminance(background)
        let lighter = max(foregroundLuminance, backgroundLuminance)
        let darker = min(foregroundLuminance, backgroundLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func relativeLuminance(_ color: NSColor) -> CGFloat {
        func linearized(_ component: CGFloat) -> CGFloat {
            component <= 0.03928
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }

        return 0.2126 * linearized(color.redComponent)
            + 0.7152 * linearized(color.greenComponent)
            + 0.0722 * linearized(color.blueComponent)
    }
}

private struct EditorDrawerHarness {
    let window: NSWindow
    let hostingView: NSHostingView<EditorContainerView>
}

private enum EditorDrawerKind {
    case outline
    case readingInspector
}

private extension NSView {
    func descendants<T: NSView>(ofType type: T.Type) -> [T] {
        var matches = subviews.compactMap { $0 as? T }
        for subview in subviews {
            matches.append(contentsOf: subview.descendants(ofType: type))
        }
        return matches
    }
}
