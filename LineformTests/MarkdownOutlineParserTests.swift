import XCTest
@testable import Lineform

final class MarkdownOutlineParserTests: XCTestCase {
    func testParsesATXHeadingsWithLevelsAndLineNumbers() {
        let text = "# Title\nBody\n## Section\n### Detail\n"

        let outline = MarkdownOutlineParser().items(in: text)

        XCTAssertEqual(outline.map(\.title), ["Title", "Section", "Detail"])
        XCTAssertEqual(outline.map(\.level), [1, 2, 3])
        XCTAssertEqual(outline.map(\.lineNumber), [1, 3, 4])
    }

    func testIgnoresHeadingsInsideFencedCodeBlocks() {
        let text = "# Real\n```\n# Not real\n```\n## Also Real"

        let outline = MarkdownOutlineParser().items(in: text)

        XCTAssertEqual(outline.map(\.title), ["Real", "Also Real"])
    }

    func testHeadingCharacterRangeStartsAtHeadingLine() {
        let text = "Intro\n\n## Target\nBody"

        let item = MarkdownOutlineParser().items(in: text).first

        XCTAssertEqual(item?.characterRange.location, 7)
        XCTAssertEqual(item?.characterRange.length, 9)
    }
}
