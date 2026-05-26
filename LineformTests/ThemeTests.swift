import AppKit
import XCTest
@testable import Lineform

final class ThemeTests: XCTestCase {
    func testBuiltInThemesHaveDistinctForegroundAndBackgroundColors() {
        for theme in Theme.builtIn {
            XCTAssertNotEqual(theme.textColor, theme.backgroundColor, theme.name)
        }
    }

    func testReaderThemesStaySmallAndAppleBooksStyle() {
        XCTAssertEqual(Theme.readerThemes.map(\.id), [.system, .paper, .calm, .quiet, .night])
        XCTAssertEqual(Theme.readerThemes.map(\.name), ["Original", "Paper", "Calm", "Quiet", "Night"])
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

    func testCodeAccentBlueMaintainsTextContrastAcrossReaderThemes() {
        for theme in Theme.readerThemes {
            let contrast = Self.contrastRatio(
                MarkdownSyntaxHighlighter.inlineCodeColor(for: theme),
                theme.backgroundColor
            )

            XCTAssertGreaterThanOrEqual(contrast, 4.5, theme.name)
        }
    }

    @MainActor
    func testMarkdownMarkersMaintainTextContrastWhenNoiseIsReduced() throws {
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
}
