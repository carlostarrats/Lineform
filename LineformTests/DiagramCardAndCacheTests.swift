import AppKit
import XCTest
@testable import Lineform

/// Task 3a (memory-sized cache), Task 3b (transparent background + fixed ink), and the resize
/// refit nit — the pure, deterministic pieces of the 2026-07-04 diagram/render bundle.
final class DiagramCardAndCacheTests: XCTestCase {

    // MARK: - RasterImageCost (memory-sized cache)

    private func bitmapImage(pixelsWide w: Int, pixelsHigh h: Int) -> NSImage {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        let image = NSImage(size: NSSize(width: w, height: h))
        image.addRepresentation(rep)
        return image
    }

    func testRasterCostIsPixelAreaTimesFourBytes() {
        let cost = RasterImageCost.bytes(for: bitmapImage(pixelsWide: 100, pixelsHigh: 50))
        XCTAssertEqual(cost, 100 * 50 * 4)
    }

    func testRasterCostGrowsWithPixelArea() {
        let small = RasterImageCost.bytes(for: bitmapImage(pixelsWide: 100, pixelsHigh: 50))
        let large = RasterImageCost.bytes(for: bitmapImage(pixelsWide: 400, pixelsHigh: 200))
        XCTAssertGreaterThan(large, small)
    }

    // MARK: - Cache budgets are memory-sized and bigger than the old flat caps

    func testDiagramCacheBudgetIsMemorySizedAndGenerous() {
        // Bigger than the old flat count cap of 50, plus a real byte ceiling so a diagram-heavy
        // document isn't constantly evicting and redrawing.
        XCTAssertGreaterThan(DiagramCacheBudget.countLimit, 50)
        XCTAssertGreaterThanOrEqual(DiagramCacheBudget.totalCostLimitBytes, 32 * 1024 * 1024)
    }

    func testMathCacheBudgetIsMemorySizedAndGenerous() {
        XCTAssertGreaterThan(MathCacheBudget.countLimit, 100)
        XCTAssertGreaterThanOrEqual(MathCacheBudget.totalCostLimitBytes, 16 * 1024 * 1024)
    }

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

    // MARK: - Block attachment refit (resize nit)

    func testWideAttachmentRefitsDownPreservingAspectAndBaseline() throws {
        let bounds = try XCTUnwrap(BlockAttachmentRefit.refittedBounds(
            naturalSize: CGSize(width: 1200, height: 600),
            currentBounds: CGRect(x: 0, y: 0, width: 820, height: 410),
            fitWidth: 620
        ))
        XCTAssertEqual(bounds.width, 620, accuracy: 0.001)
        XCTAssertEqual(bounds.height, 310, accuracy: 0.001)   // aspect ratio (0.5) preserved
        XCTAssertEqual(bounds.origin.y, 0, accuracy: 0.001)
    }

    func testAttachmentThatAlreadyFitsIsNotRefit() {
        // Fit width >= natural width: nothing to do — never upscale past natural resolution.
        XCTAssertNil(BlockAttachmentRefit.refittedBounds(
            naturalSize: CGSize(width: 300, height: 100),
            currentBounds: CGRect(x: 0, y: 0, width: 300, height: 100),
            fitWidth: 620
        ))
    }

    func testInlineMathAttachmentKeepsItsBaselineOffsetAndIsUntouched() {
        // A small inline equation (natural 10 wide, baseline offset y = -3) fits any column, so it
        // is never resized — its -descent baseline offset must survive a resize.
        XCTAssertNil(BlockAttachmentRefit.refittedBounds(
            naturalSize: CGSize(width: 10, height: 8),
            currentBounds: CGRect(x: 0, y: -3, width: 10, height: 8),
            fitWidth: 620
        ))
    }

    func testNarrowedThenWidenedAttachmentRefitsBackUp() throws {
        // Previously shrunk to 620; window widened so the fit width is now 1000; natural is 1200 →
        // grows back to 1000 (still capped at natural, never beyond it).
        let bounds = try XCTUnwrap(BlockAttachmentRefit.refittedBounds(
            naturalSize: CGSize(width: 1200, height: 600),
            currentBounds: CGRect(x: 0, y: 0, width: 620, height: 310),
            fitWidth: 1000
        ))
        XCTAssertEqual(bounds.width, 1000, accuracy: 0.001)
    }

    // MARK: - Viewport-adaptive height cap on refit (block images only)

    func testRefitWithFiniteMaxHeightClampsTallImageAspectPreserved() throws {
        // A tall, narrow image: width-fit alone (620) would produce height 1240 (2x aspect),
        // which overshoots a short window's cap. maxHeight clamps height and rescales width to match.
        let bounds = try XCTUnwrap(BlockAttachmentRefit.refittedBounds(
            naturalSize: CGSize(width: 600, height: 1200),
            currentBounds: CGRect(x: 0, y: 0, width: 300, height: 600),
            fitWidth: 620,
            maxHeight: 300
        ))
        XCTAssertEqual(bounds.height, 300, accuracy: 0.001)
        XCTAssertEqual(bounds.width, 150, accuracy: 0.001)   // aspect ratio (0.5) preserved
    }

    func testRefitWithFiniteMaxHeightLeavesShortImageUnchangedByHeight() {
        // Width-fit height (310) already sits under the cap (500): no additional height clamp,
        // identical to the uncapped width-fit result.
        let bounds = BlockAttachmentRefit.refittedBounds(
            naturalSize: CGSize(width: 1200, height: 600),
            currentBounds: CGRect(x: 0, y: 0, width: 820, height: 410),
            fitWidth: 620,
            maxHeight: 500
        )
        XCTAssertEqual(bounds?.width ?? -1, 620, accuracy: 0.001)
        XCTAssertEqual(bounds?.height ?? -1, 310, accuracy: 0.001)
    }

    func testRefitDefaultMaxHeightIsInfinityAndMatchesUncappedBehavior() throws {
        // Omitting maxHeight (mermaid/math call sites) must be byte-identical to a call with an
        // explicit .infinity — proving existing callers are unaffected by the new parameter.
        let withDefault = try XCTUnwrap(BlockAttachmentRefit.refittedBounds(
            naturalSize: CGSize(width: 1200, height: 600),
            currentBounds: CGRect(x: 0, y: 0, width: 820, height: 410),
            fitWidth: 620
        ))
        let withExplicitInfinity = try XCTUnwrap(BlockAttachmentRefit.refittedBounds(
            naturalSize: CGSize(width: 1200, height: 600),
            currentBounds: CGRect(x: 0, y: 0, width: 820, height: 410),
            fitWidth: 620,
            maxHeight: .infinity
        ))
        XCTAssertEqual(withDefault, withExplicitInfinity)
    }

    func testBlockRenderedAttachmentDefaultsToNoViewportHeightCap() {
        // Mermaid/math attachments never set the marker; it must default false.
        XCTAssertFalse(BlockRenderedAttachment().appliesViewportHeightCap)
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
