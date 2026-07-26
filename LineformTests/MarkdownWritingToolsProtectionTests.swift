import XCTest
@testable import Lineform

final class MarkdownWritingToolsProtectionTests: XCTestCase {
    func testProtectsYamlFrontMatterAtStartOfDocument() {
        let text = "---\ntitle: Draft\n---\n\nBody"

        let ranges = MarkdownWritingToolsProtection.ignoredRanges(in: text, enclosingRange: NSRange(location: 0, length: (text as NSString).length))

        XCTAssertEqual(ranges.first, NSRange(location: 0, length: 21))
    }

    func testProtectsEmptyYamlFrontMatterDelimiters() {
        let text = "---\n---\n\nBody"

        let ranges = MarkdownWritingToolsProtection.ignoredRanges(in: text, enclosingRange: NSRange(location: 0, length: (text as NSString).length))

        XCTAssertEqual(ranges.first, NSRange(location: 0, length: 8))
    }

    func testProtectsFencedCodeBlocks() {
        let text = "Body\n```swift\nlet value = 1\n```\nMore"

        let ranges = MarkdownWritingToolsProtection.ignoredRanges(in: text, enclosingRange: NSRange(location: 0, length: (text as NSString).length))

        XCTAssertEqual(ranges, [NSRange(location: 5, length: 27)])
    }

    func testClipsIgnoredRangesToEnclosingRange() {
        let text = "Body\n```swift\nlet value = 1\n```\nMore"

        let ranges = MarkdownWritingToolsProtection.ignoredRanges(in: text, enclosingRange: NSRange(location: 10, length: 10))

        XCTAssertEqual(ranges, [NSRange(location: 10, length: 10)])
    }

    // MARK: - Math regions

    private func protects(_ text: String, substring: String) -> Bool {
        let full = NSRange(location: 0, length: (text as NSString).length)
        let ranges = MarkdownWritingToolsProtection.ignoredRanges(in: text, enclosingRange: full)
        let target = (text as NSString).range(of: substring)
        guard target.location != NSNotFound else { return false }
        return ranges.contains { NSIntersectionRange($0, target).length == target.length }
    }

    func testInlineMathIsProtected() {
        XCTAssertTrue(protects("the value $x^2$ here", substring: "$x^2$"))
    }

    func testBlockMathIsProtected() {
        XCTAssertTrue(protects("intro\n$$\nx^2\n$$\nend", substring: "$$\nx^2\n$$"))
    }

    func testSingleLineBlockMathIsProtected() {
        XCTAssertTrue(protects("a\n$$E=mc^2$$\nb", substring: "$$E=mc^2$$"))
    }

    func testProseDollarsAreNotProtected() {
        XCTAssertFalse(protects("it costs $5 to $10", substring: "$5 to $10"))
    }

    func testDollarInsideCodeFenceDoesNotOverProtectTrailingText() {
        // A bare `$$` inside a code fence must not open a phantom math block that swallows the
        // rest of the document. The trailing prose must remain editable by Writing Tools.
        let text = "```\n$$\n```\nplain prose after the fence"
        let full = NSRange(location: 0, length: (text as NSString).length)
        let ranges = MarkdownWritingToolsProtection.ignoredRanges(in: text, enclosingRange: full)
        let prose = (text as NSString).range(of: "plain prose after the fence")
        XCTAssertFalse(ranges.contains { NSIntersectionRange($0, prose).length > 0 },
                       "trailing prose must not be protected by a phantom math block")
    }

    // MARK: - isInsideCodeOrFrontMatter

    // The per-Return cheap path used by list continuation. Kept in lockstep with the fence
    // rules above: both answer "is this position really Markdown?", from the same file.

    func testInsideCodeOrFrontMatterDetectsAnOpenFence() {
        let text = "```\n- milk"
        XCTAssertTrue(MarkdownWritingToolsProtection.isInsideCodeOrFrontMatter(location: 4, in: text))
    }

    func testInsideCodeOrFrontMatterDetectsAClosedFence() {
        let text = "```\n- milk\n```"
        XCTAssertTrue(MarkdownWritingToolsProtection.isInsideCodeOrFrontMatter(location: 4, in: text))
    }

    func testInsideCodeOrFrontMatterIsFalseAfterAClosedFence() {
        let text = "```\ncode\n```\n- milk"
        XCTAssertFalse(MarkdownWritingToolsProtection.isInsideCodeOrFrontMatter(location: 13, in: text))
    }

    func testInsideCodeOrFrontMatterHandlesTildeFences() {
        let text = "~~~\n- milk"
        XCTAssertTrue(MarkdownWritingToolsProtection.isInsideCodeOrFrontMatter(location: 4, in: text))
    }

    func testInsideCodeOrFrontMatterIgnoresAMismatchedFenceMarker() {
        // A ``` block is not closed by ~~~, so the position stays inside code.
        let text = "```\n~~~\n- milk"
        XCTAssertTrue(MarkdownWritingToolsProtection.isInsideCodeOrFrontMatter(location: 8, in: text))
    }

