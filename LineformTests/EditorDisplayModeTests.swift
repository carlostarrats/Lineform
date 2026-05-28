import AppKit
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
        XCTAssertEqual(MarkdownBasicsModal.title, "Markdown Basics")
        XCTAssertEqual(
            MarkdownBasicsModal.examples.map(\.syntax),
            ["# Title", "## Section", "**bold**", "_italic_", "- bullet", "`code`", "[link](https://example.com)"]
        )
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
        XCTAssertTrue(IntelligenceActionRailPresentation.isVisible(isEnabled: true, displayMode: .write))
        XCTAssertFalse(IntelligenceActionRailPresentation.isVisible(isEnabled: true, displayMode: .read))
        XCTAssertFalse(IntelligenceActionRailPresentation.isVisible(isEnabled: true, displayMode: .split))
        XCTAssertFalse(IntelligenceActionRailPresentation.isVisible(isEnabled: false, displayMode: .write))
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

    func testReadingInspectorUsesSlideAndFadeAnimation() {
        XCTAssertEqual(EditorAuxiliaryPresentation.readingExperience.presenter, .systemInspector)
        XCTAssertEqual(EditorAuxiliaryPresentation.readingExperience.transitionStyle, .slideAndFade)
        XCTAssertNil(EditorAuxiliaryPresentation.readingExperience.animationDuration)
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

    func testReduceMotionDisablesCustomEditorMotion() {
        XCTAssertTrue(EditorMotionPolicy.supportsReduceMotion)
        XCTAssertEqual(EditorMotionPolicy.effectiveDuration(0.24, reduceMotion: false), 0.24, accuracy: 0.01)
        XCTAssertEqual(EditorMotionPolicy.effectiveDuration(0.24, reduceMotion: true), 0, accuracy: 0.01)
        XCTAssertTrue(EditorMotionPolicy.usesAnimatedTransitions(reduceMotion: false))
        XCTAssertFalse(EditorMotionPolicy.usesAnimatedTransitions(reduceMotion: true))
        XCTAssertTrue(EditorModeSegmentedControl.usesReduceMotionForLiquidBridge)
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
