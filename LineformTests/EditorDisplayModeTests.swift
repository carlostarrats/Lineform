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

    func testEditorSearchAdvancesToNextMatchAndWraps() {
        let matches = [
            NSRange(location: 4, length: 5),
            NSRange(location: 18, length: 5),
            NSRange(location: 30, length: 5)
        ]

        XCTAssertEqual(EditorSearchResolver.nextIndex(after: nil, matchCount: matches.count), 0)
        XCTAssertEqual(EditorSearchResolver.nextIndex(after: 0, matchCount: matches.count), 1)
        XCTAssertEqual(EditorSearchResolver.nextIndex(after: 2, matchCount: matches.count), 0)
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
        XCTAssertEqual(MarkdownBasicsModal.sections.map(\.title), ["Markdown Basics", "Diagrams", "Math", "Search"])
        XCTAssertEqual(MarkdownBasicsModal.sections.first?.rows.last?.label, "Block Spacing")
        XCTAssertTrue(MarkdownBasicsModal.sections.first?.rows.last?.detail.localizedCaseInsensitiveContains("Read and Preview") == true)

        // The Diagrams and Math sections document the native rendering features.
        let diagrams = MarkdownBasicsModal.sections.first { $0.title == "Diagrams" }
        XCTAssertTrue(diagrams?.rows.contains { $0.label == "```mermaid" } == true)
        let math = MarkdownBasicsModal.sections.first { $0.title == "Math" }
        XCTAssertTrue(math?.rows.contains { $0.label == "$$…$$" } == true)
        XCTAssertTrue(math?.rows.contains { $0.label.contains("$x^2") } == true)
        // The prose-dollar caveat is spelled out so writers aren't surprised.
        XCTAssertTrue(math?.rows.contains { $0.detail.localizedCaseInsensitiveContains("not treated as math") } == true)
        XCTAssertFalse(MarkdownBasicsModal.sections.flatMap(\.rows).contains { $0.label == "Line Height" })
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
        XCTAssertEqual(EditorToolbarAction.primaryActions(in: .write), [.markdownBasics, .readingExperience])
        XCTAssertEqual(EditorToolbarAction.primaryActions(in: .read), [.readingExperience])
        XCTAssertEqual(EditorToolbarAction.primaryActions(in: .split), [.markdownBasics, .readingExperience])
        XCTAssertEqual(EditorAuxiliaryPresentation.readingExperience.kind, .nativeInspector)
        XCTAssertEqual(EditorAuxiliaryPresentation.markdownBasics.kind, .centeredModal)
        XCTAssertEqual(EditorAuxiliaryPresentation.readingExperience.accessibilityLabel, "Reading Experience Inspector")
        // VoiceOver label must match the modal's visible "Info" title, which now covers Markdown
        // Basics + Diagrams + Math — not just the original Markdown Basics section.
        XCTAssertEqual(EditorAuxiliaryPresentation.markdownBasics.accessibilityLabel, "Info")
        XCTAssertEqual(EditorAuxiliaryPresentation.readingExperience.idealWidth, 320)
        XCTAssertNil(EditorAuxiliaryPresentation.markdownBasics.idealWidth)
    }

    func testEditorToolbarToggleUsesQuietNativeGlyph() {
        XCTAssertTrue(EditorToolbarTogglePresentation.usesNativeToolbarButtonShell)
        XCTAssertNil(EditorToolbarTogglePresentation.outerButtonWidth)
        XCTAssertLessThan(EditorToolbarTogglePresentation.lightChromeIconWhiteComponent, 0.35)
        XCTAssertGreaterThan(EditorToolbarTogglePresentation.darkChromeIconWhiteComponent, 0.75)
        XCTAssertGreaterThan(EditorToolbarTogglePresentation.iconOpacity, 0)
        XCTAssertLessThanOrEqual(EditorToolbarTogglePresentation.iconOpacity, 1)
    }

    func testToolbarPressedStateCoversInfoAndInspectorButtons() {
        XCTAssertEqual(
            EditorToolbarPressedState.activeActions(
                isShowingMarkdownBasics: false,
                isShowingReadingInspector: false
            ),
            []
        )
        XCTAssertEqual(
            EditorToolbarPressedState.activeActions(
                isShowingMarkdownBasics: true,
                isShowingReadingInspector: true
            ),
            [.markdownBasics, .readingExperience]
        )
        XCTAssertEqual(
            EditorToolbarPressedState.activeActions(
                isShowingMarkdownBasics: false,
                isShowingReadingInspector: true
            ),
            [.readingExperience]
        )
    }

    func testToolbarActiveButtonsKeepTheirOwnGlyph() {
        // The buttons no longer morph into a filled ✕ when their panel is open — the
        // reading inspector carries its own close now, so each toolbar button keeps its
        // own quiet glyph regardless of active state.
        for action in EditorToolbarAction.allCases {
            XCTAssertFalse(action.systemImage.isEmpty)
            XCTAssertNotEqual(action.systemImage, "xmark")
        }
        XCTAssertEqual(EditorToolbarAction.markdownBasics.systemImage, "info.circle")
        XCTAssertEqual(EditorToolbarAction.readingExperience.systemImage, "textformat.size")
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
    func testLightReaderThemesForceLightWindowChromeAfterDarkThemes() {
        XCTAssertEqual(EditorWindowChrome.appearanceName(usesDarkChrome: false), .aqua)
        XCTAssertEqual(EditorWindowChrome.appearanceName(usesDarkChrome: true), .darkAqua)
        XCTAssertNotNil(EditorWindowChrome.appearance(usesDarkChrome: false))
        XCTAssertNotNil(EditorWindowChrome.appearance(usesDarkChrome: true))

        let window = NSWindow()
        window.contentView = NSView(frame: .zero)
        EditorWindowChrome.apply(to: window, usesDarkChrome: true)
        XCTAssertEqual(window.appearance?.bestMatch(from: [.darkAqua, .aqua]), .darkAqua)
        XCTAssertEqual(window.contentView?.appearance?.bestMatch(from: [.darkAqua, .aqua]), .darkAqua)

        EditorWindowChrome.apply(to: window, usesDarkChrome: false)
        XCTAssertEqual(window.appearance?.bestMatch(from: [.darkAqua, .aqua]), .aqua)
        XCTAssertEqual(window.contentView?.appearance?.bestMatch(from: [.darkAqua, .aqua]), .aqua)
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
