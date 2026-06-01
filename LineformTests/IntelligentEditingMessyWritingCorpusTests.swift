import XCTest
@testable import Lineform

final class IntelligentEditingMessyWritingCorpusTests: XCTestCase {
    func testMessyWritingCorpusCasesRunThroughValidatedServicePath() async throws {
        let cases = try Self.loadCorpus()
        XCTAssertGreaterThanOrEqual(cases.count, 10)

        for corpusCase in cases {
            let service = FoundationModelsIntelligentEditingService(
                responseProvider: CorpusStubResponseProvider(responses: corpusCase.providerResponses)
            )
            let request = try corpusCase.request()

            do {
                let replacements: [String]
                if let optionCount = corpusCase.optionCount, optionCount > 1 {
                    replacements = try await service.replacements(
                        for: request,
                        selectedText: corpusCase.selectedText,
                        documentContext: corpusCase.documentContext,
                        count: optionCount
                    )
                    XCTAssertEqual(replacements.count, optionCount, corpusCase.id)
                    XCTAssertEqual(Set(replacements).count, replacements.count, corpusCase.id)
                } else {
                    replacements = [
                        try await service.replacement(
                            for: request,
                            selectedText: corpusCase.selectedText,
                            documentContext: corpusCase.documentContext
                        )
                    ]
                }

                if let expectedFailure = corpusCase.expectedFailure {
                    XCTFail("\(corpusCase.id) expected \(expectedFailure), got \(replacements)")
                    continue
                }

                try corpusCase.assert(replacements: replacements)
                for replacement in replacements {
                    let evaluation = IntelligentEditingEvaluationRubric.evaluate(
                        replacement: replacement,
                        task: try corpusCase.evaluationTask()
                    )
                    XCTAssertTrue(evaluation.passed, "\(corpusCase.id) failed rubric with \(evaluation.failureSummary): \(replacement)")
                }
            } catch {
                if corpusCase.expectedFailure == "unrecognizedLanguage" {
                    guard case IntelligentEditingError.unrecognizedLanguage = error else {
                        XCTFail("\(corpusCase.id) expected unrecognizedLanguage, got \(error)")
                        continue
                    }
                    continue
                }

                XCTFail("\(corpusCase.id) unexpectedly threw \(error)")
            }
        }
    }

    func testMessyWritingCorpusCoversRequiredScenarioTags() throws {
        let coveredTags = Set(try Self.loadCorpus().flatMap(\.scenarioTags))
        let requiredTags: Set<String> = [
            "proofread:messy-spelling",
            "proofread:short-grammar-spelling",
            "proofread:unrecognizable",
            "proofread:already-clean",
            "rewrite:short-phrase",
            "rewrite:awkward-paragraph",
            "summarize:multi-paragraph",
            "shorten:preserve-meaning",
            "markdown:structure-preservation",
            "dictionary:false-positive-risk",
            "input:user-instruction",
            "input:custom-word-swap",
            "provider:no-op-repair",
            "provider:fallback-usage",
            "provider:fail-clean",
            "provider:multi-option-stability",
            "writing-risk:local-first"
        ]

        XCTAssertTrue(
            coveredTags.isSuperset(of: requiredTags),
            "Missing corpus scenario tags: \(requiredTags.subtracting(coveredTags).sorted().joined(separator: ", "))"
        )
    }

    private static func loadCorpus() throws -> [MessyWritingCorpusCase] {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let fixtureURL = testFileURL
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("IntelligentEditingMessyWritingCorpus.json")
        let data = try Data(contentsOf: fixtureURL)
        return try JSONDecoder().decode([MessyWritingCorpusCase].self, from: data)
    }
}

private struct MessyWritingCorpusCase: Decodable {
    let id: String
    let action: IntelligentEditingAction?
    let userInstruction: String?
    let selectedText: String
    let documentContext: String
    let providerResponses: [String]
    let expectedReplacement: String?
    let expectedReplacements: [String]?
    let expectedFailure: String?
    let optionCount: Int?
    let allowUnchanged: Bool?
    let requiredFragments: [String]?
    let forbiddenFragments: [String]?
    let scenarioTags: [String]

