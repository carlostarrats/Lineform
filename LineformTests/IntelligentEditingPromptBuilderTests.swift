import XCTest
@testable import Lineform

final class IntelligentEditingPromptBuilderTests: XCTestCase {
    func testPromptKeepsTheActionContextualAndMarkdownPreserving() {
        let prompt = IntelligentEditingPromptBuilder().prompt(
            for: .makeClearer,
            selectedText: "This paragraph is confusing.",
            documentContext: "# Draft\n\nThis paragraph is confusing."
        )

        XCTAssertTrue(prompt.contains("Make Clearer"))
        XCTAssertTrue(prompt.contains("selected Markdown only"))
        XCTAssertTrue(prompt.contains("preserve Markdown"))
        XCTAssertTrue(prompt.contains("return only the replacement"))
        XCTAssertFalse(prompt.localizedCaseInsensitiveContains("external"))
        XCTAssertFalse(prompt.localizedCaseInsensitiveContains("sidebar"))
    }

    func testCleanMarkdownPromptProtectsMeaningAndStructure() {
        let prompt = IntelligentEditingPromptBuilder().prompt(
            for: .cleanMarkdown,
            selectedText: "- item\n\n```swift\nlet value = 1\n```",
            documentContext: ""
        )

        XCTAssertTrue(prompt.contains("Clean Markdown"))
        XCTAssertTrue(prompt.contains("Do not rewrite fenced code"))
        XCTAssertTrue(prompt.contains("Keep links, headings, lists, and emphasis intact"))
    }
}
