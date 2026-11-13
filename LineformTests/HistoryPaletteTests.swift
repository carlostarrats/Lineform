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
            HistoryPalette.recededInk(for: theme),
            HistoryPalette.focusOtherInk(for: theme),
            HistoryPalette.deepRecededInk(for: theme),
            HistoryPalette.counterInk(for: theme),
        ]
    }

    func testTintedTextMeetsAAOnEveryTheme() {
        for theme in Theme.builtIn {
            let tints = [
                ("tint", HistoryPalette.tint(for: theme)),
                ("hover", HistoryPalette.hoverTint(for: theme)),
            ]
            for (name, tint) in tints {
                let flattened = Self.flattened(tint, over: theme.backgroundColor)
                let ratio = Theme.contrastRatio(theme.textColor, flattened)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(name) on \(theme.name) was \(ratio)")
            }
        }
    }

    /// Plain passages stack their washes (a word in a changed sentence in a changed paragraph sits
    /// on three). Hover is drawn OPAQUE over them, so they are exactly the
    /// page-flattened tint whatever is nested beneath — the pair the AA test above measures.
    func testNestedWashesMeetAAAndHoverSelectionFillsAreOpaque() {
        for theme in Theme.builtIn {
            var page = theme.backgroundColor
            for _ in 0..<3 {
                page = Self.flattened(HistoryPalette.tint(for: theme), over: page)
            }
            XCTAssertGreaterThanOrEqual(Theme.contrastRatio(theme.textColor, page), 4.5, theme.name)

            for tint in [HistoryPalette.hoverTint(for: theme)] {
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

    /// Focus: the focused passage and its counter are full ink (AA); the other inks keep their
    /// documented floors and step down in order: receded > focus-other > deep receded.
    func testFocusInksKeepTheirFloorsAndOrderOnEveryTheme() {
        for theme in Theme.builtIn {
            let page = theme.backgroundColor
            XCTAssertGreaterThanOrEqual(Theme.contrastRatio(theme.textColor, page), 4.5, theme.name)
            XCTAssertGreaterThanOrEqual(Theme.contrastRatio(HistoryPalette.counterInk(for: theme), page), 4.5, theme.name)
            let receded = Theme.contrastRatio(HistoryPalette.recededInk(for: theme), page)
            let other = Theme.contrastRatio(HistoryPalette.focusOtherInk(for: theme), page)
            let deep = Theme.contrastRatio(HistoryPalette.deepRecededInk(for: theme), page)
            XCTAssertGreaterThanOrEqual(other, 2.5, "\(theme.name) focus-other was \(other)")
            XCTAssertGreaterThanOrEqual(deep, 2.0, "\(theme.name) deep receded was \(deep)")
            XCTAssertGreaterThanOrEqual(receded + 0.001, other, theme.name)
            XCTAssertGreaterThanOrEqual(other + 0.001, deep, theme.name)
        }
    }

    /// The AI review's replacement highlight: visibly different from the page on every theme,
    /// and the text drawn on it keeps AA.
    func testReviewInsertTintIsVisibleInEveryTheme() {
        for theme in Theme.builtIn {
            let tint = HistoryPalette.reviewInsertTint(for: theme)
            let fill = Self.flattened(tint, over: theme.backgroundColor)
            let visible = Theme.contrastRatio(fill, theme.backgroundColor)
            XCTAssertGreaterThanOrEqual(visible, 1.15, "\(theme.name) tint vs page was \(visible)")
            let text = Theme.contrastRatio(theme.textColor, fill)
            XCTAssertGreaterThanOrEqual(text, 4.5, "\(theme.name) text on tint was \(text)")
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
