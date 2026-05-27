import XCTest
@testable import Lineform

final class IntelligentEditingPromptBuilderTests: XCTestCase {
    func testPromptKeepsTheActionContextualAndMarkdownPreserving() {
        let prompt = IntelligentEditingPromptBuilder().prompt(
            for: .rewrite,
            selectedText: "This paragraph is confusing.",
            documentContext: "# Draft\n\nThis paragraph is confusing."
        )

        XCTAssertTrue(prompt.contains("Rewrite"))
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

    func testPromptDefinesOutputContractAndInvalidOutputs() {
        let prompt = IntelligentEditingPromptBuilder().prompt(
            for: .rewrite,
            selectedText: "The launch plan is clear but final handoff is still kind of owned by somebody.",
            documentContext: "The appendix contains budget assumptions."
        )

        XCTAssertTrue(prompt.contains("Output contract"))
        XCTAssertTrue(prompt.contains("Invalid outputs"))
        XCTAssertTrue(prompt.contains("Quality bar"))
        XCTAssertTrue(prompt.contains("Do not return placeholder text"))
        XCTAssertTrue(prompt.contains("Do not return the selected Markdown unchanged"))
        XCTAssertTrue(prompt.contains("Do not copy nearby context"))
        XCTAssertTrue(prompt.contains("Successful Rewrite"))
    }

    func testPromptDefinesSelectionLengthContractForOneWordSelections() {
        let prompt = IntelligentEditingPromptBuilder().prompt(
            for: .rewrite,
            selectedText: "Features",
            documentContext: "# Features\n\n- Fast Markdown editing."
        )

        XCTAssertTrue(prompt.contains("Selection length: one word or short phrase"))
        XCTAssertTrue(prompt.contains("Return 1-4 words"))
        XCTAssertTrue(prompt.contains("Do not return a sentence, paragraph, list, heading, or newline"))
    }

    func testOptionPromptFormatDoesNotIncludeCopyablePlaceholderText() {
        let format = IntelligentEditingOptionResponseParser.exampleFormat(for: 3)

        XCTAssertFalse(format.contains("<write only replacement"))
        XCTAssertFalse(format.localizedCaseInsensitiveContains("replacement option"))
        XCTAssertTrue(format.contains("<<<LINEFORM_OPTION_1>>>"))
        XCTAssertTrue(format.contains("<<<END_LINEFORM_OPTION_3>>>"))
    }

    func testRepairPromptExplainsWhyPreviousAnswerWasRejected() {
        let prompt = IntelligentEditingPromptBuilder().repairPrompt(
            for: .shorten,
            selectedText: "Lineform keeps Markdown files on disk so writers can use Finder and version control without converting drafts into a private database.",
            documentContext: "",
            rejectedReplacement: "Lineform keeps Markdown files on disk so writers can use Finder and version control without converting drafts into a private database.",
            failures: [.unchangedTransformOutput, .missingCompression]
        )

        XCTAssertTrue(prompt.contains("Previous answer was rejected"))
        XCTAssertTrue(prompt.contains("It repeated the selected Markdown unchanged"))
        XCTAssertTrue(prompt.contains("It was not shorter than the selection"))
        XCTAssertTrue(prompt.contains("Return a new replacement now"))
    }
}
