import XCTest
@testable import Lineform

@MainActor
final class AIReviewPillCellTests: XCTestCase {
    private let cellFrame = NSRect(x: 10, y: 20, width: AIReviewPillCell.size.width + AIReviewPillCell.leadingGap,
                                   height: AIReviewPillCell.size.height)

    func testCellSizeIsThePillPlusItsLeadingGap() {
        let cell = AIReviewPillCell(changeID: 4, isCurrent: true, ink: .black)
        XCTAssertEqual(AIReviewPillCell.size, NSSize(width: 38, height: 18))
        XCTAssertEqual(AIReviewPillCell.leadingGap, 3)
        XCTAssertEqual(cell.cellSize(), NSSize(width: 41, height: 18))
        XCTAssertEqual(cell.changeID, 4)
        let outline = AIReviewPillCell.outlineRect(in: cellFrame)
        XCTAssertEqual(outline, NSRect(x: 13, y: 20, width: 38, height: 18))
    }

    func testLeftHalfAcceptsRightHalfRejects() {
        let cell = AIReviewPillCell(changeID: 0, isCurrent: false, ink: .black)
        let outline = AIReviewPillCell.outlineRect(in: cellFrame)
        XCTAssertEqual(cell.part(at: NSPoint(x: outline.minX + 4, y: outline.midY), in: cellFrame), .accept)
        XCTAssertEqual(cell.part(at: NSPoint(x: outline.midX - 0.5, y: outline.midY), in: cellFrame), .accept)
        XCTAssertEqual(cell.part(at: NSPoint(x: outline.midX + 0.5, y: outline.midY), in: cellFrame), .reject)
        XCTAssertEqual(cell.part(at: NSPoint(x: outline.maxX - 4, y: outline.minY + 2), in: cellFrame), .reject)
        XCTAssertEqual(cell.part(at: NSPoint(x: cellFrame.minX + 1, y: outline.midY), in: cellFrame), .accept,
                       "the leading gap belongs to the ✓ side")
    }

    func testDividerStopsShortOfEdges() {
        let outline = AIReviewPillCell.outlineRect(in: cellFrame)
        // The 1pt outline is stroked inside the pill's box, so its inner edge is 1pt in.
        let inner = outline.insetBy(dx: AIReviewPillCell.outlineWidth, dy: AIReviewPillCell.outlineWidth)
        let divider = AIReviewPillCell.dividerRect(in: cellFrame)
        XCTAssertEqual(AIReviewPillCell.outlineWidth, 1)
        XCTAssertEqual(divider.width, 0.75)
        XCTAssertEqual(divider.midX, outline.midX, accuracy: 0.0001)
        XCTAssertEqual(divider.minY, inner.minY + 1, accuracy: 0.0001)
        XCTAssertEqual(divider.maxY, inner.maxY - 1, accuracy: 0.0001)
    }

    func testPillInksMeetContrastOnEveryTheme() {
        for theme in Theme.builtIn {
            let page = theme.backgroundColor
            XCTAssertGreaterThanOrEqual(Theme.contrastRatio(theme.textColor, page), 4.5, "\(theme.id) current pill")
            XCTAssertGreaterThanOrEqual(Theme.contrastRatio(HistoryPalette.recededInk(for: theme), page), 3.0,
                                        "\(theme.id) other pills and removed text")
        }
    }

    func testPillDrawsOutlineOnlyInItsInk() throws {
        let cell = AIReviewPillCell(changeID: 0, isCurrent: true, ink: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        let size = NSSize(width: 41, height: 18)
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 82, pixelsHigh: 36,
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        cell.draw(withFrame: NSRect(origin: .zero, size: size), in: nil)
        NSGraphicsContext.restoreGraphicsState()
        // The gap and the pill's interior between the glyphs and the divider stay clear: no fill.
        XCTAssertEqual(rep.colorAt(x: 2, y: 18)?.alphaComponent ?? 0, 0, accuracy: 0.01, "the leading gap is empty")
        XCTAssertEqual(rep.colorAt(x: 52, y: 6)?.alphaComponent ?? 0, 0, accuracy: 0.01, "no fill inside the outline")
        // Something is drawn, and it is the ink (red), never another colour.
        var drawn = 0
        for x in 0..<82 {
            for y in 0..<36 {
                guard let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.5 else { continue }
                drawn += 1
                XCTAssertLessThan(color.greenComponent, 0.2)
                XCTAssertLessThan(color.blueComponent, 0.2)
            }
        }
        XCTAssertGreaterThan(drawn, 40)
    }
}
