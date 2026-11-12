import XCTest
import AppKit
@testable import Lineform

@MainActor
final class HistoryPaletteTests: XCTestCase {
    /// A translucent fill as the reader sees it: composited over the page.
    private static func flattened(_ color: NSColor, over page: NSColor) -> NSColor {
        let top = color.usingColorSpace(.sRGB) ?? color
        let bottom = page.usingColorSpace(.sRGB) ?? page
        let alpha = top.alphaComponent
        func blend(_ base: CGFloat, _ over: CGFloat) -> CGFloat { base + (over - base) * alpha }
        return NSColor(
            srgbRed: blend(bottom.redComponent, top.redComponent),
            green: blend(bottom.greenComponent, top.greenComponent),
            blue: blend(bottom.blueComponent, top.blueComponent),
            alpha: 1
        )
    }

    private static func palette(for theme: Theme) -> [NSColor] {
        [
            HistoryPalette.tint(for: theme),
            HistoryPalette.hoverTint(for: theme),
            HistoryPalette.selectionTint(for: theme),
            HistoryPalette.recededInk(for: theme),
            HistoryPalette.dotInk(for: theme),
        ]
    }

    func testTintedTextMeetsAAOnEveryTheme() {
        for theme in Theme.builtIn {
            let tints = [
                ("tint", HistoryPalette.tint(for: theme)),
                ("hover", HistoryPalette.hoverTint(for: theme)),
                ("selection", HistoryPalette.selectionTint(for: theme)),
            ]
            for (name, tint) in tints {
                let flattened = Self.flattened(tint, over: theme.backgroundColor)
                let ratio = Theme.contrastRatio(theme.textColor, flattened)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(name) on \(theme.name) was \(ratio)")
            }
        }
    }

    /// Plain passages stack their washes (a word in a changed sentence in a changed paragraph sits
    /// on three). Hover and selection are drawn OPAQUE over them, so they are exactly the
    /// page-flattened tint whatever is nested beneath — the pair the AA test above measures.
    func testNestedWashesMeetAAAndHoverSelectionFillsAreOpaque() {
        for theme in Theme.builtIn {
            var page = theme.backgroundColor
            for _ in 0..<3 {
                page = Self.flattened(HistoryPalette.tint(for: theme), over: page)
            }
            XCTAssertGreaterThanOrEqual(Theme.contrastRatio(theme.textColor, page), 4.5, theme.name)

            for tint in [HistoryPalette.hoverTint(for: theme), HistoryPalette.selectionTint(for: theme)] {
                let fill = HistoryPalette.opaqueFill(tint, for: theme)
                XCTAssertEqual(fill.alphaComponent, 1, theme.name)
                XCTAssertGreaterThanOrEqual(Theme.contrastRatio(theme.textColor, fill), 4.5, theme.name)
                let expected = Self.flattened(tint, over: theme.backgroundColor).usingColorSpace(.sRGB)!
                let actual = fill.usingColorSpace(.sRGB)!
                XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.002, theme.name)
                XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.002, theme.name)
            }
        }
    }

    func testRecededInkStaysReadableOnEveryTheme() {
        for theme in Theme.builtIn {
            let receded = HistoryPalette.recededInk(for: theme)
            let ratio = Theme.contrastRatio(receded, theme.backgroundColor)
            XCTAssertGreaterThanOrEqual(ratio, 3.0, "\(theme.name) was \(ratio)")
            XCTAssertLessThan(
                ratio,
                Theme.contrastRatio(theme.textColor, theme.backgroundColor),
                "\(theme.name): receded text must actually recede"
            )
        }
    }

    func testDotInkMeetsNonTextContrastOnEveryTheme() {
        for theme in Theme.builtIn {
            let ratio = Theme.contrastRatio(HistoryPalette.dotInk(for: theme), theme.backgroundColor)
            XCTAssertGreaterThanOrEqual(ratio, 3.0, "\(theme.name) was \(ratio)")
        }
    }

    func testSelectionIsBlueNotGrey() {
        for theme in Theme.builtIn {
            let blue = HistoryPalette.selectionTint(for: theme).usingColorSpace(.sRGB)!
            XCTAssertGreaterThan(blue.blueComponent, blue.redComponent + 0.3, theme.name)
        }
    }

    /// The text view draws with the DISPLAY profile, so under Automatic Dark Mode a light preset
    /// resolves to Quiet — and the History palette must follow it there.
    func testAutomaticDarkModeUsesQuietPalette() {
        for preset in ReadingPreset.builtIn where !preset.profile.highContrastEnabled
            && !ReadingProfile.automaticDarkModeExemptThemes.contains(preset.profile.themeID) {
            let shown = preset.profile.displayProfile(automaticDarkMode: true, systemIsDark: true)
            let theme = Theme.theme(for: shown)
            XCTAssertEqual(theme.id, .quiet)
            XCTAssertEqual(Self.palette(for: theme), Self.palette(for: .quiet), "\(preset.profile.themeID)")
        }
    }
}
