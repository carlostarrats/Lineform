import XCTest
@testable import Lineform

final class MarkdownRangeAnalyzerTests: XCTestCase {
    func testFindsCommonMarkdownTokenRanges() {
        let markdown = """
        # Heading
        - [x] Done
        > Quote
        Use `code` and [link](https://example.com).
        ```swift
        let value = 1
        ```
        """

        let tokens = MarkdownRangeAnalyzer().ranges(in: markdown)
        let kinds = Set(tokens.map(\.kind))

        XCTAssertTrue(kinds.contains(.headingMarker))
        XCTAssertTrue(kinds.contains(.listMarker))
        XCTAssertTrue(kinds.contains(.checkbox))
        XCTAssertTrue(kinds.contains(.blockquoteMarker))
        XCTAssertTrue(kinds.contains(.codeSpan))
        XCTAssertTrue(kinds.contains(.linkText))
        XCTAssertTrue(kinds.contains(.linkDestination))
        XCTAssertTrue(kinds.contains(.codeFence))
    }

    func testHeadingMarkerRangeCoversOnlyLeadingHashes() {
        let markdown = "### Heading"

        let token = MarkdownRangeAnalyzer().ranges(in: markdown).first { $0.kind == .headingMarker }

        XCTAssertEqual(token?.range, NSRange(location: 0, length: 3))
    }
}
