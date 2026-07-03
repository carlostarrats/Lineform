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
}