    private enum CodingKeys: String, CodingKey {
        case id
        case action
        case userInstruction
        case selectedText
        case documentContext
        case providerResponses
        case expectedReplacement
        case expectedReplacements
        case expectedFailure
        case optionCount
        case allowUnchanged
        case requiredFragments
        case forbiddenFragments
        case scenarioTags
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        if let actionRawValue = try container.decodeIfPresent(String.self, forKey: .action) {
            action = IntelligentEditingAction(rawValue: actionRawValue)
            if action == nil {
                throw DecodingError.dataCorruptedError(
                    forKey: .action,
                    in: container,
                    debugDescription: "Unknown intelligent editing action: \(actionRawValue)"
                )
            }
        } else {
            action = nil
        }
        userInstruction = try container.decodeIfPresent(String.self, forKey: .userInstruction)
        selectedText = try container.decode(String.self, forKey: .selectedText)
        documentContext = try container.decode(String.self, forKey: .documentContext)
        providerResponses = try container.decode([String].self, forKey: .providerResponses)
        expectedReplacement = try container.decodeIfPresent(String.self, forKey: .expectedReplacement)
        expectedReplacements = try container.decodeIfPresent([String].self, forKey: .expectedReplacements)
        expectedFailure = try container.decodeIfPresent(String.self, forKey: .expectedFailure)
        optionCount = try container.decodeIfPresent(Int.self, forKey: .optionCount)
        allowUnchanged = try container.decodeIfPresent(Bool.self, forKey: .allowUnchanged)
        requiredFragments = try container.decodeIfPresent([String].self, forKey: .requiredFragments)
        forbiddenFragments = try container.decodeIfPresent([String].self, forKey: .forbiddenFragments)
        scenarioTags = try container.decode([String].self, forKey: .scenarioTags)
    }

    func request() throws -> IntelligentEditingRequest {
        if let userInstruction {
            return .custom(userInstruction)
        }

        return .action(try XCTUnwrap(action, "\(id) must declare action or userInstruction"))
    }

    func evaluationTask() throws -> IntelligentEditingEvaluationTask {
        let request = try request()
        let evaluationAction = request.evaluationAction
        return IntelligentEditingEvaluationTask(
            id: id,
            action: evaluationAction,
            userInstruction: request.usesUserInstruction ? request.userInstruction : nil,
            selectedText: selectedText,
            documentContext: documentContext,
            length: selectedText.contains("\n\n") ? .multipleParagraphs : .sentence,
            requiresTransformation: (allowUnchanged ?? false) ? false : evaluationAction.requiresNonIdenticalReplacement(for: selectedText),
            requiresCompression: evaluationAction == .summarize || evaluationAction == .shorten,
            requiresMarkdownPreservation: evaluationAction == .cleanMarkdown || selectedText.contains("- ") || selectedText.contains("#")
        )
    }

    func assert(replacements: [String]) throws {
        if let expectedReplacement {
            XCTAssertEqual(replacements.first, expectedReplacement, id)
        }

        if let expectedReplacements {
            XCTAssertEqual(replacements, expectedReplacements, id)
        }

        for replacement in replacements {
            if allowUnchanged != true {
                XCTAssertNotEqual(normalized(replacement), normalized(selectedText), id)
            }

            for fragment in requiredFragments ?? [] {
                XCTAssertTrue(replacement.contains(fragment), "\(id) missing required fragment \(fragment): \(replacement)")
            }

            for fragment in forbiddenFragments ?? [] {
                XCTAssertFalse(replacement.contains(fragment), "\(id) contains forbidden fragment \(fragment): \(replacement)")
            }
        }
    }

    private func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
}

private final class CorpusStubResponseProvider: FoundationModelsResponseProviding, @unchecked Sendable {
    private var responses: [String]

    init(responses: [String]) {
        self.responses = responses
    }

    func responseContent(for prompt: String) async throws -> String {
        responses.isEmpty ? "" : responses.removeFirst()
    }
}
