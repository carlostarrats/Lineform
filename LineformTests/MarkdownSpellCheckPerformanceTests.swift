import XCTest
@testable import Lineform

/// Guards the load-bearing performance constraint: the spell-check range computation runs as the
/// user types, so it must never acquire a whole-document pass.
///
/// **The gate is a RATIO, not a wall-clock ceiling.** It measures the scoped path and the
/// whole-document pass it must never become, back to back on the same machine in the same run, and
/// requires the scoped path to be several times faster. That is the actual invariant, and it keeps
/// its meaning on any hardware.
///
/// It used to assert an absolute 5 ms ceiling, which measured ~2.2 ms on a developer Mac and
/// 5.5–8.4 ms on a shared GitHub runner — so it failed roughly a third of CI runs with no
/// regression behind any of them. Raising the number would have traded a flaky gate for a blind
/// one; the ratio takes the hardware out of the question instead. Do not put a tight absolute
/// ceiling back.
///
/// **This test runs in DEBUG**, because the Release configuration carries the iCloud entitlement
/// and cannot be test-built without real signing. Debug measures roughly **3.6× slower** than the
/// optimized build that ships (measured 2026-07-26: the dominant prefix-scan loop takes 6.99 ms at
/// `-Onone` against 1.95 ms at `-O` for the same 730 KB input). Both sides of the ratio pay that
/// tax, which is a further reason the ratio is the honest measurement. Do not "fix" a Debug reading
/// by assuming it is what users feel.
///
/// See `docs/superpowers/specs/2026-07-26-live-spell-check-design.md` and
/// `docs/notes/2026-07-26-spell-check-probe-findings.md`.
final class MarkdownSpellCheckPerformanceTests: XCTestCase {

    /// The scoped path must be at least this many times faster than the whole-document pass.
    /// Measured 11.7× on a developer Mac (2.18 ms vs 25.45 ms), so this leaves a wide margin. The
    /// shape it exists to reject — the naive version that called the two whole-document passes —
    /// measured 14.97 ms against that same baseline, i.e. barely above 1×.
    private static let minimumSpeedup: Double = 4.0

    /// A loose sanity backstop for "everything got slower at once", which a ratio cannot see. It is
    /// deliberately far above any healthy reading (~2 ms locally, ~6 ms on a slow runner) — it is
    /// not the gate, and tightening it is what made this test flaky before.
    private static let backstopSeconds: TimeInterval = 0.030

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

    /// Best-of-batches, on a MONOTONIC clock. Scheduler preemption on a shared runner can only ever
    /// ADD time, so the minimum across batches is the cleanest estimate of true cost — a mean
    /// happily absorbs one descheduled batch and reports it as a regression, which is exactly how
    /// this test used to fail. `Date()` is wall-clock and can also step under NTP.
    private func bestPerCall(batches: Int, iterations: Int, _ body: () -> Void) -> TimeInterval {
        var best = TimeInterval.infinity
        for _ in 0..<batches {
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<iterations { body() }
            let elapsed = TimeInterval(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
            best = min(best, elapsed / TimeInterval(iterations))
        }
        return best
    }

    func testCheckableRangesStaysFarFasterThanAWholeDocumentPass() {
        let text = largeDocument()
        XCTAssertGreaterThan(text.length, 700 * 1024, "fixture must be large enough to be meaningful")

        // A realistic checked range: one paragraph deep in the document, which is the worst case
        // for the prefix walk that fence and math state require.
        let midpoint = text.length / 2
        let range = text.lineRange(for: NSRange(location: midpoint, length: 0))
        let highlighter = MarkdownSyntaxHighlighter()

        // Bridged once, outside the measurement: charging the baseline for an NSString→String
        // bridge on every call would flatter the ratio.
        let bridged = text as String

        // Warm up both sides, so one-time costs are not what gets measured.
        _ = MarkdownSpellCheckRegions.checkableRanges(in: text, enclosing: range, highlighter: highlighter)
        _ = MarkdownWritingToolsProtection.ignoredRanges(in: bridged, enclosingRange: range)

        let scoped = bestPerCall(batches: 5, iterations: 20) {
            _ = MarkdownSpellCheckRegions.checkableRanges(in: text, enclosing: range, highlighter: highlighter)
        }
        let wholeDocument = bestPerCall(batches: 3, iterations: 3) {
            _ = MarkdownWritingToolsProtection.ignoredRanges(in: bridged, enclosingRange: range)
        }
        let speedup = wholeDocument / scoped

        // Printed on success too: the numbers are the point, and a passing test that reports
        // nothing makes a slow drift toward the gate invisible.
        print(String(
            format: "[perf] checkableRanges %.3f ms/call vs whole-document %.3f ms/call — %.1f× faster on %d KB (floor %.1f×)",
            scoped * 1000, wholeDocument * 1000, speedup, text.length / 1024, Self.minimumSpeedup
        ))

        XCTAssertGreaterThan(
            speedup, Self.minimumSpeedup,
            """
            checkableRanges is only \(String(format: "%.1f", speedup))× faster than the \
            whole-document pass (floor \(Self.minimumSpeedup)×): \
            \(String(format: "%.3f", scoped * 1000)) ms vs \
            \(String(format: "%.3f", wholeDocument * 1000)) ms per call on a \
            \(text.length / 1024) KB document. This almost certainly means a whole-document pass \
            crept into the checking path — check for ignoredRanges(in:enclosingRange:) or \
            MarkdownRangeAnalyzer.ranges(in:).
            """
        )

        XCTAssertLessThan(
            scoped, Self.backstopSeconds,
            """
            checkableRanges took \(String(format: "%.3f", scoped * 1000)) ms per call on a \
            \(text.length / 1024) KB document, past the \(Self.backstopSeconds * 1000) ms backstop. \
            The ratio gate above is the real check; this one only fires when everything got slower \
            at once, which a ratio cannot see.
            """
        )
    }
}
