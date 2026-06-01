import XCTest
@testable import Lineform

final class IntelligentEditingQualityPipelineTests: XCTestCase {
    func testQualityPipelineRoutesProofreadThroughNativeCheckerBeforeGeneration() {
        let plan = IntelligentEditingQualityPipeline.plan(
            for: .action(.proofread),
            selectedText: "cat ib the hat"
        )

        XCTAssertEqual(plan.action, .proofread)
        XCTAssertTrue(plan.stages.contains(.classifySelection))
        XCTAssertTrue(plan.stages.contains(.nativeProofreadCheck))
        XCTAssertTrue(plan.stages.contains(.appleCandidateGeneration))
        XCTAssertTrue(plan.stages.contains(.lineformValidation))
        XCTAssertEqual(plan.stages.last, .failCleanly)
    }

    func testQualityPipelineKeepsGenerativeActionsOnAppleCandidatePathWithValidation() {
        for action in [IntelligentEditingAction.rewrite, .summarize, .shorten] {
            let plan = IntelligentEditingQualityPipeline.plan(
                for: .action(action),
                selectedText: "This sentence needs clearer wording."
            )

            XCTAssertFalse(plan.stages.contains(.nativeProofreadCheck), "\(action)")
            XCTAssertTrue(plan.stages.contains(.appleCandidateGeneration), "\(action)")
            XCTAssertTrue(plan.stages.contains(.lineformValidation), "\(action)")
            XCTAssertEqual(plan.stages.last, .failCleanly, "\(action)")
        }
    }

    func testQualityPipelineKeepsCleanMarkdownDeterministic() {
        let plan = IntelligentEditingQualityPipeline.plan(
            for: .action(.cleanMarkdown),
            selectedText: "#Title\n\n-  item"
        )

        XCTAssertTrue(plan.stages.contains(.deterministicMarkdownCleanup))
        XCTAssertFalse(plan.stages.contains(.appleCandidateGeneration))
        XCTAssertTrue(plan.stages.contains(.lineformValidation))
    }

    func testNativeProofreadFallbackRepairsGeneratedShortTokenMisspellings() async throws {
        for fixture in ShortProofreadFixture.generatedShortTokenMisspellings {
            let service = FoundationModelsIntelligentEditingService(
                responseProvider: QualityPipelineStubProvider(
                    responses: Array(repeating: fixture.input, count: 8)
                )
            )

            let replacement = try await service.replacement(
                for: .proofread,
                selectedText: fixture.input,
                documentContext: ""
            )

            XCTAssertEqual(replacement, fixture.expected, fixture.input)
        }
    }

    func testProofreadAllowsAlreadyCleanShortPhrasesToRemainUnchanged() async throws {
        for input in ["cat in the hat", "I am going home", "the file is local"] {
            let service = FoundationModelsIntelligentEditingService(
                responseProvider: QualityPipelineStubProvider(responses: [input])
            )

            let replacement = try await service.replacement(
                for: .proofread,
                selectedText: input,
                documentContext: ""
            )

            XCTAssertEqual(replacement, input)
        }
    }

    func testProofreadRejectsUnchangedAmbiguousShortMistakeInsteadOfShowingFakeSuccess() async throws {
        let selectedText = "cat im the hat"
        let service = FoundationModelsIntelligentEditingService(
            responseProvider: QualityPipelineStubProvider(
                responses: Array(repeating: selectedText, count: 8)
            )
        )

        do {
            _ = try await service.replacement(
                for: .proofread,
                selectedText: selectedText,
                documentContext: ""
            )
            XCTFail("Expected ambiguous unchanged proofread output to fail.")
        } catch IntelligentEditingError.invalidResponse {
        }
    }

    func testProofreadRejectsKeyboardMashInsteadOfApplyingSpellcheckGuesses() async throws {
        let selectedText = "slkj sl;jf sl;jf s;afjs"
        let service = FoundationModelsIntelligentEditingService(
            responseProvider: QualityPipelineStubProvider(
                responses: Array(repeating: selectedText, count: 8)
            )
        )

        do {
            _ = try await service.replacement(
                for: .proofread,
                selectedText: selectedText,
                documentContext: ""
            )
            XCTFail("Expected unrecognizable keyboard mash to fail.")
        } catch IntelligentEditingError.unrecognizedLanguage {
        }
    }
}

private struct ShortProofreadFixture {
    let input: String
    let expected: String

    static let generatedShortTokenMisspellings: [ShortProofreadFixture] = [
        ShortProofreadFixture(input: "cat ib the hat", expected: "cat in the hat"),
        ShortProofreadFixture(input: "draft ib the folder", expected: "draft in the folder"),
        ShortProofreadFixture(input: "text ib the file", expected: "text in the file")
    ]
}

private final class QualityPipelineStubProvider: FoundationModelsResponseProviding, @unchecked Sendable {
    private var responses: [String]

    init(responses: [String]) {
        self.responses = responses
    }

    func responseContent(for prompt: String) async throws -> String {
        responses.isEmpty ? "" : responses.removeFirst()
    }
}
