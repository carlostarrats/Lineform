import XCTest
@testable import Lineform

final class IntelligentEditingEvaluationTests: XCTestCase {
    func testGoldenTasksCoverEverySelectionLength() {
        let coveredLengths = Set(IntelligentEditingEvaluationSuite.goldenTasks.map(\.length))
        let coveredActionLengthPairs = Set(IntelligentEditingEvaluationSuite.goldenTasks.map { "\($0.action.rawValue):\($0.length.rawValue)" })

        XCTAssertEqual(coveredLengths, Set(IntelligentEditingSelectionLength.allCases))
        XCTAssertTrue(IntelligentEditingEvaluationSuite.goldenTasks.contains { $0.action == .rewrite })
        XCTAssertTrue(IntelligentEditingEvaluationSuite.goldenTasks.contains { $0.action == .proofread })
        XCTAssertTrue(IntelligentEditingEvaluationSuite.goldenTasks.contains { $0.action == .summarize })
        XCTAssertTrue(IntelligentEditingEvaluationSuite.goldenTasks.contains { $0.action == .shorten })
        XCTAssertTrue(IntelligentEditingEvaluationSuite.goldenTasks.contains { $0.action == .cleanMarkdown })
        XCTAssertTrue(coveredActionLengthPairs.isSuperset(of: [
            "rewrite:oneWord",
            "rewrite:sentence",
            "rewrite:paragraph",
            "proofread:oneWord",
            "proofread:sentence",
            "proofread:paragraph",
            "shorten:sentence",
            "shorten:paragraph",
            "summarize:paragraph",
            "summarize:multipleParagraphs",
            "cleanMarkdown:multipleParagraphs"
        ]))
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

    func testRubricRejectsLineformControlTags() throws {
        let task = try XCTUnwrap(IntelligentEditingEvaluationSuite.goldenTasks.first { $0.id == "sentence-rewrite" })

        let result = IntelligentEditingEvaluationRubric.evaluate(
            replacement: "<<<LINEFORM_OPTION_1>>>",
            task: task
        )

        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.failures.contains(.placeholderOrDummyText))
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

    func testRubricRejectsPartialNearbyContextLeakage() throws {
        let task = IntelligentEditingEvaluationTask(
            id: "partial-context-leak",
            action: .rewrite,
            selectedText: "The launch plan still needs an owner.",
            documentContext: "The launch plan still needs an owner.\n\nThe appendix contains budget assumptions for the sales team.",
            length: .sentence,
            requiresTransformation: true,
            requiresCompression: false,
            requiresMarkdownPreservation: false
        )

        let result = IntelligentEditingEvaluationRubric.evaluate(
            replacement: "The launch plan needs an owner for the budget assumptions.",
            task: task
        )

        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.failures.contains(.leakedNearbyContext))
    }

    func testRubricRejectsProofreadThatRewritesStyle() throws {
        let task = try XCTUnwrap(IntelligentEditingEvaluationSuite.goldenTasks.first { $0.id == "sentence-proofread" })

        let result = IntelligentEditingEvaluationRubric.evaluate(
            replacement: "Lineform provides a polished local-first writing experience for Markdown authors.",
            task: task
        )

        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.failures.contains(.proofreadChangedMeaningOrStyle))
    }

    func testRubricRejectsCleanMarkdownThatChangesContent() throws {
        let task = try XCTUnwrap(IntelligentEditingEvaluationSuite.goldenTasks.first { $0.id == "frontmatter-clean-markdown" })

        let result = IntelligentEditingEvaluationRubric.evaluate(
            replacement: """
            ---
            title: Final
            ---

            # Title

            - First item
            - Second item
            """,
            task: task
        )

        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.failures.contains(.cleanMarkdownChangedContent))
    }

    func testLiveFoundationModelsEvalIsOptIn() async throws {
        guard Self.shouldRunLiveFoundationModelsEval else {
            throw XCTSkip("Set LINEFORM_RUN_LIVE_INTELLIGENCE_EVALS=1 or create /private/tmp/lineform-run-live-intelligence-evals to run live Apple Intelligence evals.")
        }

        let runner = IntelligentEditingRunner(service: FoundationModelsIntelligentEditingService())
        var failures: [String] = []

        for task in IntelligentEditingEvaluationSuite.liveTasks {
            let documentText = Self.documentText(for: task)
            let selectedRange = (documentText as NSString).range(of: task.selectedText)
            guard selectedRange.location != NSNotFound else {
                failures.append("\(task.id): selected text was not present in live eval document")
                continue
            }

            do {
                let suggestion = try await runner.run(
                    action: task.action,
                    documentText: documentText,
                    selectedRange: selectedRange
                )
                let replacement = suggestion.replacementText
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

    func testLiveFoundationModelsOptionEvalIsOptIn() async throws {
        guard Self.shouldRunLiveFoundationModelsEval else {
            throw XCTSkip("Set LINEFORM_RUN_LIVE_INTELLIGENCE_EVALS=1 or create /private/tmp/lineform-run-live-intelligence-evals to run live Apple Intelligence evals.")
        }

        let runner = IntelligentEditingRunner(service: FoundationModelsIntelligentEditingService())
        var failures: [String] = []

        for task in IntelligentEditingEvaluationSuite.liveTasks {
            let documentText = Self.documentText(for: task)
            let selectedRange = (documentText as NSString).range(of: task.selectedText)
            guard selectedRange.location != NSNotFound else {
                failures.append("\(task.id): selected text was not present in live eval document")
                continue
            }

            do {
                let optionCount = IntelligentEditingPresentationPolicy.optionCount(for: task.action, selectedText: task.selectedText)
                let suggestions: [IntelligentEditingSuggestion]
                if optionCount > 1 {
                    suggestions = try await runner.runOptions(
                        action: task.action,
                        documentText: documentText,
                        selectedRange: selectedRange,
                        optionCount: optionCount
                    )
                } else {
                    suggestions = [
                        try await runner.run(
                            action: task.action,
                            documentText: documentText,
                            selectedRange: selectedRange
                        )
                    ]
                }
                let replacements = suggestions.map(\.replacementText)

                if replacements.count != optionCount {
                    failures.append("\(task.id): expected \(optionCount) options, received \(replacements.count)")
                }

                let uniqueReplacements = Set(replacements.map(Self.normalized))
                if uniqueReplacements.count != replacements.count {
                    failures.append("\(task.id): duplicate option text")
                }

                for replacement in replacements {
                    let result = IntelligentEditingEvaluationRubric.evaluate(replacement: replacement, task: task)
                    if !result.passed {
                        failures.append("\(task.id): \(result.failureSummary) | \(Self.preview(replacement))")
                    }
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

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private static func documentText(for task: IntelligentEditingEvaluationTask) -> String {
        task.documentContext.contains(task.selectedText) ? task.documentContext : task.selectedText
    }
}
