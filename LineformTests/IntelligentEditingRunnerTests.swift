import XCTest
@testable import Lineform

final class IntelligentEditingRunnerTests: XCTestCase {
    func testFoundationModelsServiceDoesNotSurfaceControlTagsWhenModelReturnsThemForOptions() async throws {
        let service = FoundationModelsIntelligentEditingService(
            responseProvider: StubFoundationModelsResponseProvider(
                responses: Array(repeating: "<<<LINEFORM_OPTION_1>>>", count: 20)
            )
        )

        let replacements = try await service.replacements(
            for: .rewrite,
            selectedText: "Features",
            documentContext: "# Features\n\n- Native Markdown files.",
            count: 3
        )

        XCTAssertEqual(replacements, ["Highlights", "Capabilities", "Essentials"])
        XCTAssertFalse(replacements.joined(separator: "\n").contains("LINEFORM_OPTION"))
    }

    func testFoundationModelsServiceProducesWordLikeFallbackForShortRewriteWhenModelReturnsProtocolText() async throws {
        let service = FoundationModelsIntelligentEditingService(
            responseProvider: StubFoundationModelsResponseProvider(
                responses: Array(repeating: "<<<LINEFORM_OPTION_1>>>", count: 8)
            )
        )

        let replacement = try await service.replacement(
            for: .rewrite,
            selectedText: "better writing",
            documentContext: "# better writing\n\nA calmer Markdown editor for long drafts."
        )

        XCTAssertEqual(replacement, "clearer prose")
        XCTAssertLessThanOrEqual(IntelligentEditingEvaluationRubric.wordCount(in: replacement), 4)
        XCTAssertFalse(replacement.contains("LINEFORM_OPTION"))
    }

    func testRunnerRejectsEmptySelectionBeforeCallingService() async throws {
        let service = StubIntelligentEditingService(result: "Unused")
        let runner = IntelligentEditingRunner(service: service)

        do {
            _ = try await runner.run(
                action: .shorten,
                documentText: "Nothing selected",
                selectedRange: NSRange(location: 0, length: 0)
            )
            XCTFail("Expected empty selection to fail.")
        } catch IntelligentEditingError.emptySelection {
            XCTAssertEqual(service.requests.count, 0)
        }
    }

    func testRunnerBuildsReversibleSuggestionForSelectedText() async throws {
        let service = StubIntelligentEditingService(result: "Clear sentence.")
        let runner = IntelligentEditingRunner(service: service)

        let suggestion = try await runner.run(
            action: .rewrite,
            documentText: "Start. Confusing sentence. End.",
            selectedRange: NSRange(location: 7, length: 19)
        )

        XCTAssertEqual(suggestion.originalText, "Confusing sentence.")
        XCTAssertEqual(suggestion.replacementText, "Clear sentence.")
        XCTAssertEqual(suggestion.accept(in: "Start. Confusing sentence. End."), "Start. Clear sentence. End.")
        XCTAssertEqual(service.requests.first?.action, .rewrite)
    }

    func testSuggestionDoesNotApplyWhenOriginalSelectionChanged() async throws {
        let service = StubIntelligentEditingService(result: "Clear sentence.")
        let runner = IntelligentEditingRunner(service: service)

        let suggestion = try await runner.run(
            action: .rewrite,
            documentText: "Start. Confusing sentence. End.",
            selectedRange: NSRange(location: 7, length: 19)
        )

        XCTAssertNil(suggestion.accept(in: "Start. Different sentence. End."))
    }

    func testRunnerBuildsMultipleSuggestionsForShortSelectionOptions() async throws {
        let service = StubIntelligentEditingService(results: [
            "First option.",
            "Second option.",
            "Third option."
        ])
        let runner = IntelligentEditingRunner(service: service)

        let suggestions = try await runner.runOptions(
            action: .rewrite,
            documentText: "Start. Rough sentence. End.",
            selectedRange: NSRange(location: 7, length: 15),
            optionCount: 3
        )

        XCTAssertEqual(suggestions.map(\.replacementText), [
            "First option.",
            "Second option.",
            "Third option."
        ])
        XCTAssertEqual(Set(suggestions.map(\.originalText)), ["Rough sentence."])
        XCTAssertEqual(service.optionRequests.first?.count, 3)
    }

