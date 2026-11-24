import CoreGraphics
import XCTest
@testable import LineformCore

final class HighlighterSelectionTests: XCTestCase {
    private func line(seed: Int, minX: CGFloat = 100, maxX: CGFloat = 400, centerY: CGFloat = 50) -> HighlighterSelection.Line {
        HighlighterSelection.Line(minX: minX, maxX: maxX, centerY: centerY, textHeight: 20, pitch: 30, seed: seed)
    }

    func testTheSameLineAlwaysGetsTheSameStroke() {
        let a = HighlighterSelection.path(for: line(seed: 4_211))
        let b = HighlighterSelection.path(for: line(seed: 4_211))
        XCTAssertEqual(a.boundingBox, b.boundingBox)
        XCTAssertTrue(a == b)
    }

    func testEndsDifferFromLineToLine() {
        let rights = (0..<12).map { HighlighterSelection.path(for: line(seed: $0 * 97)).boundingBox.maxX }
        XCTAssertGreaterThan(Set(rights.map { Int($0.rounded()) }).count, 6, "right edges must not line up")
    }

    func testStrokeOvershootsWithinItsReach() {
        for seed in stride(from: 0, to: 5_000, by: 37) {
            let line = line(seed: seed)
            let box = HighlighterSelection.path(for: line).boundingBox
            // It always reaches past the text on both ends, and never beyond the invalidation reach.
            XCTAssertLessThan(box.minX, line.minX)
            XCTAssertGreaterThan(box.maxX, line.maxX)
            XCTAssertTrue(HighlighterSelection.paintBounds(for: line).contains(box), "seed \(seed)")
            XCTAssertLessThanOrEqual(line.minX - box.minX, 14)
            XCTAssertLessThanOrEqual(box.maxX - line.maxX, 18)
        }
    }

    func testConsecutiveLinesJustTouch() {
        var top = line(seed: 1, centerY: 50), next = line(seed: 2, centerY: 80)
        top.textHeight = 24
        next.textHeight = 24
        let topBox = HighlighterSelection.strokeBox(for: top), nextBox = HighlighterSelection.strokeBox(for: next)
        XCTAssertEqual(topBox.maxY - nextBox.minY, HighlighterSelection.lineOverlap, accuracy: 0.001)
    }

    func testLooseLinesAreCapped() {
        var loose = line(seed: 1)
        loose.pitch = 80
        XCTAssertEqual(HighlighterSelection.strokeBox(for: loose).height, 20 * HighlighterSelection.maximumHeightRatio, accuracy: 0.001)
    }

    func testAnEmptyLineStillShowsANib() {
        let box = HighlighterSelection.strokeBox(for: line(seed: 3, minX: 100, maxX: 100))
        XCTAssertEqual(box.width, HighlighterSelection.emptyLineWidth)
    }

    func testIncreasedContrastIsStronger() {
        for dark in [false, true] {
            XCTAssertGreaterThan(
                HighlighterSelection.opacity(usesDarkChrome: dark, increasedContrast: true),
                HighlighterSelection.opacity(usesDarkChrome: dark, increasedContrast: false)
            )
        }
    }

    /// Text on the stroke stays AA (4.5:1) in every theme, at both strengths. Where two calm strokes
    /// overlap (a 2 pt sliver between lines, where the marker darkens) it stays at least 3:1; under
    /// Increase Contrast the strokes never double up (`darkensOverlaps`).
    func testInkStaysReadableOnTheStroke() throws {
        for theme in Theme.builtIn {
            for increased in [false, true] {
                let fill = try XCTUnwrap(HighlighterSelection.fillColor(for: theme, increasedContrast: increased).lineformSRGBComponents)
                let page = theme.backgroundColor.lineformSRGBComponentsOrOwn
                let layerCounts = HighlighterSelection.darkensOverlaps(increasedContrast: increased) ? [1, 2] : [1]
                for layers in layerCounts {
                    let a = 1 - pow(1 - fill.alpha, CGFloat(layers))
                    func mix(_ p: CGFloat, _ f: CGFloat) -> CGFloat { p + (f - p) * a }
                    let ground = PlatformColor.lineformSRGB(red: mix(page.red, fill.red), green: mix(page.green, fill.green),
                                                            blue: mix(page.blue, fill.blue), alpha: 1)
                    let ratio = Theme.contrastRatio(theme.textColor, ground)
                    XCTAssertGreaterThanOrEqual(ratio, layers == 1 ? 4.5 : 3.0,
                                                "\(theme.name) increased:\(increased) layers:\(layers) = \(ratio)")
                }
            }
        }
    }
}
