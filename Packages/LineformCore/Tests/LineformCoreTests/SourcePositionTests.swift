import XCTest
@testable import LineformCore

/// `SourcePosition`: the rendered ↔ source lookups over `.sourceSpan` that the Mac's
/// `MarkdownPreviewTextView` and the iPhone Read view share.
@MainActor
final class SourcePositionTests: XCTestCase {
    private func corpus() throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "corpus", withExtension: "md", subdirectory: "render-corpus"),
            "render-corpus/corpus.md missing from the test bundle"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func render(_ text: String) -> NSAttributedString {
        MarkdownPreviewRenderer().render(
            text,
            profile: .original,
            columnWidth: 680,
            mermaidProvider: DisabledMermaidImageProvider(),
            mathProvider: DisabledMathImageProvider(),
            diagramLog: NullDiagramFailureLog(),
            appVersion: "0",
            displayMetrics: RenderDisplayMetrics(scale: 2, visibleViewportHeight: 800)
        )
    }

    /// Every distinct source-span start in the render.
    private func spanStarts(in rendered: NSAttributedString) -> [Int] {
        var starts: Set<Int> = []
        rendered.enumerateAttribute(.sourceSpan, in: NSRange(location: 0, length: rendered.length)) { value, _, _ in
            if let value = value as? NSValue { starts.insert(value.rangeValue.location) }
        }
        return starts.sorted()
    }

    func testRoundTripThroughSourceSpan() throws {
        let text = try corpus()
        // LF, and the same corpus as CRLF: the spans come from the one splitter, so the `\r` is
        // counted and the round trip still lands on each block's own offset.
        for document in [text, text.replacingOccurrences(of: "\n", with: "\r\n")] {
            let rendered = render(document)
            let starts = spanStarts(in: rendered)
            XCTAssertGreaterThan(starts.count, 20, "the corpus renders many blocks")
            for start in starts {
                let renderedIndex = try XCTUnwrap(SourcePosition.renderedIndex(forSourceLocation: start, in: rendered))
                XCTAssertEqual(
                    SourcePosition.sourceLocation(atRenderedIndex: renderedIndex, in: rendered), start,
                    "block at source \(start) round-trips through rendered \(renderedIndex)"
                )
            }
        }
    }

    func testOffsetClampedToSpanLength() {
        // A ten-character rendered run that stands for a three-character source span (a block
        // whose rendering is longer than its source).
        let rendered = NSMutableAttributedString(string: "abcdefghij")
        rendered.addAttribute(.sourceSpan, value: NSValue(range: NSRange(location: 100, length: 3)),
                              range: NSRange(location: 0, length: 10))

        XCTAssertEqual(SourcePosition.sourceLocation(atRenderedIndex: 1, in: rendered), 101)
        XCTAssertEqual(SourcePosition.sourceLocation(atRenderedIndex: 8, in: rendered), 102,
                       "the offset never runs past the span")
        XCTAssertEqual(SourcePosition.sourceLocation(atRenderedIndex: 99, in: rendered), 102,
                       "an index past the end is clamped into the string")

        XCTAssertEqual(SourcePosition.renderedIndex(forSourceLocation: 101, in: rendered), 1)
        XCTAssertEqual(SourcePosition.renderedIndex(forSourceLocation: 150, in: rendered), 9,
                       "a target past the run stays on its last character")

        // A run with no span of its own takes the nearest tagged run before it, still measuring
        // the offset from that run's start and clamping it to its span (the Mac's rule).
        let mixed = NSMutableAttributedString(string: "abcXYZ")
        mixed.addAttribute(.sourceSpan, value: NSValue(range: NSRange(location: 40, length: 3)),
                           range: NSRange(location: 0, length: 3))
        XCTAssertEqual(SourcePosition.sourceLocation(atRenderedIndex: 4, in: mixed), 42)

        XCTAssertNil(SourcePosition.sourceLocation(atRenderedIndex: 0, in: NSAttributedString()))
        XCTAssertNil(SourcePosition.renderedIndex(forSourceLocation: 0, in: NSAttributedString()))
    }

    /// A position before the first span belongs to the first block. Rendered → source: the top
    /// character of a BOM'd file reports the first span's start (1, past the BOM). Source →
    /// rendered: no span starts at or before offset 0, so the lookup is nil and the caller shows
    /// the very top, where the first block is (the Mac's rule, kept unchanged).
    func testLocationBeforeFirstSpanReturnsFirst() {
        let rendered = render("\u{FEFF}# Title\nBody text")
        XCTAssertEqual(spanStarts(in: rendered).first, 1, "the BOM is not part of line 1's span")

        XCTAssertEqual(SourcePosition.sourceLocation(atRenderedIndex: 0, in: rendered), 1)
        XCTAssertNil(SourcePosition.renderedIndex(forSourceLocation: 0, in: rendered))
        XCTAssertEqual(SourcePosition.renderedIndex(forSourceLocation: 1, in: rendered), 0)

        // Untagged text before the first tagged run has no source position.
        let leading = NSMutableAttributedString(string: "--abc")
        leading.addAttribute(.sourceSpan, value: NSValue(range: NSRange(location: 7, length: 3)),
                             range: NSRange(location: 2, length: 3))
        XCTAssertNil(SourcePosition.sourceLocation(atRenderedIndex: 0, in: leading))
        XCTAssertEqual(SourcePosition.renderedIndex(forSourceLocation: 7, in: leading), 2)
    }
}
