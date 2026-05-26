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
        assertColor(Theme.system.backgroundColor, equalsHex: 0xFFFFFF)
        assertColor(Theme.paper.backgroundColor, equalsHex: 0xF6F3ED)
        assertColor(Theme.calm.backgroundColor, equalsHex: 0xF2F4F5)
        assertColor(Theme.system.textColor, equalsHex: 0x1F1F1F)
        assertColor(Theme.paper.textColor, equalsHex: 0x1F1F1F)
        assertColor(Theme.calm.textColor, equalsHex: 0x1F1F1F)
    }

    func testOriginalThemeStaysLightWhenPreviewedFromDarkChrome() throws {
        let darkAppearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
        var resolvedBackground: NSColor?
        var resolvedText: NSColor?

        darkAppearance.performAsCurrentDrawingAppearance {
            resolvedBackground = Theme.system.backgroundColor.usingColorSpace(.sRGB)
            resolvedText = Theme.system.textColor.usingColorSpace(.sRGB)
        }

        assertColor(try XCTUnwrap(resolvedBackground), equalsHex: 0xFFFFFF)
        assertColor(try XCTUnwrap(resolvedText), equalsHex: 0x1F1F1F)
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

    func testThemeIDsOnlyRepresentNormalReaderThemes() {
        XCTAssertEqual(ThemeID.allCases, [.system, .paper, .calm, .quiet, .night])
    }

    func testHighContrastProfileResolvesToHighContrastThemeColors() {
        let theme = Theme.theme(for: ReadingPreset.highContrast.profile)

        XCTAssertEqual(theme.textColor, .textColor)
        XCTAssertEqual(theme.backgroundColor, .textBackgroundColor)
        XCTAssertEqual(theme.caretColor, .textColor)
    }

    private func assertColor(_ color: NSColor, equalsHex hex: Int, file: StaticString = #filePath, line: UInt = #line) {
        let rgb = color.usingColorSpace(.sRGB)
        XCTAssertEqual(rgb?.redComponent ?? -1, CGFloat((hex >> 16) & 0xFF) / 255, accuracy: 0.005, file: file, line: line)
        XCTAssertEqual(rgb?.greenComponent ?? -1, CGFloat((hex >> 8) & 0xFF) / 255, accuracy: 0.005, file: file, line: line)
        XCTAssertEqual(rgb?.blueComponent ?? -1, CGFloat(hex & 0xFF) / 255, accuracy: 0.005, file: file, line: line)
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
}
