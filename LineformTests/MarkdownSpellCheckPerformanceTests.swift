import XCTest
@testable import Lineform

/// Guards the load-bearing performance constraint: the spell-check range computation runs as the
/// user types, so it must never acquire a whole-document pass. The ceiling is deliberately loose
/// — it is here to catch a regression of that KIND (an 18 ms whole-document pass at this size),
/// not to police microseconds on a busy CI runner.
///
/// **This test runs in DEBUG**, because the Release configuration carries the iCloud entitlement
/// and cannot be test-built without real signing. Debug measures roughly **3.6× slower** than
/// the optimized build that ships (measured 2026-07-26: the dominant prefix-scan loop takes
/// 6.99 ms at `-Onone` against 1.95 ms at `-O` for the same 730 KB input). So the 5 ms ceiling
/// here corresponds to roughly 1.4 ms in a shipping build — near the spec's ≤ 1 ms budget rather
/// than five times over it. Do not "fix" a Debug reading by assuming it is what users feel.
///
/// See `docs/superpowers/specs/2026-07-26-live-spell-check-design.md` and
/// `docs/notes/2026-07-26-spell-check-probe-findings.md`.
final class MarkdownSpellCheckPerformanceTests: XCTestCase {
    private static let ceilingSeconds: TimeInterval = 0.005

    private func largeDocument() -> NSString {
        var parts: [String] = ["---", "title: Large Fixture", "---", ""]
        var index = 0
        var size = 0
        while size < 730 * 1024 {
            index += 1
            let block: [String]
            switch index % 12 {
            case 0: block = ["```swift", "let isRichText = false", "func doThing() {}", "```", ""]
            case 5: block = ["$$", "a = b", "$$", ""]
            case 7: block = ["See [the docs](/Users/qa/notes/file-\(index).md) and `NSTextView`.", ""]
            case 9: block = ["## Section \(index)", ""]
            default: block = ["the quick brown fox jumps over the lazy dog writing calm markdown", ""]
            }
            parts += block
            size += block.reduce(0) { $0 + $1.count + 1 }
        }
        return parts.joined(separator: "\n") as NSString
    }

    func testCheckableRangesStaysFastOnALargeDocument() {
        let text = largeDocument()
        XCTAssertGreaterThan(text.length, 700 * 1024, "fixture must be large enough to be meaningful")

        // A realistic checked range: one paragraph deep in the document, which is the worst case
        // for the prefix walk that fence and math state require.
        let midpoint = text.length / 2
        let range = text.lineRange(for: NSRange(location: midpoint, length: 0))
        let highlighter = MarkdownSyntaxHighlighter()

        // Warm up, so one-time costs are not what gets measured.
        _ = MarkdownSpellCheckRegions.checkableRanges(in: text, enclosing: range, highlighter: highlighter)

        let iterations = 20
        let start = Date()
        for _ in 0..<iterations {
            _ = MarkdownSpellCheckRegions.checkableRanges(in: text, enclosing: range, highlighter: highlighter)
        }
        let perCall = Date().timeIntervalSince(start) / Double(iterations)

        // Printed on success too: the number is the point, and a passing test that reports
        // nothing makes a slow drift toward the ceiling invisible.
        print(String(
            format: "[perf] checkableRanges %.3f ms/call on %d KB (ceiling %.0f ms)",
            perCall * 1000, text.length / 1024, Self.ceilingSeconds * 1000
        ))

        XCTAssertLessThan(
            perCall, Self.ceilingSeconds,
            """
            checkableRanges took \(String(format: "%.3f", perCall * 1000)) ms per call on a \
            \(text.length / 1024) KB document (ceiling \(Self.ceilingSeconds * 1000) ms). \
            This almost certainly means a whole-document pass crept into the checking path — \
            check for ignoredRanges(in:enclosingRange:) or MarkdownRangeAnalyzer.ranges(in:).
            """
        )
    }
}