    func testRunnerRejectsParagraphReplacementForOneWordSelection() async throws {
        let service = StubIntelligentEditingService(result: """
        Lineform is a native macOS Markdown editor.

        ## Features

        - Built with Swift.
        """)
        let runner = IntelligentEditingRunner(service: service)

        do {
            _ = try await runner.run(
                action: .rewrite,
                documentText: "## Features\n\n- Built with Swift.",
                selectedRange: NSRange(location: 3, length: 8)
            )
            XCTFail("Expected oversized replacement to be rejected.")
        } catch IntelligentEditingError.emptyResponse {
            XCTAssertEqual(service.requests.first?.selectedText, "Features")
            XCTAssertEqual(service.requests.first?.documentContext, "")
        }
    }

    func testRunnerFiltersOversizedOptionsForOneWordSelection() async throws {
        let service = StubIntelligentEditingService(results: [
            "Highlights",
            "Lineform is a native macOS Markdown editor.\n\n## Features",
            "Replacement option 3"
        ])
        let runner = IntelligentEditingRunner(service: service)

        let suggestions = try await runner.runOptions(
            action: .rewrite,
            documentText: "## Features\n\n- Built with Swift.",
            selectedRange: NSRange(location: 3, length: 8),
            optionCount: 3
        )

        XCTAssertEqual(suggestions.map(\.replacementText), ["Highlights"])
        XCTAssertEqual(service.optionRequests.first?.selectedText, "Features")
        XCTAssertEqual(service.optionRequests.first?.documentContext, "")
    }

    func testRunnerRejectsLineformControlTagOptions() async throws {
        let service = StubIntelligentEditingService(results: [
            "<<<LINEFORM_OPTION_1>>>",
            "Clearer sentence."
        ])
        let runner = IntelligentEditingRunner(service: service)

        let suggestions = try await runner.runOptions(
            action: .rewrite,
            documentText: "Start. Rough sentence. End.",
            selectedRange: NSRange(location: 7, length: 15),
            optionCount: 2
        )

        XCTAssertEqual(suggestions.map(\.replacementText), ["Clearer sentence."])
    }

    func testRunnerRejectsDuplicateOptions() async throws {
        let service = StubIntelligentEditingService(results: [
            "Clearer sentence.",
            "Clearer sentence.",
            "Tighter sentence."
        ])
        let runner = IntelligentEditingRunner(service: service)

        let suggestions = try await runner.runOptions(
            action: .rewrite,
            documentText: "Start. Rough sentence. End.",
            selectedRange: NSRange(location: 7, length: 15),
            optionCount: 3
        )

        XCTAssertEqual(suggestions.map(\.replacementText), ["Clearer sentence.", "Tighter sentence."])
    }

    func testRunnerExtractsQuotedReplacementForOneWordSelection() async throws {
        let service = StubIntelligentEditingService(result: "A better word is \"writer\".")
        let runner = IntelligentEditingRunner(service: service)

        let suggestion = try await runner.run(
            action: .rewrite,
            documentText: "editor",
            selectedRange: NSRange(location: 0, length: 6)
        )

        XCTAssertEqual(suggestion.replacementText, "writer")
    }

    func testRunnerRejectsDummyReplacementText() async throws {
        let service = StubIntelligentEditingService(result: "Lorem ipsum dolor sit amet.")
        let runner = IntelligentEditingRunner(service: service)

        do {
            _ = try await runner.run(
                action: .rewrite,
                documentText: "This sentence needs clearer wording.",
                selectedRange: NSRange(location: 0, length: 36)
            )
            XCTFail("Expected dummy text to be rejected.")
        } catch IntelligentEditingError.emptyResponse {
            XCTAssertEqual(service.requests.first?.selectedText, "This sentence needs clearer wording.")
        }
    }

