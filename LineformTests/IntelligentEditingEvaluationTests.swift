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
            "rewrite:multipleParagraphs",
            "proofread:oneWord",
            "proofread:sentence",
            "proofread:paragraph",
            "proofread:multipleParagraphs",
            "shorten:sentence",
            "shorten:paragraph",
            "shorten:multipleParagraphs",
            "summarize:sentence",
            "summarize:paragraph",
            "summarize:multipleParagraphs",
            "cleanMarkdown:paragraph",
            "cleanMarkdown:multipleParagraphs"
        ]))
    }

    func testGoldenTasksIncludeUserVisibleSelectedListItemRewrite() throws {
        let task = try XCTUnwrap(IntelligentEditingEvaluationSuite.goldenTasks.first { $0.id == "selected-list-item-rewrite" })

        XCTAssertEqual(task.action, .rewrite)
        XCTAssertEqual(task.length, .sentence)
        XCTAssertEqual(task.selectedText, "- Real Markdown files that remain portable across Finder, iCloud Drive, Git, and other editors.")
        XCTAssertTrue(task.requiresTransformation)
        XCTAssertTrue(task.requiresMarkdownPreservation)
        XCTAssertTrue(task.documentContext.contains(task.selectedText))
    }

    func testLiveEvaluationReportCapturesSuccessfulReplacementText() throws {
        let task = try XCTUnwrap(IntelligentEditingEvaluationSuite.goldenTasks.first { $0.id == "sentence-rewrite" })
        let replacement = "The launch plan is clear, but the final handoff needs a named owner."
        let evaluation = IntelligentEditingEvaluationRubric.evaluate(replacement: replacement, task: task)
        let record = LiveIntelligenceEvalRecord(
            task: task,
            mode: "single",
            optionIndex: nil,
            replacement: replacement,
            evaluation: evaluation
        )
        let report = LiveIntelligenceEvalReport(records: [record])
        let data = try JSONEncoder.lineformEvalReportEncoder.encode(report)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(evaluation.passed)
        XCTAssertTrue(json.contains("\"taskID\" : \"sentence-rewrite\""))
        XCTAssertTrue(json.contains("\"passed\" : true"))
        XCTAssertTrue(json.contains(replacement))
        XCTAssertTrue(json.contains("\"failures\" : ["))
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

    func testRubricRejectsIncorrectKnownOneWordProofreadCorrection() throws {
        let task = try XCTUnwrap(IntelligentEditingEvaluationSuite.goldenTasks.first { $0.id == "one-word-proofread" })

        let result = IntelligentEditingEvaluationRubric.evaluate(
            replacement: "Theh",
            task: task
        )

        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.failures.contains(.proofreadChangedMeaningOrStyle))
    }

    func testRubricRejectsKnownBadSingularProofreadGrammar() throws {
        let task = try XCTUnwrap(IntelligentEditingEvaluationSuite.goldenTasks.first { $0.id == "multiple-paragraph-proofread" })

        let result = IntelligentEditingEvaluationRubric.evaluate(
            replacement: """
            The editor keeps drafts local and don't change Markdown syntax.

            Writers don't need to upload files before they can edit.
            """,
            task: task
        )

        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.failures.contains(.lowQualityReplacement))
    }

    func testRubricRejectsProofreadThatReordersParagraphs() throws {
        let task = try XCTUnwrap(IntelligentEditingEvaluationSuite.goldenTasks.first { $0.id == "multiple-paragraph-proofread" })

        let result = IntelligentEditingEvaluationRubric.evaluate(
            replacement: """
            Writers don't need to upload files before they can edit.

            The editor keeps drafts local and doesn't change Markdown syntax.
            """,
            task: task
        )

        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.failures.contains(.proofreadChangedMeaningOrStyle))
    }

    func testRubricRejectsProofreadThatReversesNegation() throws {
        let task = try XCTUnwrap(IntelligentEditingEvaluationSuite.goldenTasks.first { $0.id == "markdown-list-proofread" })

        let result = IntelligentEditingEvaluationRubric.evaluate(
            replacement: """
            - The editor keeps files local.
            - Writers **do** need a database.
            """,
            task: task
        )

        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.failures.contains(.lowQualityReplacement))
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

    func testRubricRejectsCleanMarkdownThatDropsFrontMatterDelimiter() throws {
        let task = try XCTUnwrap(IntelligentEditingEvaluationSuite.goldenTasks.first { $0.id == "frontmatter-clean-markdown" })

        let result = IntelligentEditingEvaluationRubric.evaluate(
            replacement: """
            title: Draft
            ---

            #Title

            -  First item
            -    Second item
            """,
            task: task
        )

        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.failures.contains(.markdownStructureNotPreserved))
    }

    func testRubricRejectsCleanMarkdownThatChangesHeadingLevel() throws {
        let task = try XCTUnwrap(IntelligentEditingEvaluationSuite.goldenTasks.first { $0.id == "multiple-paragraph-clean-markdown" })

        let result = IntelligentEditingEvaluationRubric.evaluate(
            replacement: """
            ## Release notes

            - Fixed typo
            - Improved spacing

            ```swift
            let value = 1
            ```
            """,
            task: task
        )

        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.failures.contains(.markdownStructureNotPreserved))
    }

    func testRubricRejectsWeakCompressionUnderTwentyFivePercent() throws {
        let task = try XCTUnwrap(IntelligentEditingEvaluationSuite.goldenTasks.first { $0.id == "sentence-summarize" })

        let result = IntelligentEditingEvaluationRubric.evaluate(
            replacement: "Lineform provides a quiet native editor for Markdown files, ensuring portability across Finder, iCloud Drive, Git, and other tools.",
            task: task
        )

        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.failures.contains(.missingCompression))
    }

    func testRubricRejectsMultipleParagraphCompressionThatDropsAParagraphsMeaning() throws {
        let task = try XCTUnwrap(IntelligentEditingEvaluationSuite.goldenTasks.first { $0.id == "multiple-paragraph-summary" })

        let result = IntelligentEditingEvaluationRubric.evaluate(
            replacement: "The first release focuses on local Markdown editing with strong reading controls.",
            task: task
        )

        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.failures.contains(.missingCompression))
    }

    func testRubricRejectsMisspelledShortRewrite() throws {
        let task = try XCTUnwrap(IntelligentEditingEvaluationSuite.goldenTasks.first { $0.id == "short-phrase-rewrite-title" })

        let result = IntelligentEditingEvaluationRubric.evaluate(
            replacement: "clarer prose",
            task: task
        )

        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.failures.contains(.lowQualityReplacement))
    }

    func testRubricRejectsAwkwardSentenceRewrite() throws {
        let task = try XCTUnwrap(IntelligentEditingEvaluationSuite.goldenTasks.first { $0.id == "sentence-rewrite" })

        let result = IntelligentEditingEvaluationRubric.evaluate(
            replacement: "The launch plan is clear, but the final handoff is still somewhat controlled by someone.",
            task: task
        )

        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.failures.contains(.lowQualityReplacement))
    }

    func testRubricRejectsRewriteThatDropsCoreDetails() throws {
        let task = try XCTUnwrap(IntelligentEditingEvaluationSuite.goldenTasks.first { $0.id == "multiple-paragraph-rewrite" })

        let result = IntelligentEditingEvaluationRubric.evaluate(
            replacement: "Reading mode aims to make the draft easier to read for a longer time.",
            task: task
        )

        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.failures.contains(.lowQualityReplacement))
    }

    func testRubricRejectsMultipleParagraphRewriteThatDropsAParagraphsMeaning() throws {
        let task = try XCTUnwrap(IntelligentEditingEvaluationSuite.goldenTasks.first { $0.id == "multiple-paragraph-rewrite" })

        let result = IntelligentEditingEvaluationRubric.evaluate(
            replacement: "Reading mode should help people stay with a draft longer, but the controls are currently described in a way that feels a little scattered.",
            task: task
        )

        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.failures.contains(.lowQualityReplacement))
    }

    func testRubricAcceptsMultipleParagraphReadingModeRewriteFallbacks() throws {
        let task = try XCTUnwrap(IntelligentEditingEvaluationSuite.goldenTasks.first { $0.id == "multiple-paragraph-rewrite" })
        let replacements = [
            "Reading mode should help people stay with a draft longer by making currently scattered controls feel coherent across type size, line height, themes, margins, focus settings, and the reading system.",
            "Reading mode should help people stay with a draft longer by describing scattered controls as one coherent reading system for type size, line height, themes, margins, and focus settings.",
            "Reading mode should make draft controls feel less scattered, helping people stay longer while type size, line height, themes, margins, and focus settings sound like one coherent reading system."
        ]

        for replacement in replacements {
            let result = IntelligentEditingEvaluationRubric.evaluate(replacement: replacement, task: task)
            XCTAssertTrue(result.passed, result.failureSummary)
        }
    }

    func testRubricAcceptsCleanMarkdownThatOnlyNormalizesListSpacing() throws {
        let task = try XCTUnwrap(IntelligentEditingEvaluationSuite.goldenTasks.first { $0.id == "markdown-list-clean-markdown" })

        let result = IntelligentEditingEvaluationRubric.evaluate(
            replacement: """
            - First item
            - Second item
            """,
            task: task
        )

        XCTAssertTrue(result.passed, result.failureSummary)
    }

    func testRubricRejectsCleanMarkdownThatAttachesCodeFenceToList() throws {
        let task = try XCTUnwrap(IntelligentEditingEvaluationSuite.goldenTasks.first { $0.id == "multiple-paragraph-clean-markdown" })

        let result = IntelligentEditingEvaluationRubric.evaluate(
            replacement: """
            # Release notes

            - Fixed typo
            - Improved spacing
            ```swift
            let value = 1
            ```
            """,
            task: task
        )

        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.failures.contains(.markdownStructureNotPreserved))
    }

    func testRubricRejectsCleanMarkdownThatChangesListNesting() throws {
        let task = try XCTUnwrap(IntelligentEditingEvaluationSuite.goldenTasks.first { $0.id == "markdown-list-clean-markdown" })

        let result = IntelligentEditingEvaluationRubric.evaluate(
            replacement: """
            - First item
              - Second item
            """,
            task: task
        )

        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.failures.contains(.markdownStructureNotPreserved))
    }

    func testRubricRejectsCleanMarkdownThatSplitsAdjacentListItems() throws {
        let task = try XCTUnwrap(IntelligentEditingEvaluationSuite.goldenTasks.first { $0.id == "markdown-list-clean-markdown" })

        let result = IntelligentEditingEvaluationRubric.evaluate(
            replacement: """
            - First item

            - Second item
            """,
            task: task
        )

        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.failures.contains(.markdownStructureNotPreserved))
    }

    func testLiveFoundationModelsEvalIsOptIn() async throws {
        guard Self.shouldRunLiveFoundationModelsEval else {
            throw XCTSkip("Set LINEFORM_RUN_LIVE_INTELLIGENCE_EVALS=1 or create /private/tmp/lineform-run-live-intelligence-evals to run live Apple Intelligence evals.")
        }

        let runner = IntelligentEditingRunner(service: FoundationModelsIntelligentEditingService())
        var records: [LiveIntelligenceEvalRecord] = []

        for task in IntelligentEditingEvaluationSuite.liveTasks {
            let documentText = Self.documentText(for: task)
            let selectedRange = (documentText as NSString).range(of: task.selectedText)
            guard selectedRange.location != NSNotFound else {
                records.append(LiveIntelligenceEvalRecord(task: task, mode: "single", optionIndex: nil, failure: "selected text was not present in live eval document"))
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
                records.append(LiveIntelligenceEvalRecord(task: task, mode: "single", optionIndex: nil, replacement: replacement, evaluation: result))
            } catch {
                records.append(LiveIntelligenceEvalRecord(task: task, mode: "single", optionIndex: nil, failure: error.localizedDescription))
            }
        }

        let report = LiveIntelligenceEvalReport(records: records)
        let reportURL = Self.liveEvaluationReportURL(for: "single")
        try report.write(to: reportURL)

        let failures = report.failureSummaries
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testLiveFoundationModelsOptionEvalIsOptIn() async throws {
        guard Self.shouldRunLiveFoundationModelsEval else {
            throw XCTSkip("Set LINEFORM_RUN_LIVE_INTELLIGENCE_EVALS=1 or create /private/tmp/lineform-run-live-intelligence-evals to run live Apple Intelligence evals.")
        }

        let runner = IntelligentEditingRunner(service: FoundationModelsIntelligentEditingService())
        var records: [LiveIntelligenceEvalRecord] = []

        for task in IntelligentEditingEvaluationSuite.liveTasks {
            let documentText = Self.documentText(for: task)
            let selectedRange = (documentText as NSString).range(of: task.selectedText)
            guard selectedRange.location != NSNotFound else {
                records.append(LiveIntelligenceEvalRecord(task: task, mode: "options", optionIndex: nil, failure: "selected text was not present in live eval document"))
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
                    records.append(LiveIntelligenceEvalRecord(task: task, mode: "options", optionIndex: nil, failure: "expected \(optionCount) options, received \(replacements.count)"))
                }

                let uniqueReplacements = Set(replacements.map(Self.normalized))
                if uniqueReplacements.count != replacements.count {
                    records.append(LiveIntelligenceEvalRecord(task: task, mode: "options", optionIndex: nil, failure: "duplicate option text"))
                }

                for (index, replacement) in replacements.enumerated() {
                    let result = IntelligentEditingEvaluationRubric.evaluate(replacement: replacement, task: task)
                    records.append(LiveIntelligenceEvalRecord(task: task, mode: "options", optionIndex: index + 1, replacement: replacement, evaluation: result))
                }
            } catch {
                records.append(LiveIntelligenceEvalRecord(task: task, mode: "options", optionIndex: nil, failure: error.localizedDescription))
            }
        }

        let report = LiveIntelligenceEvalReport(records: records)
        let reportURL = Self.liveEvaluationReportURL(for: "options")
        try report.write(to: reportURL)

        let failures = report.failureSummaries
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

    private static func liveEvaluationReportURL(for mode: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lineform-intelligence-live-eval-\(mode).json")
    }
}

