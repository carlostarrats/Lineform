import XCTest
@testable import Lineform

final class MarkdownWritingToolsProtectionTests: XCTestCase {
    func testProtectsYamlFrontMatterAtStartOfDocument() {
        let text = "---\ntitle: Draft\n---\n\nBody"

        let ranges = MarkdownWritingToolsProtection.ignoredRanges(in: text, enclosingRange: NSRange(location: 0, length: (text as NSString).length))

        XCTAssertEqual(ranges.first, NSRange(location: 0, length: 21))
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
}
