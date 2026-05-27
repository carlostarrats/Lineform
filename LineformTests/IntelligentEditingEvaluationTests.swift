import XCTest
@testable import Lineform

final class IntelligentEditingEvaluationTests: XCTestCase {
    func testGoldenTasksCoverEverySelectionLength() {
        let coveredLengths = Set(IntelligentEditingEvaluationSuite.goldenTasks.map(\.length))

        XCTAssertEqual(coveredLengths, Set(IntelligentEditingSelectionLength.allCases))
        XCTAssertTrue(IntelligentEditingEvaluationSuite.goldenTasks.contains { $0.action == .rewrite })
        XCTAssertTrue(IntelligentEditingEvaluationSuite.goldenTasks.contains { $0.action == .proofread })
        XCTAssertTrue(IntelligentEditingEvaluationSuite.goldenTasks.contains { $0.action == .summarize })
        XCTAssertTrue(IntelligentEditingEvaluationSuite.goldenTasks.contains { $0.action == .shorten })
        XCTAssertTrue(IntelligentEditingEvaluationSuite.goldenTasks.contains { $0.action == .cleanMarkdown })
    }

    func testRubricAcceptsUsefulReplacementForRewriteTask() throws {
        let task = try XCTUnwrap(IntelligentEditingEvaluationSuite.goldenTasks.first { $0.id == "sentence-rewrite" })

        let result = IntelligentEditingEvaluationRubric.evaluate(
            replacement: "The launch plan is clear, but the final handoff still needs a named owner.",
            task: task
        )

        XCTAssertTrue(result.passed, result.failureSummary)
    }

    func testRubricRejectsPlaceholderAndDummyText() throws {
        let task = try XCTUnwrap(IntelligentEditingEvaluationSuite.goldenTasks.first { $0.id == "sentence-rewrite" })

        let placeholder = IntelligentEditingEvaluationRubric.evaluate(
            replacement: "Replacement option 1",
            task: task
        )
        let dummy = IntelligentEditingEvaluationRubric.evaluate(
            replacement: "Lorem ipsum dolor sit amet.",
            task: task
        )

        XCTAssertFalse(placeholder.passed)
        XCTAssertTrue(placeholder.failures.contains(.placeholderOrDummyText))
        XCTAssertFalse(dummy.passed)
        XCTAssertTrue(dummy.failures.contains(.placeholderOrDummyText))
    }

    func testRubricRejectsUnchangedTransformOutput() throws {
        let task = try XCTUnwrap(IntelligentEditingEvaluationSuite.goldenTasks.first { $0.id == "sentence-rewrite" })

        let result = IntelligentEditingEvaluationRubric.evaluate(
            replacement: task.selectedText,
            task: task
        )

        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.failures.contains(.unchangedTransformOutput))
    }

    func testRubricRejectsOversizedOneWordReplacement() throws {
        let task = try XCTUnwrap(IntelligentEditingEvaluationSuite.goldenTasks.first { $0.id == "one-word-proofread" })

        let result = IntelligentEditingEvaluationRubric.evaluate(
            replacement: "A complete paragraph is not a valid replacement for a single selected title word.",
            task: task
        )

        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.failures.contains(.oversizedShortSelection))
    }

    func testRubricRejectsNearbyContextLeakage() throws {
        let task = try XCTUnwrap(IntelligentEditingEvaluationSuite.goldenTasks.first { $0.id == "sentence-rewrite" })

        let result = IntelligentEditingEvaluationRubric.evaluate(
            replacement: "The appendix contains budget assumptions that should not appear in the selected replacement.",
            task: task
        )

        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.failures.contains(.leakedNearbyContext))
    }

    func testLiveFoundationModelsEvalIsOptIn() async throws {
        guard Self.shouldRunLiveFoundationModelsEval else {
            throw XCTSkip("Set LINEFORM_RUN_LIVE_INTELLIGENCE_EVALS=1 or create /private/tmp/lineform-run-live-intelligence-evals to run live Apple Intelligence evals.")
        }

        let service = FoundationModelsIntelligentEditingService()
        var failures: [String] = []

        for task in IntelligentEditingEvaluationSuite.liveTasks {
            do {
                let replacement = try await service.replacement(
                    for: task.action,
                    selectedText: task.selectedText,
                    documentContext: task.documentContext
                )
                let result = IntelligentEditingEvaluationRubric.evaluate(replacement: replacement, task: task)
                if !result.passed {
                    failures.append("\(task.id): \(result.failureSummary) | \(Self.preview(replacement))")
                }
            } catch {
                failures.append("\(task.id): \(error.localizedDescription)")
            }
        }

        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    private static var shouldRunLiveFoundationModelsEval: Bool {
        ProcessInfo.processInfo.environment["LINEFORM_RUN_LIVE_INTELLIGENCE_EVALS"] == "1"
            || FileManager.default.fileExists(atPath: "/private/tmp/lineform-run-live-intelligence-evals")
    }

    private static func preview(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 160 else {
            return trimmed
        }

        return "\(trimmed.prefix(160))..."
    }
}
