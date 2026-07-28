import AppKit
import XCTest
@testable import Lineform

final class ThemeTests: XCTestCase {
    func testBuiltInThemesHaveDistinctForegroundAndBackgroundColors() {
        for theme in Theme.builtIn {
            XCTAssertNotEqual(theme.textColor, theme.backgroundColor, theme.name)
        }
    }

    /// Body text is the entire product, and it is the ONE pairing that was only ever asserted to
    /// be "not equal" — code tokens, diagram ink, and the Info tab all had a real ratio gate while
    /// the prose the reader actually looks at did not. A theme is a colour choice made by eye, and
    /// eyes are exactly what this check exists to not rely on.
    ///
    /// WCAG AA for body text is 4.5:1; the themes are deliberately soft (grey-on-charcoal rather
    /// than white-on-black) so this pins the floor, not the aesthetic.
    func testEveryThemeMeetsAAForBodyText() {
        for theme in Theme.builtIn {
            let ratio = Self.contrastRatio(theme.textColor, theme.backgroundColor)
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(theme.name) body text is \(ratio):1")
        }
    }

    /// The caret is a 1–3pt sliver, which makes it the easiest colour in the app to lose against
    /// the page — and losing it means not knowing where typing will land.
    func testEveryThemeCaretStaysVisible() {
        for theme in Theme.builtIn {
            let ratio = Self.contrastRatio(theme.caretColor, theme.backgroundColor)
            XCTAssertGreaterThanOrEqual(ratio, 3.0, "\(theme.name) caret is \(ratio):1")
        }
    }

    /// The accessibility high-contrast profile must be a real improvement on every theme it can be
    /// turned on over, not just a different palette.
    func testHighContrastBeatsEveryThemeItReplaces() {
        for id in ThemeID.allCases {
            var profile = ReadingProfile.original
            profile.themeID = id
            profile.highContrastEnabled = true
            let high = Theme.theme(for: profile)
            let ratio = Self.contrastRatio(high.textColor, high.backgroundColor)
            XCTAssertGreaterThanOrEqual(ratio, 7.0, "high contrast over \(id) is \(ratio):1")
        }
    }

    func testReaderThemesStaySmallAndAppleBooksStyle() {
        XCTAssertEqual(Theme.builtIn.map(\.id), [.system, .paper, .calm, .quiet, .night])
        XCTAssertEqual(Theme.builtIn.map(\.name), ["Original", "Paper", "Calm", "Quiet", "Night"])
    }

    func testReaderThemesUseRequestedBackgroundAndSoftTextColors() throws {
        assertSameRGB(Theme.system.backgroundColor, LineformColors.originalBackground)
        assertSameRGB(Theme.paper.backgroundColor, LineformColors.paperBackground)
        assertSameRGB(Theme.calm.backgroundColor, LineformColors.calmBackground)
        assertSameRGB(Theme.system.textColor, LineformColors.primaryText)
        assertSameRGB(Theme.paper.textColor, LineformColors.primaryText)
        assertSameRGB(Theme.calm.textColor, LineformColors.primaryText)
    }

    func testOriginalThemeStaysLightWhenPreviewedFromDarkChrome() throws {
        let darkAppearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
        var resolvedBackground: NSColor?
        var resolvedText: NSColor?

        darkAppearance.performAsCurrentDrawingAppearance {
            resolvedBackground = Theme.system.backgroundColor.usingColorSpace(.sRGB)
            resolvedText = Theme.system.textColor.usingColorSpace(.sRGB)
        }

        assertSameRGB(try XCTUnwrap(resolvedBackground), LineformColors.originalBackground)
        assertSameRGB(try XCTUnwrap(resolvedText), LineformColors.primaryText)
    }

    func testQuietThemeUsesReadableCharcoalBackgroundNotBlack() {
        let quiet = Theme.quiet.backgroundColor.usingColorSpace(.deviceRGB)

        XCTAssertNotNil(quiet)
        XCTAssertGreaterThan(quiet?.redComponent ?? 0, 0.12)
        XCTAssertLessThan(quiet?.redComponent ?? 1, 0.30)
    }

    func testDarkThemesRequestDarkWindowChrome() {
        XCTAssertFalse(Theme.theme(for: .system).usesDarkChrome)
        XCTAssertFalse(Theme.theme(for: .paper).usesDarkChrome)
        XCTAssertFalse(Theme.theme(for: .calm).usesDarkChrome)
        XCTAssertTrue(Theme.theme(for: .quiet).usesDarkChrome)
        XCTAssertTrue(Theme.theme(for: .night).usesDarkChrome)
    }

    @MainActor
    func testEditorSelectionHighlightFollowsReaderTheme() throws {
        let lightBackground = try XCTUnwrap(
            LineformTextView.selectedTextAttributes(usesDarkChrome: false)[.backgroundColor] as? NSColor
        ).usingColorSpace(.sRGB)
        let darkBackground = try XCTUnwrap(
            LineformTextView.selectedTextAttributes(usesDarkChrome: true)[.backgroundColor] as? NSColor
        ).usingColorSpace(.sRGB)

        XCTAssertEqual(lightBackground?.alphaComponent ?? -1, LineformTextView.lightSelectionBackgroundAlpha, accuracy: 0.005)
        XCTAssertEqual(darkBackground?.alphaComponent ?? -1, LineformTextView.darkSelectionBackgroundAlpha, accuracy: 0.005)
    }

