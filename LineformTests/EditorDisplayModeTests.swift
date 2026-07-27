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

    // MARK: - Find & Replace (Task 8)

    func testReplaceAllSwapsEveryMatchAndCountsThem() {
        let result = EditorSearchResolver.replaceAll(
            in: "cat dog cat bird cat",
            query: "cat",
            replacement: "fox"
        )

        XCTAssertEqual(result?.text, "fox dog fox bird fox")
        XCTAssertEqual(result?.replacedCount, 3)
    }

    func testReplaceAllReplacesExactlyAsManyAsSearchMatches() {
        let text = "Find this, then find this again. FIND."
        let query = "find"
        let matchCount = EditorSearchResolver.matches(in: text, query: query).count
        let result = EditorSearchResolver.replaceAll(in: text, query: query, replacement: "seek")

        XCTAssertEqual(result?.replacedCount, matchCount)
        XCTAssertEqual(result?.text, "seek this, then seek this again. seek.")
    }

    func testReplaceAllIsCaseAndDiacriticInsensitiveLikeSearch() {
        // Matches search's [.caseInsensitive, .diacriticInsensitive] behavior.
        let result = EditorSearchResolver.replaceAll(
            in: "café CAFE cafe",
            query: "cafe",
            replacement: "bar"
        )

        XCTAssertEqual(result?.replacedCount, 3)
        XCTAssertEqual(result?.text, "bar bar bar")
    }

    func testReplaceAllHandlesReplacementLongerAndShorterThanQuery() {
        let longer = EditorSearchResolver.replaceAll(in: "a b a", query: "a", replacement: "xyz")
        XCTAssertEqual(longer?.text, "xyz b xyz")

        let shorter = EditorSearchResolver.replaceAll(in: "aaa b aaa", query: "aaa", replacement: "z")
        XCTAssertEqual(shorter?.text, "z b z")
    }

    func testReplaceAllWithEmptyReplacementDeletesMatches() {
        let result = EditorSearchResolver.replaceAll(in: "a-b-a-b", query: "-", replacement: "")

        XCTAssertEqual(result?.text, "abab")
        XCTAssertEqual(result?.replacedCount, 3)
    }

    func testReplaceAllDoesNotCascadeWhenReplacementContainsQuery() {
        // Replacing "a" with "aa" must not re-scan the freshly written text (no runaway).
        let result = EditorSearchResolver.replaceAll(in: "a a a", query: "a", replacement: "aa")

        XCTAssertEqual(result?.text, "aa aa aa")
        XCTAssertEqual(result?.replacedCount, 3)
    }

    func testReplaceAllReturnsNilWhenNothingMatchesOrQueryEmpty() {
        XCTAssertNil(EditorSearchResolver.replaceAll(in: "hello", query: "zzz", replacement: "x"))
        XCTAssertNil(EditorSearchResolver.replaceAll(in: "hello", query: "", replacement: "x"))
        XCTAssertNil(EditorSearchResolver.replaceAll(in: "hello", query: "   ", replacement: "x"))
    }

    func testReplaceAllCaretLandsAfterLastReplacement() {
        // Back-to-front rewrite; caret ends up as a zero-length insertion point at the
        // end of the top-most replacement so the view has a sensible post-edit selection.
        let result = EditorSearchResolver.replaceAll(in: "cat cat", query: "cat", replacement: "fox")

        XCTAssertEqual(result?.text, "fox fox")
        // First "fox" occupies 0..<3; caret sits at its end.
        XCTAssertEqual(result?.selectedRange, NSRange(location: 3, length: 0))
    }

    func testReplaceMatchReplacesOnlyTheGivenRangeAndSelectsInsertion() {
        let text = "cat dog cat"
        let matches = EditorSearchResolver.matches(in: text, query: "cat")
        let result = EditorSearchResolver.replaceMatch(in: text, matchRange: matches[1], replacement: "fox")

        XCTAssertEqual(result?.text, "cat dog fox")
        XCTAssertEqual(result?.replacedCount, 1)
        XCTAssertEqual(result?.selectedRange, NSRange(location: 8, length: 3))
    }

    func testReplaceMatchReturnsNilForOutOfBoundsRange() {
        XCTAssertNil(
            EditorSearchResolver.replaceMatch(
                in: "short",
                matchRange: NSRange(location: 10, length: 3),
                replacement: "x"
            )
        )
    }

    func testNextActiveIndexAfterReplacementAdvancesPastTheReplacement() {
        // Replaced "cat" at loc 0 with "dog" (len 3) in "cat cat cat" → next is the following match.
        let newMatches = EditorSearchResolver.matches(in: "dog cat cat", query: "cat")
        let next = EditorSearchResolver.nextActiveIndexAfterReplacement(
            matches: newMatches,
            replacedLocation: 0,
            replacementLength: 3
        )
        XCTAssertEqual(next, 0) // first "cat" now at loc 4
    }

    func testNextActiveIndexAfterReplacementSkipsAReplacementContainingTheQuery() {
        // Regression: replacing "cat"→"cats" must NOT re-select the "cat" inside the fresh "cats"
        // (that would make Replace loop on its own output: cat→cats→catss…).
        let newMatches = EditorSearchResolver.matches(in: "cats cat", query: "cat")
        // Two matches: the one inside "cats" at loc 0, and the standalone "cat" at loc 5.
        XCTAssertEqual(newMatches.map(\.location), [0, 5])
        let next = EditorSearchResolver.nextActiveIndexAfterReplacement(
            matches: newMatches,
            replacedLocation: 0,
            replacementLength: 4 // "cats"
        )
        XCTAssertEqual(next, 1) // skips loc 0 (inside the replacement), lands on loc 5
    }

    func testNextActiveIndexAfterReplacementWrapsWhenNoneFollow() {
        // Replaced the LAST "cat" (loc 4) in "cat cat" → wrap back to the first remaining match.
        let newMatches = EditorSearchResolver.matches(in: "cat dog", query: "cat")
        let next = EditorSearchResolver.nextActiveIndexAfterReplacement(
            matches: newMatches,
            replacedLocation: 4,
            replacementLength: 3
        )
        XCTAssertEqual(next, 0)
    }

    func testNextActiveIndexAfterReplacementReturnsNilWhenNoMatchesRemain() {
        XCTAssertNil(
            EditorSearchResolver.nextActiveIndexAfterReplacement(
                matches: [],
                replacedLocation: 0,
                replacementLength: 3
            )
        )
    }

    func testNextActiveIndexAfterReplacementDoesNotWrapOntoASoleSelfContainingReplacement() {
        // Single occurrence "cat" replaced by "cats": the only match left is the "cat" INSIDE the
        // inserted "cats". Wrapping onto it would resume the cascade, so no match is selected.
        let newMatches = EditorSearchResolver.matches(in: "cats", query: "cat")
        XCTAssertEqual(newMatches, [NSRange(location: 0, length: 3)])
        let next = EditorSearchResolver.nextActiveIndexAfterReplacement(
            matches: newMatches,
            replacedLocation: 0,
            replacementLength: 4 // "cats"
        )
        XCTAssertNil(next)
    }

    func testNextActiveIndexAfterReplacementWrapSkipsMatchInsideInsertion() {
        // "cat cat" → replace the SECOND (loc 4) with "cats" → "cat cats". Matches: "cat" at loc 0
        // and the "cat" inside "cats" at loc 4. Wrap must land on loc 0, never the loc-4 self-match.
        let newMatches = EditorSearchResolver.matches(in: "cat cats", query: "cat")
        XCTAssertEqual(newMatches.map(\.location), [0, 4])
        let next = EditorSearchResolver.nextActiveIndexAfterReplacement(
            matches: newMatches,
            replacedLocation: 4,
            replacementLength: 4 // "cats"
        )
        XCTAssertEqual(next, 0)
    }

    func testDisplayModesStaySmallAndOrdered() {
        XCTAssertEqual(EditorDisplayMode.allCases, [.write, .read, .split])
        XCTAssertEqual(EditorDisplayMode.allCases.map(\.title), ["Write", "Read", "Preview"])
    }

    func testToggledWriteReadFlipsWriteToReadAndEverythingElseToWrite() {
        XCTAssertEqual(EditorDisplayMode.write.toggledWriteRead, .read)
        XCTAssertEqual(EditorDisplayMode.read.toggledWriteRead, .write)
        XCTAssertEqual(EditorDisplayMode.split.toggledWriteRead, .write)
    }

    @MainActor
    func testReadModeHidesStatusBarForCleanReading() {
        XCTAssertTrue(EditorStatusBar.isVisible(in: .write))
        XCTAssertFalse(EditorStatusBar.isVisible(in: .read))
        XCTAssertTrue(EditorStatusBar.isVisible(in: .split))
    }

    func testToolbarButtonsUseSeparateNativePresentationModels() {
        // The Markdown reference moved to the Files-sidebar Info tab, so the only
        // primary toolbar toggle left is the Reading Experience inspector — in every mode.
        XCTAssertEqual(EditorToolbarAction.primaryActions(in: .write), [.readingExperience])
        XCTAssertEqual(EditorToolbarAction.primaryActions(in: .read), [.readingExperience])
        XCTAssertEqual(EditorToolbarAction.primaryActions(in: .split), [.readingExperience])
        XCTAssertEqual(EditorAuxiliaryPresentation.readingExperience.kind, .nativeInspector)
        XCTAssertEqual(EditorAuxiliaryPresentation.readingExperience.accessibilityLabel, "Reading Experience Inspector")
        XCTAssertEqual(EditorAuxiliaryPresentation.readingExperience.idealWidth, 320)
    }

    func testEditorToolbarToggleUsesQuietNativeGlyph() {
        XCTAssertTrue(EditorToolbarTogglePresentation.usesNativeToolbarButtonShell)
        XCTAssertNil(EditorToolbarTogglePresentation.outerButtonWidth)
        XCTAssertLessThan(EditorToolbarTogglePresentation.lightChromeIconWhiteComponent, 0.35)
        XCTAssertGreaterThan(EditorToolbarTogglePresentation.darkChromeIconWhiteComponent, 0.75)
        XCTAssertGreaterThan(EditorToolbarTogglePresentation.iconOpacity(usesDarkChrome: false), 0)
        XCTAssertLessThanOrEqual(EditorToolbarTogglePresentation.iconOpacity(usesDarkChrome: false), 1)
        // Dark chrome renders the glyph at full strength so it matches the sidebar's opaque
        // white symbols rather than reading as dimmed grey.
        XCTAssertEqual(EditorToolbarTogglePresentation.iconOpacity(usesDarkChrome: true), 1)
    }

    func testToolbarPressedStateCoversInspectorButton() {
        XCTAssertEqual(
            EditorToolbarPressedState.activeActions(isShowingReadingInspector: false),
            []
        )
        XCTAssertEqual(
            EditorToolbarPressedState.activeActions(isShowingReadingInspector: true),
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
        XCTAssertEqual(EditorToolbarAction.readingExperience.systemImage, "textformat.alt")
    }

    @MainActor
    func testMuseModalScrimMatchesTheDesignFieldValues() {
        // These are the Paper design's exact stops. They are asserted rather than merely
        // bounded because the field's whole character lives in a ~12-value range — a
        // well-meaning "rounding" of any of them flattens it back to a plain gray.
        XCTAssertEqual(MuseModalScrim.fieldGradientTop, Color(red: 1.0, green: 1.0, blue: 1.0))
        XCTAssertEqual(MuseModalScrim.fieldGradientBottom, Color(red: 0.945, green: 0.969, blue: 1.0))
        XCTAssertEqual(MuseModalScrim.diagonalWashTop, Color(red: 0.957, green: 0.957, blue: 0.957))
        XCTAssertEqual(MuseModalScrim.diagonalWashBottom, Color(red: 0.835, green: 0.835, blue: 0.835))
        XCTAssertEqual(MuseModalScrim.diagonalWashOpacity, 0.20)
        // Mostly solid over the blur: a faint ghost of the page, not a see-through veil.
        XCTAssertEqual(MuseModalScrim.fieldOpacity, 0.90)
        // Still appears instantly (no fade lag).
        XCTAssertEqual(MuseModalScrim.scrimTransitionStyle, .instant)
    }

    func testMuseModalScrimFieldFollowsTheReaderThemeHue() {
        XCTAssertEqual(
            MuseModalScrim.fieldGradientColors(for: .paper, usesDarkChrome: false),
            [MuseModalScrim.fieldGradientTopPaper, MuseModalScrim.fieldGradientBottomPaper]
        )
        XCTAssertEqual(
            MuseModalScrim.fieldGradientColors(for: .calm, usesDarkChrome: false),
            [MuseModalScrim.fieldGradientTopCalm, MuseModalScrim.fieldGradientBottomCalm]
        )
        // Original keeps the design's cool default.
        XCTAssertEqual(
            MuseModalScrim.fieldGradientColors(for: .system, usesDarkChrome: false),
            [MuseModalScrim.fieldGradientTop, MuseModalScrim.fieldGradientBottom]
        )
        // A dark theme ignores the hue entirely.
        XCTAssertEqual(
            MuseModalScrim.fieldGradientColors(for: .paper, usesDarkChrome: true),
            [MuseModalScrim.fieldGradientTopDark, MuseModalScrim.fieldGradientBottomDark]
        )
    }

    func testMuseModalScrimThemeTintsMoveHueWithoutMovingLightness() {
        // The point of the tinted fields: same weight, different hue. A stop that drifts in
        // lightness makes the modal look like it dims by a different amount per theme.
        func luminance(_ rgb: (CGFloat, CGFloat, CGFloat)) -> CGFloat {
            (0.2126 * rgb.0) + (0.7152 * rgb.1) + (0.0722 * rgb.2)
        }

        let cool = luminance((0.945, 0.969, 1.0))
        XCTAssertEqual(luminance((0.984, 0.965, 0.929)), cool, accuracy: 0.005)   // paper
        XCTAssertEqual(luminance((0.925, 0.980, 0.949)), cool, accuracy: 0.005)   // calm

        // Paper leans warm (red highest), Calm leans green (green highest, blue behind it).
        XCTAssertEqual(MuseModalScrim.fieldGradientBottomPaper, Color(red: 0.984, green: 0.965, blue: 0.929))
        XCTAssertEqual(MuseModalScrim.fieldGradientBottomCalm, Color(red: 0.925, green: 0.980, blue: 0.949))
        // The tops stay near white — a hint of the hue, not a color.
        XCTAssertEqual(MuseModalScrim.fieldGradientTopPaper, Color(red: 0.996, green: 0.992, blue: 0.980))
        XCTAssertEqual(MuseModalScrim.fieldGradientTopCalm, Color(red: 0.980, green: 0.996, blue: 0.988))
    }

    func testMuseModalScrimTintSurvivesTheFieldComposite() {
        // Only ~58% of the base wash's chroma reaches the screen: the two neutral diagonals
        // composite to 0.64 × base, then the field is laid at 0.90 over the blurred page.
        // Calm's first pass authored green just 3/255 above blue and arrived visually gray.
        // Assert the AUTHORED separation is wide enough to survive that, in 0…1 units.
        let surviving = 0.64 * MuseModalScrim.fieldOpacity

        func components(_ color: Color) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
            let rgb = NSColor(color).usingColorSpace(.sRGB)!
            return (rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
        }

        // Calm: green must lead blue on screen by a margin you can actually see, and red must
        // trail blue — otherwise the mint turns olive.
        let calm = components(MuseModalScrim.fieldGradientBottomCalm)
        let calmGreenOverBlue = (calm.g - calm.b) * surviving
        XCTAssertGreaterThan(calmGreenOverBlue, 0.012)
        XCTAssertLessThan(calm.r, calm.b)

        // Paper: red must lead blue by a comparable margin, so neither theme reads stronger.
        let paper = components(MuseModalScrim.fieldGradientBottomPaper)
        let paperRedOverBlue = (paper.r - paper.b) * surviving
        XCTAssertGreaterThan(paperRedOverBlue, 0.012)
        XCTAssertEqual(paperRedOverBlue, calmGreenOverBlue, accuracy: 0.020)
    }

    func testHighContrastKeepsTheModalFieldNeutral() {
        // High contrast strips theme color from the page, so it must strip it from the field.
        // `Theme.theme(for:)` keeps the user's themeID under high contrast (the theme picker
        // still shows their pick), which is why the field keys off `chromeTintID`, not `id`.
        var profile = ReadingProfile.original
        profile.themeID = .paper
        profile.highContrastEnabled = true

        let theme = Theme.theme(for: profile)
        XCTAssertEqual(theme.id, .paper)
        XCTAssertEqual(theme.chromeTintID, .system)
        XCTAssertEqual(
            MuseModalScrim.fieldGradientColors(for: theme.chromeTintID, usesDarkChrome: false),
            [MuseModalScrim.fieldGradientTop, MuseModalScrim.fieldGradientBottom]
        )

        // Without high contrast the same profile does carry Paper's hue.
        profile.highContrastEnabled = false
        XCTAssertEqual(Theme.theme(for: profile).chromeTintID, .paper)
    }

    func testMuseModalScrimMatchesTheDesignDarkFieldValues() {
        // The dark field's exact stops, same three-layer structure as light.
        XCTAssertEqual(MuseModalScrim.fieldGradientTopDark, Color(red: 0.192, green: 0.188, blue: 0.188))
        XCTAssertEqual(MuseModalScrim.fieldGradientBottomDark, Color(red: 0.071, green: 0.071, blue: 0.071))
        XCTAssertEqual(MuseModalScrim.diagonalWashTopDark, Color(red: 0.173, green: 0.173, blue: 0.173))
        XCTAssertEqual(MuseModalScrim.diagonalWashBottomDark, Color(red: 0.071, green: 0.071, blue: 0.071))
    }

    func testMuseModalDarkCardStaysDarkerThanTheTextOnIt() {
        XCTAssertEqual(MuseModalChrome.cardGradientTopDark, Color(red: 0.192, green: 0.192, blue: 0.192))
        XCTAssertEqual(MuseModalChrome.cardGradientBottomDark, Color(red: 0.125, green: 0.125, blue: 0.125))
        // The dark card is ~0.19 white at its lightest; its text must stay well clear of that.
        XCTAssertGreaterThan(MuseModalChrome.darkPrimaryTextWhiteComponent, 0.80)
        XCTAssertGreaterThan(MuseModalChrome.darkSecondaryTextWhiteComponent, 0.60)
        XCTAssertGreaterThan(
            MuseModalChrome.darkPrimaryTextWhiteComponent,
            MuseModalChrome.darkSecondaryTextWhiteComponent
        )
    }

    func testMuseModalTextColorsFlipWithThreadedChromeNotTheEnvironment() {
        // Light text on the dark card and dark text on the light card must come from the
        // THREADED flag. If these ever compare equal, something started reading the
        // environment instead and dark modals will render unreadable text.
        XCTAssertNotEqual(
            MuseModalChrome.primaryTextColor(usesDarkChrome: true),
            MuseModalChrome.primaryTextColor(usesDarkChrome: false)
        )
        XCTAssertNotEqual(
            MuseModalChrome.secondaryTextColor(usesDarkChrome: true),
            MuseModalChrome.secondaryTextColor(usesDarkChrome: false)
        )
    }

    @MainActor
    func testMuseModalBackdropBlursWithinWindowAndFollowsTheField() {
        // The blur must blend WITHIN the window (blurring editor content, not the desktop)
        // and match the FIELD's appearance — a light blur under the dark field would glow
        // through the 10% the field does not cover.
        let light = MuseModalBackdropBlur.makeBackdropView(usesDarkChrome: false)
        let dark = MuseModalBackdropBlur.makeBackdropView(usesDarkChrome: true)

        for view in [light, dark] {
            XCTAssertEqual(view.blendingMode, .withinWindow)
            XCTAssertEqual(view.state, .active)
            // Clicks belong to the field above it, which owns tap-to-dismiss.
            XCTAssertNil(view.hitTest(NSPoint(x: 1, y: 1)))
        }
        XCTAssertEqual(light.appearance?.name, .aqua)
        XCTAssertEqual(dark.appearance?.name, .darkAqua)
    }

    func testMuseModalCardMatchesTheDesignCardValues() {
        // Vertical wash, white to a barely-there gray, with the design's cool 1pt stroke.
        XCTAssertEqual(MuseModalChrome.cardGradientTop, Color(red: 1.0, green: 1.0, blue: 1.0))
        XCTAssertEqual(MuseModalChrome.cardGradientBottom, Color(red: 0.945, green: 0.945, blue: 0.945))
        XCTAssertEqual(MuseModalChrome.cornerRadius, 20)
        // Both modals must carry ⌘K's outline. If this ever diverges per-modal again, the
        // shared card has been bypassed.
        XCTAssertEqual(MuseModalChrome.cardStrokeColor, Color.black.opacity(0.08))
        XCTAssertEqual(MuseModalChrome.cardStrokeColorDark, Color.white.opacity(0.14))
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
    func testWindowChromeReaderAppliesDarkAppearanceSynchronouslyOnWindowJoin() {
        // Regression: the appearance used to be applied inside a deferred Task (needed only
        // to write the windowNumber binding outside the view-update phase). That let the
        // window paint a frame with the default light appearance, so appearance-derived
        // native controls — the NavigationSplitView sidebar-toggle glyph and
        // NSColor.secondaryLabelColor in the empty-state placeholder — flashed dark-on-dark
        // in the Quiet theme. The backing view must apply the dark appearance SYNCHRONOUSLY
        // the moment it joins the window (no runloop pump), while only the windowNumber
        // write stays deferred.
        let window = NSWindow()
        window.contentView = NSView(frame: .zero)

        var reportedWindow: NSWindow?
        let view = WindowChromeReader.ChromeView()
        view.usesDarkChrome = true
        // The reporter is handed the window (not a pre-read number) so it can read the
        // windowNumber a runloop later, once the window is ordered on-screen.
        view.onWindowChanged = { reportedWindow = $0 }

        // Not yet in a window: nothing applied.
        XCTAssertNil(view.window)

        window.contentView?.addSubview(view)

        // Synchronously dark — no async wait.
        XCTAssertEqual(window.appearance?.bestMatch(from: [.darkAqua, .aqua]), .darkAqua)
        XCTAssertEqual(window.contentView?.appearance?.bestMatch(from: [.darkAqua, .aqua]), .darkAqua)
        XCTAssertIdentical(reportedWindow, window)

        // A later theme change also applies synchronously.
        view.usesDarkChrome = false
        view.applyChrome()
        XCTAssertEqual(window.appearance?.bestMatch(from: [.darkAqua, .aqua]), .aqua)

        // Detaching reports a nil window so the reader clears the stale windowNumber.
        reportedWindow = window
        view.removeFromSuperview()
        XCTAssertNil(reportedWindow)
    }

    @MainActor
    func testWindowChromeReaderHealsWindowAppearanceDrift() {
        // Regression: AppKit can reset the window's explicit appearance to the default
        // (light) aqua when the detail hierarchy rebuilds (tab bar / inspector / theme
        // switch). If that drift went unanswered, appearance-derived native controls —
        // the NavigationSplitView sidebar-toggle glyph, the search field — rendered
        // BLACK on the dark Quiet nav. The reader must re-assert the themed appearance
        // the instant the drift reaches it (viewDidChangeEffectiveAppearance).
        let window = NSWindow()
        window.contentView = NSView(frame: .zero)

        let view = WindowChromeReader.ChromeView()
        view.usesDarkChrome = true
        window.contentView?.addSubview(view)
        XCTAssertEqual(window.appearance?.bestMatch(from: [.darkAqua, .aqua]), .darkAqua)

        // Simulate AppKit's rebuild-time reset. (The direct window-appearance observation
        // already heals this synchronously — see the test below; this case covers the OTHER
        // entry point, a drift that arrives as an effectiveAppearance change, e.g. a system
        // light/dark switch under an unpinned window.)
        window.appearance = NSAppearance(named: .aqua)

        // The drift notification re-asserts the themed appearance synchronously.
        view.viewDidChangeEffectiveAppearance()
        XCTAssertEqual(window.appearance?.bestMatch(from: [.darkAqua, .aqua]), .darkAqua)
        XCTAssertEqual(window.contentView?.appearance?.bestMatch(from: [.darkAqua, .aqua]), .darkAqua)

        // Idempotent: a second notification with no drift must not churn (no loop).
        view.viewDidChangeEffectiveAppearance()
        XCTAssertEqual(window.appearance?.bestMatch(from: [.darkAqua, .aqua]), .darkAqua)
    }

    @MainActor
    func testWindowChromeReaderHealsWindowAppearanceDriftWithoutAnEffectiveAppearanceChange() {
        // Regression (2026-07-25, round 2): the drift self-heal above was reachable ONLY
        // through viewDidChangeEffectiveAppearance, and that callback can never fire for
        // this drift — EditorWindowChrome.apply pins window.contentView.appearance, so the
        // reader (a descendant of contentView) inherits the PINNED appearance and its
        // effectiveAppearance is unchanged when window.appearance alone is reset. The
        // sidebar-toggle glyph is drawn by the titlebar, which follows window.appearance,
        // so it turned black on dark themes and STUCK. The reader must observe the window's
        // appearance directly. No manual callback invocation here — that is the point.
        let window = NSWindow()
        window.contentView = NSView(frame: .zero)

        let view = WindowChromeReader.ChromeView()
        view.usesDarkChrome = true
        window.contentView?.addSubview(view)
        XCTAssertEqual(window.appearance?.bestMatch(from: [.darkAqua, .aqua]), .darkAqua)

        // Simulate AppKit's rebuild-time reset of the WINDOW appearance only.
        window.appearance = NSAppearance(named: .aqua)

        XCTAssertEqual(
            window.appearance?.bestMatch(from: [.darkAqua, .aqua]),
            .darkAqua,
            "window appearance drift must self-heal without an effectiveAppearance change"
        )

        // Clearing it entirely (the other shape of AppKit's reset) also heals.
        window.appearance = nil
        XCTAssertEqual(window.appearance?.bestMatch(from: [.darkAqua, .aqua]), .darkAqua)

        // Detaching stops the observation: the window is free to change without churn.
        view.removeFromSuperview()
        window.appearance = NSAppearance(named: .aqua)
        XCTAssertEqual(window.appearance?.bestMatch(from: [.darkAqua, .aqua]), .aqua)
    }

    @MainActor
    func testWindowChromeReaderDismantleKeepsThemedWindowAppearance() {
        // Regression: dismantling the reader must NOT clear the window appearance.
        // SwiftUI dismantles/recreates the background view during the same hierarchy
        // rebuilds that reset the appearance, with no guaranteed ordering vs. the
        // replacement view's apply — a clear here was what left the Quiet nav stuck
        // light (black sidebar-toggle glyph) when it landed last.
        let window = NSWindow()
        window.contentView = NSView(frame: .zero)

        let view = WindowChromeReader.ChromeView()
        view.usesDarkChrome = true
        window.contentView?.addSubview(view)
        XCTAssertEqual(window.appearance?.bestMatch(from: [.darkAqua, .aqua]), .darkAqua)

        WindowChromeReader.dismantleNSView(view, coordinator: ())
        XCTAssertEqual(window.appearance?.bestMatch(from: [.darkAqua, .aqua]), .darkAqua)
        XCTAssertEqual(window.contentView?.appearance?.bestMatch(from: [.darkAqua, .aqua]), .darkAqua)
    }

    @MainActor
    func testEditorMinimumWidthAllowsOutlineAndInspectorWithoutForcingWideWindow() {
        XCTAssertLessThanOrEqual(EditorLayout.minimumContentWidth, 240)

        let combinedMinimumWidth = EditorLayout.minimumContentWidth
            + OutlineSidebarView.minimumColumnWidth
            + (EditorAuxiliaryPresentation.readingExperience.minimumWidth ?? 0)

        XCTAssertLessThanOrEqual(combinedMinimumWidth, 760)
    }

    func testCompactModeControlSwapsInOnNarrowWindowsOnly() {
        XCTAssertTrue(EditorToolbarCompactPresentation.usesCompactModeControl(windowWidth: 400))
        XCTAssertTrue(
            EditorToolbarCompactPresentation.usesCompactModeControl(
                windowWidth: EditorToolbarCompactPresentation.compactModeControlThreshold - 1
            )
        )
        XCTAssertFalse(
            EditorToolbarCompactPresentation.usesCompactModeControl(
                windowWidth: EditorToolbarCompactPresentation.compactModeControlThreshold
            )
        )
        XCTAssertFalse(EditorToolbarCompactPresentation.usesCompactModeControl(windowWidth: 1_080))
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

    func testFullWidthColumnFillsToMarginsRegardlessOfWindowSize() {
        var profile = ReadingProfile.original
        profile.columnWidth = ReadingProfile.columnWidthMaximum // "Full"
        profile.marginWidth = 40

        XCTAssertTrue(ReadingProfile.isFullWidthColumn(profile.columnWidth))
        // The column is unbounded, so the inset clamps to the margin at any window size.
        XCTAssertEqual(EditorReadingLayout.horizontalInset(forContainerWidth: 900, profile: profile), 40)
        XCTAssertEqual(EditorReadingLayout.horizontalInset(forContainerWidth: 3_000, profile: profile), 40)
        // Text fills the window minus both margins.
        XCTAssertEqual(EditorReadingLayout.textContainerWidth(forContainerWidth: 3_000, profile: profile), 2_920)
    }

    func testFixedColumnWidthStillCentersOnWideWindows() {
        var profile = ReadingProfile.original
        profile.columnWidth = 820 // below the Full threshold
        profile.marginWidth = 40

        XCTAssertFalse(ReadingProfile.isFullWidthColumn(profile.columnWidth))
        // A fixed column centers with growing margins on a wide window (unchanged behavior).
        XCTAssertEqual(EditorReadingLayout.horizontalInset(forContainerWidth: 3_000, profile: profile), 1_090)
    }

    func testColumnWidthValueReadsFullAtTheTop() {
        var full = ReadingProfile.original
        full.columnWidth = ReadingProfile.columnWidthMaximum
        XCTAssertEqual(ReadingExperienceInspector.valueText(for: \.columnWidth, in: full), "Full")

        var fixed = ReadingProfile.original
        fixed.columnWidth = 820
        XCTAssertEqual(ReadingExperienceInspector.valueText(for: \.columnWidth, in: fixed), "820 px")
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

    func testMetadataSegmentsColorOnlyTheUntitledLabel() {
        let untitled = EditorStatusFormatter.metadataSegments(
            lastSavedDisplay: EditorStatusFormatter.LastSavedDisplay(label: "Not saved yet", detail: nil),
            statisticsText: "12 words — 68 characters"
        )
        XCTAssertEqual(untitled.unsavedLabel, "Not saved yet")
        XCTAssertEqual(untitled.neutralText, "  |  12 words — 68 characters")

        let saved = EditorStatusFormatter.metadataSegments(
            lastSavedDisplay: EditorStatusFormatter.LastSavedDisplay(label: "Last save", detail: "3:41 PM"),
            statisticsText: "340 words — 1948 characters"
        )
        XCTAssertNil(saved.unsavedLabel, "Established doc metadata is never colored")
        XCTAssertEqual(saved.neutralText, "Last save: 3:41 PM  |  340 words — 1948 characters")
    }

    func testMetadataTextStillMatchesSegments() {
        // Existing metadataText output must be unchanged (a11y string).
        let display = EditorStatusFormatter.LastSavedDisplay(label: "Not saved yet", detail: nil)
        XCTAssertEqual(
            EditorStatusFormatter.metadataText(lastSavedDisplay: display, statisticsText: "12 words — 68 characters"),
            "Not saved yet  |  12 words — 68 characters"
        )
    }

    func testLeftIndicatorReflectsSaveState() {
        let now = Date()
        // Untitled: never a left indicator (red lives in main text).
        XCTAssertEqual(EditorStatusFormatter.indicator(savedAt: nil, isDirty: false, flash: nil), .none)
        XCTAssertEqual(EditorStatusFormatter.indicator(savedAt: nil, isDirty: true, flash: .saved), .none)
        // Established dirty: amber, and dirty wins over a lingering flash.
        XCTAssertEqual(EditorStatusFormatter.indicator(savedAt: now, isDirty: true, flash: nil), .unsavedChanges)
        XCTAssertEqual(EditorStatusFormatter.indicator(savedAt: now, isDirty: true, flash: .autosaved), .unsavedChanges)
        // Established clean with a flash: show the flash.
        XCTAssertEqual(EditorStatusFormatter.indicator(savedAt: now, isDirty: false, flash: .saved), .saved)
        XCTAssertEqual(EditorStatusFormatter.indicator(savedAt: now, isDirty: false, flash: .autosaved), .autosaved)
        XCTAssertEqual(EditorStatusFormatter.indicator(savedAt: now, isDirty: false, flash: .updated), .updated)
        // Established clean, no flash: nothing.
        XCTAssertEqual(EditorStatusFormatter.indicator(savedAt: now, isDirty: false, flash: nil), .none)
    }

    func testIndicatorPresentationTextAndIcon() {
        XCTAssertEqual(EditorStatusIndicator.unsavedChanges.text, "Unsaved changes")
        XCTAssertEqual(EditorStatusIndicator.saved.text, "Saved")
        XCTAssertEqual(EditorStatusIndicator.autosaved.text, "Autosaved")
        XCTAssertEqual(EditorStatusIndicator.updated.text, "Updated")
        XCTAssertNil(EditorStatusIndicator.none.text)
        XCTAssertTrue(EditorStatusIndicator.updated.showsReloadIcon)
        XCTAssertFalse(EditorStatusIndicator.unsavedChanges.showsReloadIcon)
        XCTAssertFalse(EditorStatusIndicator.saved.showsReloadIcon)
    }

    @MainActor
    func testDocumentDirtyReflectsTextVsLastWrite() {
        let status = DocumentSaveStatus.testInstance()
        let id = UUID()
        // Untitled (never saved): never "dirty" — the untitled state is signaled separately.
        XCTAssertFalse(status.isDirty(documentID: id, currentText: "hello"))
        // After a write, matching text is clean; changed text is dirty.
        status.recordWrite(documentID: id, text: "hello")
        XCTAssertFalse(status.isDirty(documentID: id, currentText: "hello"))
        XCTAssertTrue(status.isDirty(documentID: id, currentText: "hello world"))
    }

    @MainActor
    func testRecordWriteClassifiesManualVsAutosave() {
        let status = DocumentSaveStatus.testInstance()
        let id = UUID()
        // No intent → autosave.
        status.recordWrite(documentID: id, text: "a")
        XCTAssertEqual(status.lastSaveEvent?.kind, .autosave)
        let firstSeq = status.lastSaveEvent?.sequence
        // Manual intent → manual, consumed once.
        status.noteManualSaveIntent()
        status.recordWrite(documentID: id, text: "ab")
        XCTAssertEqual(status.lastSaveEvent?.kind, .manual)
        // A distinct event each time, so .onChange fires even for repeated kinds.
        XCTAssertNotEqual(status.lastSaveEvent?.sequence, firstSeq)
        // Intent is one-shot: the next write is autosave again.
        status.recordWrite(documentID: id, text: "abc")
        XCTAssertEqual(status.lastSaveEvent?.kind, .autosave)
    }

    @MainActor
    func testManualIntentSurvivesUntilWriteButIsClearedByAnEdit() {
        let status = DocumentSaveStatus.testInstance()
        let id = UUID()
        // Intent is not time-gated: it persists across a (potentially slow) save panel
        // until the write lands, so panel saves still classify as manual.
        status.noteManualSaveIntent()
        status.recordWrite(documentID: id, text: "saved via panel")
        XCTAssertEqual(status.lastSaveEvent?.kind, .manual)

        // But an edit before the write means the next write is an autosave of that edit.
        status.noteManualSaveIntent()
        status.noteUserEdit()
        status.recordWrite(documentID: id, text: "edited then autosaved")
        XCTAssertEqual(status.lastSaveEvent?.kind, .autosave)
    }

    func testStatusStateColorsMeetAAAgainstEveryThemeBackground() {
        for theme in Theme.builtIn {
            let dark = theme.usesDarkChrome
            let background = theme.backgroundColor
            for color in [
                EditorStatusColors.notSaved(dark: dark),
                EditorStatusColors.unsavedChanges(dark: dark),
                EditorStatusColors.saved(dark: dark)
            ] {
                XCTAssertGreaterThanOrEqual(
                    Self.contrastRatio(color, background), 4.5,
                    "Status color fails AA on theme \(theme.name) (dark=\(dark))"
                )
            }
        }
    }

    // The document tab titles must stay readable on their own capsule fills in every theme.
    // The light-mode fills are derived from each theme's page color (TabBarView.lightTone), and
    // the active/hovered pairs were pushed as dark as WCAG AA allows — this locks that so a
    // future retune can't silently drop a state below 4.5:1. Mirrors the status-color guard.
    @MainActor
    func testTabColorsMeetAAAgainstTheirFillsInEveryTheme() {
        let states: [(name: String, isSelected: Bool, isHovered: Bool)] = [
            ("inactive rest", false, false),
            ("inactive hover", false, true),
            ("selected rest", true, false),
            ("selected hover", true, true),
        ]
        for theme in Theme.builtIn {
            let dark = theme.usesDarkChrome
            for state in states {
                let fill = TabBarView.tabBackgroundColor(
                    isSelected: state.isSelected,
                    isHovered: state.isHovered,
                    usesDarkChrome: dark,
                    pageBackground: theme.backgroundColor
                )
                let text = TabBarView.textColor(
                    usesDarkChrome: dark,
                    isSelected: state.isSelected,
                    isHovered: state.isHovered
                )
                XCTAssertGreaterThanOrEqual(
                    Self.contrastRatio(text, fill), 4.5,
                    "Tab \(state.name) text fails AA on theme \(theme.name) (dark=\(dark))"
                )
            }
        }
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
        let rgb = color.usingColorSpace(.sRGB) ?? color
        func linearized(_ component: CGFloat) -> CGFloat {
            component <= 0.03928
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }

        return 0.2126 * linearized(rgb.redComponent)
            + 0.7152 * linearized(rgb.greenComponent)
            + 0.0722 * linearized(rgb.blueComponent)
    }
}