private struct LiveIntelligenceEvalReport: Codable {
    let generatedAt: String
    let records: [LiveIntelligenceEvalRecord]

    init(records: [LiveIntelligenceEvalRecord]) {
        self.generatedAt = ISO8601DateFormatter().string(from: Date())
        self.records = records
    }

    var failureSummaries: [String] {
        records
            .filter { !$0.passed }
            .map { record in
                "\(record.taskID)\(record.optionIndex.map { " option \($0)" } ?? ""): \(record.failures.joined(separator: ", ")) | \(record.replacementPreview)"
            }
    }

    func write(to url: URL) throws {
        let data = try JSONEncoder.lineformEvalReportEncoder.encode(self)
        try data.write(to: url, options: .atomic)
    }
}

private struct LiveIntelligenceEvalRecord: Codable {
    let taskID: String
    let action: String
    let length: String
    let mode: String
    let optionIndex: Int?
    let selectedText: String
    let documentContext: String
    let replacement: String
    let passed: Bool
    let failures: [String]

    init(
        task: IntelligentEditingEvaluationTask,
        mode: String,
        optionIndex: Int?,
        replacement: String,
        evaluation: IntelligentEditingEvaluationResult
    ) {
        self.taskID = task.id
        self.action = task.action.rawValue
        self.length = task.length.rawValue
        self.mode = mode
        self.optionIndex = optionIndex
        self.selectedText = task.selectedText
        self.documentContext = task.documentContext
        self.replacement = replacement
        self.passed = evaluation.passed
        self.failures = evaluation.failures.map(\.rawValue)
    }

    init(task: IntelligentEditingEvaluationTask, mode: String, optionIndex: Int?, failure: String) {
        self.taskID = task.id
        self.action = task.action.rawValue
        self.length = task.length.rawValue
        self.mode = mode
        self.optionIndex = optionIndex
        self.selectedText = task.selectedText
        self.documentContext = task.documentContext
        self.replacement = ""
        self.passed = false
        self.failures = [failure]
    }

    var replacementPreview: String {
        let trimmed = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 160 else {
            return trimmed
        }

        return "\(trimmed.prefix(160))..."
    }
}

private extension JSONEncoder {
    static var lineformEvalReportEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
