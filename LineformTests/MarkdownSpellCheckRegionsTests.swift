import XCTest
@testable import Lineform

final class MarkdownSpellCheckRegionsTests: XCTestCase {
    private func checkableText(_ source: String) -> [String] {
        let text = source as NSString
        let full = NSRange(location: 0, length: text.length)
        return MarkdownSpellCheckRegions
            .checkableRanges(in: text, enclosing: full)
            .map { text.substring(with: $0) }
    }

    func testPlainProseIsFullyCheckable() {
        let text = "the quick brown fox" as NSString
        let full = NSRange(location: 0, length: text.length)
        XCTAssertEqual(MarkdownSpellCheckRegions.checkableRanges(in: text, enclosing: full), [full])
    }

    func testInlineCodeIsExcludedButSurroundingProseIsKept() {
        let joined = checkableText("Set `isRichText` to false befor shipping").joined()
        XCTAssertFalse(joined.contains("isRichText"), "inline code must not be checked")
        XCTAssertTrue(joined.contains("befor"), "prose around inline code must still be checked")
    }

    func testFencedCodeIsExcluded() {
        let joined = checkableText("prose one\n```swift\nlet teh = 1\n```\nprose two").joined()
        XCTAssertFalse(joined.contains("let teh"))
        XCTAssertTrue(joined.contains("prose one"))
        XCTAssertTrue(joined.contains("prose two"))
    }

    func testFrontMatterIsExcluded() {
        let joined = checkableText("---\ntitle: teh\n---\nprose here").joined()
        XCTAssertFalse(joined.contains("title: teh"))
        XCTAssertTrue(joined.contains("prose here"))
    }

    func testDisplayMathIsExcluded() {
        let joined = checkableText("prose\n$$\nx = y\n$$\nmore prose").joined()
        XCTAssertFalse(joined.contains("x = y"))
        XCTAssertTrue(joined.contains("more prose"))
    }

    func testLinkTextIsCheckedButDestinationIsNot() {
        let joined = checkableText("See [teh docs](/Users/qa/somefile.md) now").joined()
        XCTAssertTrue(joined.contains("teh docs"), "link TEXT is prose and must be checked")
        XCTAssertFalse(joined.contains("/Users/qa/somefile.md"), "link destination must not be checked")
    }

    func testImageDestinationIsNotChecked() {
        let joined = checkableText("![alt teh](/Users/qa/img-pth.png) after").joined()
        XCTAssertFalse(joined.contains("/Users/qa/img-pth.png"))
        XCTAssertTrue(joined.contains("after"))
    }

    func testResultRangesAreOrderedNonEmptyAndNonOverlapping() {
        let text = "a `b` c `d` e\n```\nf\n```\ng [h](/i) j" as NSString
        let ranges = MarkdownSpellCheckRegions
            .checkableRanges(in: text, enclosing: NSRange(location: 0, length: text.length))
        for range in ranges {
            XCTAssertGreaterThan(range.length, 0, "zero-length range emitted")
        }
        for (lhs, rhs) in zip(ranges, ranges.dropFirst()) {
            XCTAssertLessThanOrEqual(NSMaxRange(lhs), rhs.location, "ranges overlap or are unsorted")
        }
    }

    func testEnclosingRangeIsRespected() {
        let text = "aaaa `bb` cccc" as NSString
        let enclosing = NSRange(location: 0, length: 4)
        let ranges = MarkdownSpellCheckRegions.checkableRanges(in: text, enclosing: enclosing)
        XCTAssertEqual(ranges, [enclosing], "must never return anything outside the enclosing range")
    }

    func testEmptyAndOutOfBoundsRangesAreSafe() {
        let text = "hello" as NSString
        XCTAssertTrue(MarkdownSpellCheckRegions
            .checkableRanges(in: text, enclosing: NSRange(location: 0, length: 0)).isEmpty)
        XCTAssertTrue(MarkdownSpellCheckRegions
            .checkableRanges(in: "" as NSString, enclosing: NSRange(location: 0, length: 0)).isEmpty)
        XCTAssertEqual(
            MarkdownSpellCheckRegions.checkableRanges(in: text, enclosing: NSRange(location: 0, length: 999)),
            [NSRange(location: 0, length: 5)],
            "an over-long enclosing range must clamp, not crash"
        )
    }

    /// Guards the line-local invariant: a scoped computation must agree with the whole-document
    /// one, clipped. Mirrors the scoped-highlighting equivalence test.
    func testScopedResultMatchesWholeDocumentClipped() {
        let text = """
        ---
        title: Doc
        ---
        prose one `code` tail
        ```swift
        let a = 1
        ```
        prose two [link](/a/b) end
        $$
        a = b
        $$
        prose three $x+y$ done
        """ as NSString
        let full = NSRange(location: 0, length: text.length)
        let whole = MarkdownSpellCheckRegions.checkableRanges(in: text, enclosing: full)

        var scope = NSRange(location: 0, length: 0)
        while scope.location < text.length {
            scope = text.lineRange(for: NSRange(location: scope.location, length: 0))
            let scoped = MarkdownSpellCheckRegions.checkableRanges(in: text, enclosing: scope)
            let expected = whole.map { NSIntersectionRange($0, scope) }.filter { $0.length > 0 }
            XCTAssertEqual(
                scoped, expected,
                "scoped diverged from whole-document at \(NSStringFromRange(scope))"
            )
            scope.location = NSMaxRange(scope)
        }
    }
}
