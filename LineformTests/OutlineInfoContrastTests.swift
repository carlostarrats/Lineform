import XCTest
import AppKit
@testable import Lineform

final class OutlineMarkdownBasicsContrastTests: XCTestCase {
    // The Markdown Basics tab draws in the sidebar's chrome-mode colors. The sidebar background
    // is chrome-mode-based, not per-theme (dark chrome = the Quiet/Night themes), so
    // two checks — light chrome and dark chrome — cover every reader theme.
    private func background(darkChrome: Bool) -> NSColor {
        // Dark chrome is a specified hex (#303031) built in sRGB in production; measuring it as
        // `calibratedWhite` would grade these ratios against a swatch that never ships.
        guard darkChrome else {
            return NSColor(calibratedWhite: OutlineSidebarView.lightBackgroundWhiteComponent, alpha: 1)
        }
        return OutlineSidebarView.darkBackgroundNSColor
    }

    // Syntax reuses the sidebar's primary text color; the explanation uses the Info
    // tab's own AA-safe muted tone (the sidebar secondary dips below AA on the light page).
    private func syntaxText(darkChrome: Bool) -> NSColor {
        NSColor(calibratedWhite: darkChrome ? OutlineSidebarView.darkPrimaryTextWhiteComponent
                                            : OutlineSidebarView.primaryTextWhiteComponent,
                alpha: 1)
    }

    private func explanationText(darkChrome: Bool) -> NSColor {
        // Dark reuses the sidebar's secondary (already AA); only light is overridden.
        NSColor(calibratedWhite: darkChrome ? OutlineSidebarView.darkSecondaryTextWhiteComponent
                                            : OutlineMarkdownBasicsTabView.explanationLightWhiteComponent,
                alpha: 1)
    }

    func testSecondaryExplanationTextMeetsAAInBothChromes() {
        for darkChrome in [false, true] {
            XCTAssertGreaterThanOrEqual(
                Self.contrastRatio(explanationText(darkChrome: darkChrome), background(darkChrome: darkChrome)), 4.5,
                "explanation text, darkChrome=\(darkChrome)"
            )
        }
    }

    func testPrimarySyntaxTextMeetsAAInBothChromes() {
        for darkChrome in [false, true] {
            XCTAssertGreaterThanOrEqual(
                Self.contrastRatio(syntaxText(darkChrome: darkChrome), background(darkChrome: darkChrome)), 4.5,
                "syntax text, darkChrome=\(darkChrome)"
            )
        }
    }

    private static func contrastRatio(_ a: NSColor, _ b: NSColor) -> CGFloat {
        func lum(_ c: NSColor) -> CGFloat {
            let s = c.usingColorSpace(.sRGB) ?? c
            func chan(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * chan(s.redComponent) + 0.7152 * chan(s.greenComponent) + 0.0722 * chan(s.blueComponent)
        }
        let l1 = lum(a), l2 = lum(b)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }
}
