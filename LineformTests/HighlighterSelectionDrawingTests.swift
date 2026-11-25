import XCTest
import AppKit
@testable import Lineform
@testable import LineformCore

/// The Mac editor's highlighter selection, rendered without a window (default test plan).
@MainActor
final class HighlighterSelectionDrawingTests: XCTestCase {
    private let sample = """
    In response, the company responsibly disclosed the identified zero-day vulnerability in the internally-hosted third-party software and are working with them to patch.

    But to most professionals, vulnerabilities are to be expected.
    """

    private func laidOutTextView(profile: ReadingProfile = .original) throws -> LineformTextView {
        let textView = LineformTextView()
        textView.frame = NSRect(x: 0, y: 0, width: 640, height: 420)
        textView.applyTypography(profile)
        textView.string = sample
        textView.layoutManager?.ensureLayout(for: try XCTUnwrap(textView.textContainer))
        return textView
    }

    private func bitmap(of textView: NSTextView) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(textView.bitmapImageRepForCachingDisplay(in: textView.bounds))
        textView.cacheDisplay(in: textView.bounds, to: rep)
        // For a look by eye: `TEST_RUNNER_HIGHLIGHTER_SNAPSHOTS=1` writes each render to the test
        // host's temporary folder (the app container's `tmp`).
        if ProcessInfo.processInfo.environment["HIGHLIGHTER_SNAPSHOTS"] != nil,
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("highlighter-\(name.filter(\.isLetter)).png"))
        }
        return rep
    }

    private func color(_ rep: NSBitmapImageRep, at point: NSPoint, in view: NSView) throws -> NSColor {
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        let raw = try XCTUnwrap(rep.colorAt(x: Int(point.x * scale), y: Int(point.y * scale)))
        return try XCTUnwrap(raw.usingColorSpace(.sRGB))
    }

    /// A point in the gap between two glyphs (the space after `index`), on its line's centre.
    private func spacePoint(after index: Int, in textView: LineformTextView) throws -> NSPoint {
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let container = try XCTUnwrap(textView.textContainer)
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        return NSPoint(x: rect.midX + textView.textContainerOrigin.x, y: rect.midY + textView.textContainerOrigin.y)
    }

    private func blueLift(_ color: NSColor) -> CGFloat { color.blueComponent - color.redComponent }

    func testSelectionIsAStrokeBehindTheTextAndNeverAnAttribute() throws {
        let textView = try laidOutTextView()
        let space = (sample as NSString).range(of: "the company").location + 3 // the space in "the company"
        let unselectedSpace = (sample as NSString).range(of: "to be").location + 2
        let before = try bitmap(of: textView)
        let pageBefore = try color(before, at: try spacePoint(after: space, in: textView), in: textView)

        let storageBefore = try XCTUnwrap(textView.textStorage).copy() as! NSAttributedString
        textView.setSelectedRange(NSRange(location: 0, length: 140))
        let after = try bitmap(of: textView)

        let selected = try color(after, at: try spacePoint(after: space, in: textView), in: textView)
        let unselected = try color(after, at: try spacePoint(after: unselectedSpace, in: textView), in: textView)
        XCTAssertGreaterThan(blueLift(selected), blueLift(pageBefore) + 0.05, "the selection must read as Lineform blue")
        XCTAssertEqual(blueLift(unselected), blueLift(pageBefore), accuracy: 0.01, "unselected text stays on the bare page")
        XCTAssertEqual(textView.textStorage, storageBefore, "the selection never touches the text storage")
    }

    func testStrokesAreDeterministicPerLine() throws {
        let textView = try laidOutTextView()
        textView.setSelectedRange(NSRange(location: 0, length: 140))
        let first = HighlighterSelectionDrawing.lines(for: textView.highlighterSelectionRanges, in: textView)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.setSelectedRange(NSRange(location: 0, length: 140))
        let second = HighlighterSelectionDrawing.lines(for: textView.highlighterSelectionRanges, in: textView)
        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.map { HighlighterSelection.path(for: $0).boundingBox }, second.map { HighlighterSelection.path(for: $0).boundingBox })
    }

    func testCollapsedSelectionDrawsNothing() throws {
        let textView = try laidOutTextView()
        textView.setSelectedRange(NSRange(location: 4, length: 0))
        XCTAssertTrue(HighlighterSelectionDrawing.lines(for: textView.highlighterSelectionRanges, in: textView).isEmpty)
    }

    func testDarkThemeUsesTheLighterBlue() throws {
        var profile = ReadingProfile.original
        profile.themeID = .quiet
        let textView = try laidOutTextView(profile: profile)
        let space = (sample as NSString).range(of: "the company").location + 3
        let page = try color(try bitmap(of: textView), at: try spacePoint(after: space, in: textView), in: textView)
        textView.setSelectedRange(NSRange(location: 0, length: 140))
        let selected = try color(try bitmap(of: textView), at: try spacePoint(after: space, in: textView), in: textView)
        XCTAssertGreaterThan(blueLift(selected), blueLift(page) + 0.08)
    }
}
