import XCTest
@testable import Lineform

final class IntelligentEditingRunnerTests: XCTestCase {
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

    func testRunnerKeepsNearbyContextSmallForResponsiveEditing() async throws {
        let service = StubIntelligentEditingService(result: "Clear sentence.")
        let runner = IntelligentEditingRunner(service: service)
        let prefix = String(repeating: "a", count: 1_000)
        let suffix = String(repeating: "b", count: 1_000)
        let document = "\(prefix)Selected text.\(suffix)"

        _ = try await runner.run(
            action: .rewrite,
            documentText: document,
            selectedRange: NSRange(location: 1_000, length: 14)
        )

        XCTAssertLessThanOrEqual(service.requests.first?.documentContext.count ?? 0, 14 + IntelligentEditingRunner.documentContextRadius * 2)
    }

    func testOptionResponseParserExtractsTaggedOptionsInOrder() {
        let response = """
        <<<LINEFORM_OPTION_1>>>
        First option.
        <<<END_LINEFORM_OPTION_1>>>
        <<<LINEFORM_OPTION_2>>>
        Second option.
        <<<END_LINEFORM_OPTION_2>>>
        <<<LINEFORM_OPTION_3>>>
        Third option.
        <<<END_LINEFORM_OPTION_3>>>
        """

        XCTAssertEqual(
            IntelligentEditingOptionResponseParser.parse(response, expectedCount: 3),
            ["First option.", "Second option.", "Third option."]
        )
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