    func testInsideCodeOrFrontMatterDetectsFrontMatter() {
        let text = "---\n- a\n---\nBody"
        XCTAssertTrue(MarkdownWritingToolsProtection.isInsideCodeOrFrontMatter(location: 4, in: text))
    }

    func testInsideCodeOrFrontMatterIsFalseAfterFrontMatter() {
        let text = "---\ntitle: x\n---\n- item"
        XCTAssertFalse(MarkdownWritingToolsProtection.isInsideCodeOrFrontMatter(location: 17, in: text))
    }

    func testInsideCodeOrFrontMatterIsFalseInPlainProse() {
        XCTAssertFalse(MarkdownWritingToolsProtection.isInsideCodeOrFrontMatter(location: 3, in: "hello world"))
    }

    func testInsideCodeOrFrontMatterToleratesOutOfBoundsLocations() {
        XCTAssertFalse(MarkdownWritingToolsProtection.isInsideCodeOrFrontMatter(location: 999, in: "hello"))
        XCTAssertFalse(MarkdownWritingToolsProtection.isInsideCodeOrFrontMatter(location: -1, in: "hello"))
    }

    func testInsideCodeOrFrontMatterMatchesIgnoredRangesForAnIndentedFence() {
        let text = "  ```\n- milk\n  ```"
        XCTAssertTrue(MarkdownWritingToolsProtection.isInsideCodeOrFrontMatter(location: 6, in: text))
    }

    // MARK: - Scoped block regions (live spell check)

    func testScopedProtectedRangesFindsFenceOpenedBeforeScope() {
        let text = "```swift\nlet a = 1\nlet b = 2\n```\nprose here\n" as NSString
        let scope = text.range(of: "let b")
        let ranges = MarkdownWritingToolsProtection.protectedRanges(in: text, intersecting: scope)
        XCTAssertEqual(ranges, [scope], "a fence opened before the scope must still protect inside it")
    }

    func testScopedProtectedRangesExcludesProseOutsideFence() {
        let text = "```\ncode\n```\nprose here\n" as NSString
        let scope = text.range(of: "prose")
        let ranges = MarkdownWritingToolsProtection.protectedRanges(in: text, intersecting: scope)
        XCTAssertTrue(ranges.isEmpty, "prose after a closed fence is not protected")
    }

    func testScopedProtectedRangesCoversFrontMatter() {
        let text = "---\ntitle: teh\n---\nprose\n" as NSString
        let scope = text.range(of: "title: teh")
        let ranges = MarkdownWritingToolsProtection.protectedRanges(in: text, intersecting: scope)
        XCTAssertEqual(ranges, [scope])
    }

    func testScopedProtectedRangesCoversDisplayMathOpenedBeforeScope() {
        let text = "prose\n$$\nx = y\n$$\nmore\n" as NSString
        let scope = text.range(of: "x = y")
        let ranges = MarkdownWritingToolsProtection.protectedRanges(in: text, intersecting: scope)
        XCTAssertEqual(ranges, [scope])
    }

    func testScopedProtectedRangesIsEmptyForAnEmptyScope() {
        let text = "```\ncode\n```\n" as NSString
        XCTAssertTrue(MarkdownWritingToolsProtection
            .protectedRanges(in: text, intersecting: NSRange(location: 0, length: 0)).isEmpty)
    }

    /// The equivalence that makes the scoped path safe to substitute for the whole-document one.
    func testScopedProtectedRangesMatchesWholeDocumentIntersection() {
        let text = """
        ---
        title: Doc
        ---
        prose one $x+y$ tail
        ```swift
        let a = 1
        ```
        prose two
        $$
        a = b
        $$
        prose three with $5 in it
        """ as NSString
        let full = NSRange(location: 0, length: text.length)

        var scope = NSRange(location: 0, length: 0)
        while scope.location < text.length {
            scope = text.lineRange(for: NSRange(location: scope.location, length: 0))
            let scoped = MarkdownWritingToolsProtection.protectedRanges(in: text, intersecting: scope)
            let expected = MarkdownWritingToolsProtection
                .ignoredRanges(in: text as String, enclosingRange: full)
                .map { NSIntersectionRange($0, scope) }
                .filter { $0.length > 0 }
            XCTAssertEqual(
                normalizedRanges(scoped), normalizedRanges(expected),
                "scoped result diverged from the whole-document pass at \(NSStringFromRange(scope))"
            )
            scope.location = NSMaxRange(scope)
        }
    }

    /// Merges touching/overlapping ranges so the two paths compare on coverage, not on how
    /// each happened to split it.
    private func normalizedRanges(_ ranges: [NSRange]) -> [NSRange] {
        let sorted = ranges.filter { $0.length > 0 }.sorted { $0.location < $1.location }
        var merged: [NSRange] = []
        for range in sorted {
            if let last = merged.last, range.location <= NSMaxRange(last) {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}
