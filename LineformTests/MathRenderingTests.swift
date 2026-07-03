import XCTest
import AppKit
@testable import Lineform

final class MathRenderingTests: XCTestCase {
    // MARK: - Block fence

    func testBlockDelimiterOnly() {
        XCTAssertTrue(MathBlockFence.blockDelimiterOnly("$$"))
        XCTAssertTrue(MathBlockFence.blockDelimiterOnly("  $$  "))
        XCTAssertFalse(MathBlockFence.blockDelimiterOnly("$"))
        XCTAssertFalse(MathBlockFence.blockDelimiterOnly("$$x"))
    }

    func testSingleLineBlock() {
        XCTAssertEqual(MathBlockFence.singleLineBlock("$$x^2$$"), "x^2")
        XCTAssertEqual(MathBlockFence.singleLineBlock("$$ E=mc^2 $$"), " E=mc^2 ")
        XCTAssertNil(MathBlockFence.singleLineBlock("$$"))
        XCTAssertNil(MathBlockFence.singleLineBlock("$x$"))
        // Two display spans with prose between must NOT be treated as one block (would swallow "and").
        XCTAssertNil(MathBlockFence.singleLineBlock("$$a$$ and $$b$$"))
    }

    // MARK: - Inline delimiter rules

    private func mathValues(_ line: String) -> [String] {
        MathDelimiters.inlineSpans(in: line).map(\.latex)
    }
    private func styles(_ line: String) -> [MathStyle] {
        MathDelimiters.inlineSpans(in: line).map(\.style)
    }

    func testSimpleInlineMath() {
        XCTAssertEqual(mathValues("the value $x^2$ here"), ["x^2"])
    }
    func testDigitLeadingMathRenders() {
        // The opener may precede a digit; only the closing side guards against prose.
        XCTAssertEqual(mathValues("the value $2\\pi r$ here"), ["2\\pi r"])
        XCTAssertEqual(mathValues("so $1+1=2$ holds"), ["1+1=2"])
    }
    func testProseDigitDollarsAreLiteral() {
        XCTAssertEqual(mathValues("it costs $5 to $10 today"), [])
        XCTAssertEqual(mathValues("$5+$6 total"), [])            // closer followed by digit → literal
    }
    func testOpeningDollarFollowedBySpaceIsProse() {
        XCTAssertEqual(mathValues("give me $ 5 and $ 6"), [])
    }
    func testClosingDollarPrecededBySpaceIsProse() {
        // Whitespace immediately before the closing `$` disqualifies it (internal spaces are fine).
        XCTAssertEqual(mathValues("a $x^2 $ b"), [])
    }
    func testInternalSpacesAreAllowedInMath() {
        XCTAssertEqual(mathValues("a $x + y$ b"), ["x + y"])
    }
    func testEscapedDollarIsLiteral() {
        XCTAssertEqual(mathValues(#"a \$5 and \$6 b"#), [])
    }
    func testUnbalancedDollarStaysLiteral() {
        XCTAssertEqual(mathValues("a single $ here"), [])
    }
    func testTwoInlineExpressions() {
        XCTAssertEqual(mathValues("$a+b$ and $c-d$"), ["a+b", "c-d"])
    }
    func testMidLineDisplayMathIsOneSpan() {
        // `$$…$$` embedded in prose is a single display span — no stray `$` left over.
        XCTAssertEqual(mathValues("the famous $$E=mc^2$$ equation"), ["E=mc^2"])
        XCTAssertEqual(styles("the famous $$E=mc^2$$ equation"), [.display])
    }
    func testInlineSpanRangeCoversDelimiters() {
        let spans = MathDelimiters.inlineSpans(in: "ab $x$ cd")
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans.first?.range, NSRange(location: 3, length: 3))   // "$x$"
    }

    // MARK: - Provider policy / cache

    func testMathSizeGuardBoundary() {
        XCTAssertTrue(MathBlockPolicy.shouldAttemptRender(source: String(repeating: "a", count: 20_000)))
        XCTAssertFalse(MathBlockPolicy.shouldAttemptRender(source: String(repeating: "a", count: 20_001)))
    }
    func testMathCacheKeyStableAndDistinct() {
        let a = MathCacheKey.key(latex: "x^2", style: .inline, foregroundHex: "#ffffff", scale: 2)
        XCTAssertEqual(a, MathCacheKey.key(latex: "x^2", style: .inline, foregroundHex: "#ffffff", scale: 2))
        XCTAssertNotEqual(a, MathCacheKey.key(latex: "x^3", style: .inline, foregroundHex: "#ffffff", scale: 2))
        XCTAssertNotEqual(a, MathCacheKey.key(latex: "x^2", style: .display, foregroundHex: "#ffffff", scale: 2))
        XCTAssertNotEqual(a, MathCacheKey.key(latex: "x^2", style: .inline, foregroundHex: "#000000", scale: 2))
        XCTAssertNotEqual(a, MathCacheKey.key(latex: "x^2", style: .inline, foregroundHex: "#ffffff", scale: 1))
    }
    func testDisabledProviderSkips() {
        let outcome = DisabledMathImageProvider().outcome(latex: "x^2", style: .inline, foreground: .white, pointSize: 18, scale: 2)
        if case .skipped = outcome {} else { XCTFail("disabled provider must skip") }
    }

    // MARK: - Live SwiftMath smoke tests

    func testLiveProviderRendersNonEmptyImage() {
        let outcome = MathImageProvider().outcome(latex: "x^2+y^2", style: .display, foreground: .black, pointSize: 18, scale: 2)
        guard case .image(let image, _) = outcome else { return XCTFail("expected an image, got \(outcome)") }
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
    }
    func testLiveProviderReportsDescentForInlineMath() {
        // A fraction has real depth below the baseline, so descent must be positive.
        let outcome = MathImageProvider().outcome(latex: "\\frac{a}{b}", style: .inline, foreground: .black, pointSize: 18, scale: 2)
        guard case .image(_, let descent) = outcome else { return XCTFail("expected an image") }
        XCTAssertGreaterThan(descent, 0)
    }
    func testLiveProviderFailsOnGarbageLaTeX() {
        let outcome = MathImageProvider().outcome(latex: "\\frac{", style: .inline, foreground: .black, pointSize: 18, scale: 2)
        if case .failed = outcome {} else { XCTFail("malformed LaTeX must fail → fallback") }
    }
}
