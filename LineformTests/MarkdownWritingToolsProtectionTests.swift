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

    // MARK: - CRLF line endings

    /// Lines are split on `\n`, so a CRLF file's lines end in `\r` — and `.whitespaces` does not
    /// trim it. Before this, a Windows-authored file's front matter never opened and its `$$`
    /// never read as a block delimiter, leaving YAML and math unprotected: Writing Tools could
    /// rewrite them, the spell checker flagged them, and ⌘1 inside front matter prepended a
    /// heading marker to a YAML key.
    func testFrontMatterIsProtectedWithCRLFLineEndings() {
        let text = "---\r\ntitle: Notes\r\n---\r\n\r\nBody\r\n"
        let ranges = MarkdownWritingToolsProtection.ignoredRanges(
            in: text,
            enclosingRange: NSRange(location: 0, length: (text as NSString).length)
        )
        let yaml = (text as NSString).range(of: "title: Notes")
        XCTAssertTrue(
            ranges.contains { NSIntersectionRange($0, yaml).length == yaml.length },
            "CRLF front matter must be protected: \(ranges)"
        )
    }

    func testMathBlockIsProtectedWithCRLFLineEndings() {
        let text = "intro\r\n$$\r\nx = 1\r\n$$\r\nafter\r\n"
        let ranges = MarkdownWritingToolsProtection.ignoredRanges(
            in: text,
            enclosingRange: NSRange(location: 0, length: (text as NSString).length)
        )
        let body = (text as NSString).range(of: "x = 1")
        XCTAssertTrue(
            ranges.contains { NSIntersectionRange($0, body).length == body.length },
            "a CRLF $$ block must be protected: \(ranges)"
        )
    }

    /// The scoped walk and the whole-document pass classify lines through two different
    /// implementations that must agree; CRLF is exactly the kind of input that splits them.
    func testScopedAndWholeDocumentPassesAgreeOnCRLF() {
        let text = "---\r\ntitle: x\r\n---\r\n\r\n$$\r\ny\r\n$$\r\n```swift\r\ncode\r\n```\r\ntail\r\n"
        let full = NSRange(location: 0, length: (text as NSString).length)
        let whole = MarkdownWritingToolsProtection.ignoredRanges(in: text, enclosingRange: full)
        let scoped = MarkdownWritingToolsProtection.protectedRanges(in: text as NSString, intersecting: full)
        func normalize(_ ranges: [NSRange]) -> [NSRange] {
            ranges.filter { $0.length > 0 }.sorted { $0.location < $1.location }
        }
        XCTAssertEqual(normalize(whole), normalize(scoped))
    }

    /// The end-to-end consequence: a heading command must leave a CRLF file's YAML alone.
    func testHeadingCommandLeavesCRLFFrontMatterAlone() {
        let text = "---\r\ntitle: Notes\r\n---\r\n\r\nBody\r\n"
        let caret = (text as NSString).range(of: "title: Notes").location
        XCTAssertNil(
            MarkdownHeadingEditing.setLevel(1, in: text, selectedRange: NSRange(location: caret, length: 0)),
            "⌘1 inside CRLF front matter must be a no-op, not `# title: Notes`"
        )
    }

    // MARK: - Fence agreement probes

    /// Markdown-about-markdown: a 4-backtick fence wrapping 3-backtick fences. The renderer
    /// (`MermaidFence`) keeps the whole thing as ONE code block, so every other surface must too.
    private static let nestedFenceDocument = """
    ````markdown
    ```swift
    let notAWord = qqzzxx
    ```
    ````

    Prose.
    """

    /// A ``` block whose body contains a `~~~` line.
    private static let mixedMarkerDocument = """
    ```text
    ~~~
    qqzzxx
    ```

    Prose.
    """

    private func range(of needle: String, in text: String) -> NSRange {
        (text as NSString).range(of: needle)
    }

    private func fullyCovered(_ ranges: [NSRange], _ range: NSRange) -> Bool {
        ranges.contains { NSIntersectionRange($0, range).length == range.length }
    }

    private func protectedRanges(in text: String) -> [NSRange] {
        MarkdownWritingToolsProtection.ignoredRanges(
            in: text,
            enclosingRange: NSRange(location: 0, length: (text as NSString).length)
        )
    }

    func testProtectionCoversBodyOfNestedBacktickFence() {
        let text = Self.nestedFenceDocument
        XCTAssertTrue(
            fullyCovered(protectedRanges(in: text), range(of: "let notAWord = qqzzxx", in: text)),
            "an inner ``` must not close a ```` fence"
        )
    }

    func testProtectionCoversBodyWhenFenceContainsOtherMarker() {
        let text = Self.mixedMarkerDocument
        XCTAssertTrue(
            fullyCovered(protectedRanges(in: text), range(of: "qqzzxx", in: text)),
            "a ~~~ line must not close a ``` fence"
        )
    }

    func testProtectionEndsWithTheFenceRatherThanRunningToEndOfDocument() {
        let text = Self.nestedFenceDocument
        XCTAssertFalse(
            protectedRanges(in: text).contains {
                NSIntersectionRange($0, range(of: "Prose.", in: text)).length > 0
            },
            "prose after the closing fence must stay unprotected"
        )
    }

    func testIsInsideCodeAgreesWithProtectionForNestedFence() {
        let text = Self.nestedFenceDocument
        XCTAssertTrue(
            MarkdownWritingToolsProtection.isInsideCodeOrFrontMatter(
                location: range(of: "let notAWord = qqzzxx", in: text).location,
                in: text
            ),
            "the per-keystroke check must agree with the whole-document pass"
        )
        XCTAssertFalse(
            MarkdownWritingToolsProtection.isInsideCodeOrFrontMatter(
                location: range(of: "Prose.", in: text).location,
                in: text
            ),
            "the document must not be left permanently inside a fence"
        )
    }

    func testIsInsideCodeAgreesWithProtectionForMixedMarkers() {
        let text = Self.mixedMarkerDocument
        XCTAssertTrue(
            MarkdownWritingToolsProtection.isInsideCodeOrFrontMatter(
                location: range(of: "qqzzxx", in: text).location,
                in: text
            ),
            "a ~~~ line must not close a ``` fence for the per-keystroke check"
        )
    }

    func testSpellCheckSkipsBodyOfNestedFence() {
        let text = Self.nestedFenceDocument
        let body = range(of: "let notAWord = qqzzxx", in: text)
        let regions = MarkdownSpellCheckRegions.checkableRanges(
            in: text as NSString,
            enclosing: NSRange(location: 0, length: (text as NSString).length)
        )
        XCTAssertFalse(
            regions.contains { NSIntersectionRange($0, body).length > 0 },
            "spell check must not run inside a ```` fence"
        )
    }

    /// The scoped walk classifies fences by reading UTF-16 units (`fenceRun`); the whole-document
    /// pass calls `MermaidFence`, which is the renderer's definition. This pins the two together
    /// on the shapes where a first-three-characters comparison used to disagree.
    func testFenceClassificationMatchesTheRenderer() {
        let documents = [
            Self.nestedFenceDocument,
            Self.mixedMarkerDocument,
            "````\n```\n$x$\n```\n````\n",
            "```\ncode\n````\nstill code\n```\n",
            "~~~~\n~~~\nbody\n~~~\n~~~~\n",
            "``` swift\nlet x = 1\n```   \nafter\n",
            "```\nunclosed\n``\n",
            "````markdown\r\n```\r\ncode\r\n```\r\n````\r\nProse.\r\n",
        ]
        for text in documents {
            let full = NSRange(location: 0, length: (text as NSString).length)
            func normalize(_ ranges: [NSRange]) -> [NSRange] {
                ranges.filter { $0.length > 0 }.sorted { $0.location < $1.location }
            }
            XCTAssertEqual(
                normalize(MarkdownWritingToolsProtection.ignoredRanges(in: text, enclosingRange: full)),
                normalize(MarkdownWritingToolsProtection.protectedRanges(in: text as NSString, intersecting: full)),
                "scoped and whole-document passes disagree on \(text.debugDescription)"
            )
        }
    }

    /// `isInsideCodeOrFrontMatter` is a third implementation of the same question. It must answer
    /// like the whole-document pass at every offset, or a per-keystroke edit and the renderer
    /// disagree about whether the caret is in code.
    func testIsInsideCodeMatchesProtectedRangesAtEveryOffset() {
        for text in [Self.nestedFenceDocument, Self.mixedMarkerDocument] {
            let nsText = text as NSString
            let fenced = MarkdownWritingToolsProtection.ignoredRanges(
                in: text,
                enclosingRange: NSRange(location: 0, length: nsText.length)
            )
            for location in 0...nsText.length {
                // Compare only on the fenced-code question: `ignoredRanges` also covers math,
                // which this check deliberately ignores.
                let inRange = fenced.contains { NSLocationInRange(location, $0) }
                let inCode = MarkdownWritingToolsProtection.isInsideCodeOrFrontMatter(
                    location: location,
                    in: text
                )
                if inCode {
                    XCTAssertTrue(inRange, "offset \(location) reads as code but is unprotected")
                }
            }
        }
    }
}
