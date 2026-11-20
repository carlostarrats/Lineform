import AppKit
import XCTest
@testable import Lineform
@testable import LineformCore

/// Task 3a (memory-sized cache), Task 3b (transparent background + fixed ink), and the resize
/// refit nit — the pure, deterministic pieces of the 2026-07-04 diagram/render bundle. The cache
/// cost, budget and refit tests moved to LineformCoreTests with `DiagramCardStyle.swift`; these two
/// use app types.
final class DiagramCardAndCacheTests: XCTestCase {

    // MARK: - Fixed diagram/math ink (Task 3b): transparent background, AA-legible on every page

    func testDiagramInkMeetsAAAgainstEverySameSideThemePage() {
        // Block diagrams/math are transparent, so the ink sits directly on the page. Light-theme ink
        // must clear WCAG AA on every light page; dark-theme ink on every dark page.
        for theme in [Theme.system, Theme.paper, Theme.calm] {
            XCTAssertGreaterThanOrEqual(
                Self.contrastRatio(DiagramPalette.ink(isDark: false), theme.backgroundColor), 4.5, "light ink on \(theme.name)")
        }
        for theme in [Theme.quiet, Theme.night] {
            XCTAssertGreaterThanOrEqual(
                Self.contrastRatio(DiagramPalette.ink(isDark: true), theme.backgroundColor), 4.5, "dark ink on \(theme.name)")
        }
    }

    func testBlockAttachmentFitWidthShrinksOnNarrowWindow() {
        var profile = ReadingProfile.original
        profile.columnWidth = 820
        profile.marginWidth = 40
        // Window wider than the column: fit width == column width.
        XCTAssertEqual(
            EditorReadingLayout.blockAttachmentFitWidth(forContainerWidth: 1200, profile: profile),
            820, accuracy: 0.001
        )
        // Window narrower than the column: fit width shrinks to the visible text width (700 - 2*40).
        XCTAssertEqual(
            EditorReadingLayout.blockAttachmentFitWidth(forContainerWidth: 700, profile: profile),
            620, accuracy: 0.001
        )
    }

    // WCAG contrast helpers (mirror ThemeTests)
    private static func contrastRatio(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let la = relativeLuminance(a); let lb = relativeLuminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
    private static func relativeLuminance(_ color: NSColor) -> CGFloat {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        return 0.2126 * linearized(rgb.redComponent)
            + 0.7152 * linearized(rgb.greenComponent)
            + 0.0722 * linearized(rgb.blueComponent)
    }
    private static func linearized(_ c: CGFloat) -> CGFloat {
        c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
}