    func testCodeAccentBlueMaintainsTextContrastAcrossReaderThemes() {
        for theme in Theme.builtIn {
            let contrast = Self.contrastRatio(
                MarkdownSyntaxHighlighter.inlineCodeColor(for: theme),
                theme.backgroundColor
            )

            XCTAssertGreaterThanOrEqual(contrast, 4.5, theme.name)
        }
    }

    @MainActor
    func testMarkdownMarkersMaintainTextContrastWhenLegacyNoiseSettingIsEnabled() throws {
        for preset in ReadingPreset.builtIn {
            let textView = LineformTextView()
            textView.string = "# Title"
            var profile = preset.profile
            profile.reduceMarkdownNoise = true
            textView.applyTypography(profile)

            let theme = Theme.theme(for: profile)
            let markerColor = try XCTUnwrap(textView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
            let renderedMarkerColor = Self.color(markerColor, compositedOver: theme.backgroundColor)
            let contrast = Self.contrastRatio(renderedMarkerColor, theme.backgroundColor)

            XCTAssertGreaterThanOrEqual(contrast, 4.5, preset.profile.name)
        }
    }

    func testThemeIDsOnlyRepresentNormalReaderThemes() {
        XCTAssertEqual(ThemeID.allCases, [.system, .paper, .calm, .quiet, .night])
    }

    func testHighContrastProfileResolvesToHighContrastThemeColors() {
        let theme = Theme.theme(for: ReadingPreset.highContrast.profile)

        XCTAssertEqual(theme.textColor, .textColor)
        XCTAssertEqual(theme.backgroundColor, .textBackgroundColor)
        XCTAssertEqual(theme.caretColor, .textColor)
    }

    private func assertSameRGB(_ first: NSColor, _ second: NSColor, file: StaticString = #filePath, line: UInt = #line) {
        let firstRGB = first.usingColorSpace(.sRGB)
        let secondRGB = second.usingColorSpace(.sRGB)
        XCTAssertEqual(firstRGB?.redComponent ?? -1, secondRGB?.redComponent ?? -2, accuracy: 0.005, file: file, line: line)
        XCTAssertEqual(firstRGB?.greenComponent ?? -1, secondRGB?.greenComponent ?? -2, accuracy: 0.005, file: file, line: line)
        XCTAssertEqual(firstRGB?.blueComponent ?? -1, secondRGB?.blueComponent ?? -2, accuracy: 0.005, file: file, line: line)
    }

    private static func contrastRatio(_ first: NSColor, _ second: NSColor) -> CGFloat {
        let firstLuminance = relativeLuminance(first)
        let secondLuminance = relativeLuminance(second)
        return (max(firstLuminance, secondLuminance) + 0.05) / (min(firstLuminance, secondLuminance) + 0.05)
    }

    private static func relativeLuminance(_ color: NSColor) -> CGFloat {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        return 0.2126 * linearized(rgb.redComponent)
            + 0.7152 * linearized(rgb.greenComponent)
            + 0.0722 * linearized(rgb.blueComponent)
    }

    private static func linearized(_ component: CGFloat) -> CGFloat {
        component <= 0.03928 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
    }

    private static func color(_ foreground: NSColor, compositedOver background: NSColor) -> NSColor {
        let fg = foreground.usingColorSpace(.sRGB) ?? foreground
        let bg = background.usingColorSpace(.sRGB) ?? background
        let alpha = fg.alphaComponent

        return NSColor(
            srgbRed: fg.redComponent * alpha + bg.redComponent * (1 - alpha),
            green: fg.greenComponent * alpha + bg.greenComponent * (1 - alpha),
            blue: fg.blueComponent * alpha + bg.blueComponent * (1 - alpha),
            alpha: 1
        )
    }

    /// Link/image ink and the diagram fallback caption were the two reader inks never put under the
    /// contrast gate — the first because it was the only ink not derived from the theme, the second
    /// because a flat 0.6 alpha reads as a style choice rather than a contrast decision.
    func testEveryReaderInkMeetsAAOnEveryTheme() {
        for theme in Theme.builtIn {
            let link = theme.readableInk(NSColor.linkColor)
            XCTAssertGreaterThanOrEqual(
                Theme.contrastRatio(link, theme.backgroundColor), 4.5,
                "link ink on \(theme.name)"
            )

            let caption = theme.readableInk(theme.textColor.withAlphaComponent(0.6))
            XCTAssertGreaterThanOrEqual(
                Theme.contrastRatio(caption, theme.backgroundColor), 4.5,
                "diagram/math fallback caption on \(theme.name)"
            )
        }
    }

    /// The contrast math now lives in `Theme` so production and tests share one definition.
    func testThemeContrastRatioMatchesTheKnownWCAGEndpoints() {
        XCTAssertEqual(Theme.contrastRatio(.white, .black), 21, accuracy: 0.01)
        XCTAssertEqual(Theme.contrastRatio(.white, .white), 1, accuracy: 0.01)
    }

}
