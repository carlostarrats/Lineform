import XCTest
@testable import Lineform

final class IntelligentEditingPromptBuilderTests: XCTestCase {
    func testCustomInstructionPromptPrioritizesTheUserDirectionAndSelectionBoundary() {
        let prompt = IntelligentEditingPromptBuilder().prompt(
            for: .custom("Make this warmer and less corporate."),
            selectedText: "The rollout requires stakeholder alignment before execution.",
            documentContext: "Do not copy this neighboring sentence into the answer."
        )

        XCTAssertTrue(prompt.contains("User instruction:"))
        XCTAssertTrue(prompt.contains("Make this warmer and less corporate."))
        XCTAssertTrue(prompt.contains("Follow the user instruction exactly when it is safe for the selected text."))
        XCTAssertTrue(prompt.contains("Custom instruction rules:"))
        XCTAssertTrue(prompt.contains("replace business jargon with plain human wording"))
        XCTAssertTrue(prompt.contains("Replace exactly the selected Markdown, not nearby context."))
        XCTAssertTrue(prompt.contains("Use nearby context only to understand tone and boundaries."))
        XCTAssertFalse(prompt.contains("Action: Rewrite"))
        XCTAssertFalse(prompt.contains("Action: Proofread"))
        XCTAssertFalse(prompt.contains("LINEFORM_OPTION"))
    }

    func testCustomInstructionPromptDefinesSpecificInstructionModes() {
        let prompt = IntelligentEditingPromptBuilder().prompt(
            for: .custom("Replace robust with simple and make this active voice."),
            selectedText: "The robust draft was reviewed by the editor.",
            documentContext: ""
        )

        XCTAssertTrue(prompt.contains("remove the old wording and include the requested new wording"))
        XCTAssertTrue(prompt.contains("make the subject perform the action"))
        XCTAssertTrue(prompt.contains("Do not answer the instruction as a question"))
    }

    func testCustomInstructionPromptTrimsAndLimitsUserInstructions() {
        let longInstruction = String(repeating: "make this calmer ", count: 40)

        let request = IntelligentEditingRequest.custom("   \(longInstruction)   ")

        XCTAssertEqual(request.title, "Custom Instruction")
        XCTAssertLessThanOrEqual(request.userInstruction.count, IntelligentEditingRequest.maximumInstructionLength)
        XCTAssertFalse(request.userInstruction.hasPrefix(" "))
        XCTAssertFalse(request.userInstruction.hasSuffix(" "))
    }

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
        XCTAssertTrue(prompt.contains("Do not rewrite prose, facts, fenced code blocks"))
        XCTAssertTrue(prompt.contains("Change Markdown formatting only"))
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

    func testOptionPromptDoesNotExposeInternalTags() {
        let prompt = IntelligentEditingPromptBuilder().optionPrompt(
            for: .rewrite,
            selectedText: "The handoff is kind of unclear.",
            documentContext: "The handoff is kind of unclear.",
            optionNumber: 2,
            optionCount: 3,
            priorOptions: ["The handoff needs clearer ownership."],
            rejectedDuplicate: nil
        )

        XCTAssertTrue(prompt.contains("Return exactly one replacement for option 2 of 3"))
        XCTAssertTrue(prompt.contains("meaningfully different from accepted prior options"))
        XCTAssertFalse(prompt.contains("LINEFORM_OPTION"))
        XCTAssertFalse(prompt.contains("<<<"))
        XCTAssertFalse(prompt.contains(">>>"))
    }

    func testPromptForbidsInternalMarkersAndActionDrift() {
        let proofreadPrompt = IntelligentEditingPromptBuilder().prompt(
            for: .proofread,
            selectedText: "The editor keep drafts local.",
            documentContext: ""
        )
        let cleanMarkdownPrompt = IntelligentEditingPromptBuilder().prompt(
            for: .cleanMarkdown,
            selectedText: "#Title\n\n-  item",
            documentContext: ""
        )

        XCTAssertFalse(proofreadPrompt.contains("LINEFORM_OPTION"))
        XCTAssertFalse(cleanMarkdownPrompt.contains("LINEFORM_OPTION"))
        XCTAssertTrue(proofreadPrompt.contains("do not improve style, tone, structure, or word choice"))
        XCTAssertTrue(cleanMarkdownPrompt.contains("Change Markdown formatting only"))
    }

    func testRepairPromptExplainsWhyPreviousAnswerWasRejected() {
        let prompt = IntelligentEditingPromptBuilder().repairPrompt(
            for: .shorten,
            selectedText: "Lineform keeps Markdown files on disk so writers can use Finder and version control without converting drafts into a private database.",
            documentContext: "",
            rejectedReplacement: "Lineform keeps Markdown files on disk so writers can use Finder and version control without converting drafts into a private database.",
            failures: [.unchangedTransformOutput, .missingCompression, .cleanMarkdownChangedContent]
        )

        XCTAssertTrue(prompt.contains("Previous answer was rejected"))
        XCTAssertTrue(prompt.contains("It repeated the selected Markdown unchanged"))
        XCTAssertTrue(prompt.contains("It was not compressed enough"))
        XCTAssertTrue(prompt.contains("It changed content during Clean Markdown"))
        XCTAssertTrue(prompt.contains("Return a new replacement now"))
        XCTAssertFalse(prompt.contains("LINEFORM_OPTION"))
    }

    func testCustomRepairPromptExplainsInstructionFollowingFailures() {
        let prompt = IntelligentEditingPromptBuilder().repairPrompt(
            for: .custom("Replace robust with simple."),
            selectedText: "The robust export flow keeps drafts local.",
            documentContext: "",
            rejectedReplacement: "The reliable export flow keeps drafts local.",
            failures: [.userInstructionNotFollowed]
        )

        XCTAssertTrue(prompt.contains("Custom instruction rules:"))
        XCTAssertTrue(prompt.contains("remove the old wording and include the requested new wording"))
        XCTAssertTrue(prompt.contains("It did not follow the user's instruction"))
        XCTAssertFalse(prompt.contains("LINEFORM_OPTION"))
    }
}