    func testRunnerRejectsUnchangedRewriteOutput() async throws {
        let selectedText = "This sentence needs clearer wording."
        let service = StubIntelligentEditingService(result: selectedText)
        let runner = IntelligentEditingRunner(service: service)

        do {
            _ = try await runner.run(
                action: .rewrite,
                documentText: selectedText,
                selectedRange: NSRange(location: 0, length: (selectedText as NSString).length)
            )
            XCTFail("Expected unchanged rewrite output to be rejected.")
        } catch IntelligentEditingError.emptyResponse {
            XCTAssertEqual(service.requests.first?.selectedText, selectedText)
        }
    }

    func testRunnerStripsEnclosingMarkdownFenceBeforeValidation() async throws {
        let selectedText = "#Title\n\n-  First item"
        let service = StubIntelligentEditingService(result: """
        ```markdown
        # Title

        - First item
        ```
        """)
        let runner = IntelligentEditingRunner(service: service)

        let suggestion = try await runner.run(
            action: .cleanMarkdown,
            documentText: selectedText,
            selectedRange: NSRange(location: 0, length: (selectedText as NSString).length)
        )

        XCTAssertEqual(suggestion.replacementText, "# Title\n\n- First item")
    }

    func testRunnerRejectsNearbyContextLeakage() async throws {
        let selectedText = "The launch plan is clear but final handoff still needs an owner."
        let leakedContext = "The appendix contains budget assumptions."
        let document = "\(selectedText)\n\n\(leakedContext)"
        let service = StubIntelligentEditingService(result: "The appendix contains budget assumptions.")
        let runner = IntelligentEditingRunner(service: service)

        do {
            _ = try await runner.run(
                action: .rewrite,
                documentText: document,
                selectedRange: NSRange(location: 0, length: (selectedText as NSString).length)
            )
            XCTFail("Expected leaked nearby context to be rejected.")
        } catch IntelligentEditingError.emptyResponse {
            XCTAssertEqual(service.requests.first?.documentContext, document)
        }
    }

    func testRunnerKeepsNearbyContextSmallForResponsiveEditing() async throws {
        let service = StubIntelligentEditingService(result: "Clear sentence.")
        let runner = IntelligentEditingRunner(service: service)
        let prefix = String(repeating: "a", count: 1_000)
        let suffix = String(repeating: "b", count: 1_000)
        let selectedText = "This selected sentence contains enough words for context."
        let document = "\(prefix)\(selectedText)\(suffix)"

        _ = try await runner.run(
            action: .rewrite,
            documentText: document,
            selectedRange: NSRange(location: 1_000, length: (selectedText as NSString).length)
        )

        XCTAssertLessThanOrEqual(service.requests.first?.documentContext.count ?? 0, selectedText.count + IntelligentEditingRunner.documentContextRadius * 2)
    }

}

private final class StubIntelligentEditingService: IntelligentEditingServicing {
    private(set) var requests: [(action: IntelligentEditingAction, selectedText: String, documentContext: String)] = []
    private(set) var optionRequests: [(action: IntelligentEditingAction, selectedText: String, documentContext: String, count: Int)] = []
    private let results: [String]

    init(result: String) {
        self.results = [result]
    }

    init(results: [String]) {
        self.results = results
    }

    func replacement(for action: IntelligentEditingAction, selectedText: String, documentContext: String) async throws -> String {
        requests.append((action, selectedText, documentContext))
        return results[0]
    }

    func replacements(for action: IntelligentEditingAction, selectedText: String, documentContext: String, count: Int) async throws -> [String] {
        optionRequests.append((action, selectedText, documentContext, count))
        return Array(results.prefix(count))
    }
}

private final class StubFoundationModelsResponseProvider: FoundationModelsResponseProviding, @unchecked Sendable {
    private var responses: [String]

    init(responses: [String]) {
        self.responses = responses
    }

    func responseContent(for prompt: String) async throws -> String {
        responses.isEmpty ? "" : responses.removeFirst()
    }
}
