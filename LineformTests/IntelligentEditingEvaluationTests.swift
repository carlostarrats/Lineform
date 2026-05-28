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
        XCTAssertTrue(IntelligentEditingEvaluationSuite.goldenTasks.contains { $0.userInstruction != nil })
        XCTAssertTrue(
            IntelligentEditingEvaluationSuite.missingRequiredActionLengthPairs.isEmpty,
            "Missing action/length pairs: \(IntelligentEditingEvaluationSuite.missingRequiredActionLengthPairs.sorted().joined(separator: ", "))"
        )
    }

    func testGoldenTasksCoverCriticalUsageScenarios() {
        XCTAssertTrue(
            IntelligentEditingEvaluationSuite.missingRequiredScenarioNames.isEmpty,
            "Missing scenarios: \(IntelligentEditingEvaluationSuite.missingRequiredScenarioNames.sorted().joined(separator: ", "))"
        )
    }

    func testGoldenTasksIncludeUserDirectedInstructionCoverage() throws {
        let task = try XCTUnwrap(IntelligentEditingEvaluationSuite.goldenTasks.first { $0.id == "custom-friendly-rewrite" })

        XCTAssertEqual(task.action, .rewrite)
        XCTAssertEqual(task.userInstruction, "Make this friendlier without adding facts.")
        XCTAssertTrue(IntelligentEditingEvaluationSuite.coveredScenarioNames.contains("input:user-instruction"))
        XCTAssertTrue(IntelligentEditingEvaluationSuite.coveredScenarioNames.contains("input:custom-tone"))
    }

    func testGoldenTasksCoverExpandedCustomInstructionScenarios() {
        let requiredScenarios: Set<String> = [
            "input:custom-word-swap",
            "input:custom-less-corporate",
            "input:custom-simplify",
            "input:custom-active-voice",
            "input:custom-heading-rename",
            "input:custom-markdown-safe"
        ]
        let requiredTaskIDs: Set<String> = [
            "custom-word-swap-rewrite",
            "custom-less-corporate-rewrite",
            "custom-simplify-rewrite",
            "custom-active-voice-rewrite",
            "custom-heading-rename",
            "custom-markdown-safe-list-rewrite"
        ]
        let coveredTaskIDs = Set(IntelligentEditingEvaluationSuite.goldenTasks.map(\.id))

        XCTAssertTrue(
            IntelligentEditingEvaluationSuite.coveredScenarioNames.isSuperset(of: requiredScenarios),
            "Missing custom scenarios: \(requiredScenarios.subtracting(IntelligentEditingEvaluationSuite.coveredScenarioNames).sorted().joined(separator: ", "))"
        )
        XCTAssertTrue(
            coveredTaskIDs.isSuperset(of: requiredTaskIDs),
            "Missing custom tasks: \(requiredTaskIDs.subtracting(coveredTaskIDs).sorted().joined(separator: ", "))"
        )
    }

    func testGoldenTasksCoverExpandedMarkdownAndWritingRiskScenarios() {
        let requiredScenarios: Set<String> = [
            "markdown:link",
            "markdown:table",
            "markdown:blockquote",
            "markdown:numbered-list",
            "markdown:nested-list",
            "markdown:code-only",
            "selection:very-long",
            "selection:weird-whitespace",
            "risk:fact-preservation",
            "language:mixed"
        ]

        XCTAssertTrue(
            IntelligentEditingEvaluationSuite.coveredScenarioNames.isSuperset(of: requiredScenarios),
            "Missing expanded scenarios: \(requiredScenarios.subtracting(IntelligentEditingEvaluationSuite.coveredScenarioNames).sorted().joined(separator: ", "))"
        )
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
        let task = try XCTUnwrap(IntelligentEditingEvaluationSuite.goldenTasks.first { $0.id == "custom-friendly-rewrite" })
        let replacement = "This may briefly affect users during migration."
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
        XCTAssertEqual(evaluation.score, 100)
        XCTAssertEqual(evaluation.qualityBand, "pass")
        XCTAssertTrue(json.contains("\"taskID\" : \"custom-friendly-rewrite\""))
        XCTAssertTrue(json.contains("\"userInstruction\" : \"Make this friendlier without adding facts.\""))
        XCTAssertTrue(json.contains("\"averageScore\" : 100"))
        XCTAssertTrue(json.contains("\"criticalFailureCount\" : 0"))
        XCTAssertTrue(json.contains("\"passed\" : true"))
        XCTAssertTrue(json.contains("\"score\" : 100"))
        XCTAssertTrue(json.contains("\"qualityBand\" : \"pass\""))
        XCTAssertTrue(json.contains(replacement))
        XCTAssertTrue(json.contains("\"failures\" : ["))
    }

    func testLiveEvaluationReportScoresFailuresAndSummarizesResults() throws {
        let task = try XCTUnwrap(IntelligentEditingEvaluationSuite.goldenTasks.first { $0.id == "sentence-rewrite" })
        let passingReplacement = "The launch plan is clear, but final handoff still needs a named owner."
        let failingReplacement = "<<<LINEFORM_OPTION_1>>>"
        let passingEvaluation = IntelligentEditingEvaluationRubric.evaluate(replacement: passingReplacement, task: task)
        let failingEvaluation = IntelligentEditingEvaluationRubric.evaluate(replacement: failingReplacement, task: task)

        let report = LiveIntelligenceEvalReport(records: [
            LiveIntelligenceEvalRecord(task: task, mode: "single", optionIndex: nil, replacement: passingReplacement, evaluation: passingEvaluation),
            LiveIntelligenceEvalRecord(task: task, mode: "single", optionIndex: nil, replacement: failingReplacement, evaluation: failingEvaluation)
        ])
        let data = try JSONEncoder.lineformEvalReportEncoder.encode(report)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertEqual(report.summary.totalRecordCount, 2)
        XCTAssertEqual(report.summary.passedRecordCount, 1)
        XCTAssertEqual(report.summary.failedRecordCount, 1)
        XCTAssertEqual(report.summary.criticalFailureCount, 1)
        XCTAssertEqual(report.summary.passRate, 0.5)
        XCTAssertEqual(report.summary.averageScore, 50)
        XCTAssertEqual(failingEvaluation.score, 0)
        XCTAssertEqual(failingEvaluation.qualityBand, "fail")
        XCTAssertEqual(failingEvaluation.criticalFailureCount, 1)
        XCTAssertTrue(json.contains("\"summary\" : {"))
        XCTAssertTrue(json.contains("\"passRate\" : 0.5"))
        XCTAssertTrue(json.contains("\"averageScore\" : 50"))
        XCTAssertTrue(json.contains("\"qualityBand\" : \"fail\""))
    }

    func testRepeatedLiveEvaluationSummaryFlagsUnstableRunsAndDuplicateOptions() throws {
        let task = try XCTUnwrap(IntelligentEditingEvaluationSuite.goldenTasks.first { $0.id == "sentence-rewrite" })
        let passingEvaluation = IntelligentEditingEvaluationRubric.evaluate(
            replacement: "The launch plan is clear, but the final handoff needs a named owner.",
            task: task
        )
        let failingEvaluation = IntelligentEditingEvaluationRubric.evaluate(
            replacement: "<<<LINEFORM_OPTION_1>>>",
            task: task
        )

        let firstRun = LiveIntelligenceEvalReport(records: [
            LiveIntelligenceEvalRecord(task: task, mode: "options", optionIndex: 0, replacement: "The launch plan is clear, but the final handoff needs a named owner.", evaluation: passingEvaluation),
            LiveIntelligenceEvalRecord(task: task, mode: "options", optionIndex: 1, replacement: "The launch plan is clear, but the final handoff needs a named owner.", evaluation: passingEvaluation)
        ])
        let secondRun = LiveIntelligenceEvalReport(records: [
            LiveIntelligenceEvalRecord(task: task, mode: "options", optionIndex: 0, replacement: "<<<LINEFORM_OPTION_1>>>", evaluation: failingEvaluation)
        ])

        let repeatedReport = RepeatedLiveIntelligenceEvalReport(reports: [firstRun, secondRun])

        XCTAssertEqual(repeatedReport.summary.runCount, 2)
        XCTAssertEqual(repeatedReport.summary.failedRunCount, 2)
        XCTAssertEqual(repeatedReport.summary.criticalFailureCount, 1)
        XCTAssertEqual(repeatedReport.summary.emptyOutputCount, 0)
        XCTAssertEqual(repeatedReport.summary.duplicateOptionCount, 1)
        XCTAssertFalse(repeatedReport.summary.passed)
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

    func testRubricRejectsCustomLessCorporateRewriteThatKeepsCorporateWording() {
        let task = IntelligentEditingEvaluationTask(
            id: "custom-less-corporate-regression",
            action: .rewrite,
            userInstruction: "Make this less corporate.",
            selectedText: "We need stakeholder alignment before execution.",
            documentContext: "We need stakeholder alignment before execution.",
            length: .sentence,
            requiresTransformation: true,
            requiresCompression: false,
            requiresMarkdownPreservation: false
        )

        let result = IntelligentEditingEvaluationRubric.evaluate(
            replacement: "We need stakeholder alignment before we execute.",
            task: task
        )

        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.failures.contains(.userInstructionNotFollowed))
    }

    func testRubricRejectsCustomLessCorporateRewriteThatMentionsStakeholders() {
        let task = IntelligentEditingEvaluationTask(
            id: "custom-less-corporate-live-regression",
            action: .rewrite,
            userInstruction: "Make this less corporate.",
            selectedText: "We need stakeholder alignment before execution.",
            documentContext: "We need stakeholder alignment before execution.",
            length: .sentence,
            requiresTransformation: true,
            requiresCompression: false,
            requiresMarkdownPreservation: false
        )

        let result = IntelligentEditingEvaluationRubric.evaluate(
            replacement: "We need to align with stakeholders before moving forward.",
            task: task
        )

        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.failures.contains(.userInstructionNotFollowed))
    }

    func testRubricRejectsCustomWordSwapThatMissesRequestedReplacement() {
        let task = IntelligentEditingEvaluationTask(
            id: "custom-word-swap-regression",
            action: .rewrite,
            userInstruction: "Replace robust with simple.",
            selectedText: "The robust export flow keeps drafts local.",
            documentContext: "The robust export flow keeps drafts local.",
            length: .sentence,
            requiresTransformation: true,
            requiresCompression: false,
            requiresMarkdownPreservation: false
        )

        let result = IntelligentEditingEvaluationRubric.evaluate(
            replacement: "The reliable export flow keeps drafts local.",
            task: task
        )

        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.failures.contains(.userInstructionNotFollowed))
    }

    func testRubricAcceptsCustomWordSwapThatAppliesRequestedReplacement() {
        let task = IntelligentEditingEvaluationTask(
            id: "custom-word-swap-acceptance",
            action: .rewrite,
            userInstruction: "Replace robust with simple.",
            selectedText: "The robust export flow keeps drafts local.",
            documentContext: "The robust export flow keeps drafts local.",
            length: .sentence,
            requiresTransformation: true,
            requiresCompression: false,
            requiresMarkdownPreservation: false
        )

        let result = IntelligentEditingEvaluationRubric.evaluate(
            replacement: "The simple export flow keeps drafts local.",
            task: task
        )

        XCTAssertTrue(result.passed, result.failureSummary)
    }

    func testRubricAcceptsCustomLessCorporateRewrite() {
        let task = IntelligentEditingEvaluationTask(
            id: "custom-less-corporate-acceptance",
            action: .rewrite,
            userInstruction: "Make this less corporate.",
            selectedText: "We need stakeholder alignment before execution.",
            documentContext: "We need stakeholder alignment before execution.",
            length: .sentence,
            requiresTransformation: true,
            requiresCompression: false,
            requiresMarkdownPreservation: false
        )

        let result = IntelligentEditingEvaluationRubric.evaluate(
            replacement: "We should get everyone on the same page before we start.",
            task: task
        )

        XCTAssertTrue(result.passed, result.failureSummary)
    }

    func testRubricRejectsCustomFriendlierRewriteThatKeepsHarshWording() {
        let task = IntelligentEditingEvaluationTask(
            id: "custom-friendly-live-regression",
            action: .rewrite,
            userInstruction: "Make this friendlier without adding facts.",
            selectedText: "This update may inconvenience users during migration.",
            documentContext: "This update may inconvenience users during migration.",
            length: .sentence,
            requiresTransformation: true,
            requiresCompression: false,
            requiresMarkdownPreservation: false
        )

        for replacement in [
            "This update may cause some inconvenience during migration.",
            "This update may be a bit of a hassle for users during migration.",
            "This update may be a little tricky for some users during the migration.",
            "**This update may briefly affect users during migration.**",
            "**This update may be a little tricky for some users during the migration.**"
        ] {
            let result = IntelligentEditingEvaluationRubric.evaluate(
                replacement: replacement,
                task: task
            )

            XCTAssertFalse(result.passed, replacement)
            XCTAssertTrue(result.failures.contains(.userInstructionNotFollowed), replacement)
        }
    }

    func testRubricRejectsCustomCalmerHeadingThatKeepsOptimizationLanguage() {
        let task = IntelligentEditingEvaluationTask(
            id: "custom-heading-live-regression",
            action: .rewrite,
            userInstruction: "Rename this heading to sound calmer.",
            selectedText: "Workflow Optimization",
            documentContext: "# Workflow Optimization\n\nDraft review settings.",
            length: .oneWord,
            requiresTransformation: true,
            requiresCompression: false,
            requiresMarkdownPreservation: false
        )

        let result = IntelligentEditingEvaluationRubric.evaluate(
            replacement: "Optimization of Workflow",
            task: task
        )

        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.failures.contains(.userInstructionNotFollowed))
    }

    func testRubricRejectsCustomCalmerHeadingThatUsesGenericImprovementLanguage() {
        let task = IntelligentEditingEvaluationTask(
            id: "custom-heading-improvement-regression",
            action: .rewrite,
            userInstruction: "Rename this heading to sound calmer.",
            selectedText: "Workflow Optimization",
            documentContext: "# Workflow Optimization\n\nDraft review settings.",
            length: .oneWord,
            requiresTransformation: true,
            requiresCompression: false,
            requiresMarkdownPreservation: false
        )

        for replacement in ["Workflow Enhancement", "Workflow Improvement", "Improved Workflow", "Workflow Simplification", "Workflow Streamlining"] {
            let result = IntelligentEditingEvaluationRubric.evaluate(
                replacement: replacement,
                task: task
            )

            XCTAssertFalse(result.passed, replacement)
            XCTAssertTrue(result.failures.contains(.userInstructionNotFollowed), replacement)
        }
    }

    func testRubricRejectsCustomSimplifyRewriteThatKeepsJargon() {
        let task = IntelligentEditingEvaluationTask(
            id: "custom-simplify-regression",
            action: .rewrite,
            userInstruction: "Simplify this for a non-technical reader.",
            selectedText: "The synchronization layer persists local file metadata before reconciliation.",
            documentContext: "The synchronization layer persists local file metadata before reconciliation.",
            length: .sentence,
            requiresTransformation: true,
            requiresCompression: false,
            requiresMarkdownPreservation: false
        )

        let result = IntelligentEditingEvaluationRubric.evaluate(
            replacement: "The synchronization layer persists metadata before reconciliation.",
            task: task
        )

        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.failures.contains(.userInstructionNotFollowed))
    }

    func testRubricRejectsCustomActiveVoiceRewriteThatStaysPassive() {
        let task = IntelligentEditingEvaluationTask(
            id: "custom-active-voice-regression",
            action: .rewrite,
            userInstruction: "Make this active voice.",
            selectedText: "The final draft was reviewed by the editor before export.",
            documentContext: "The final draft was reviewed by the editor before export.",
            length: .sentence,
            requiresTransformation: true,
            requiresCompression: false,
            requiresMarkdownPreservation: false
        )

        let result = IntelligentEditingEvaluationRubric.evaluate(
            replacement: "The final draft was carefully reviewed by the editor before export.",
            task: task
        )

        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.failures.contains(.userInstructionNotFollowed))
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

    func testRubricRejectsGenericLineformProtocolTags() throws {
        let task = try XCTUnwrap(IntelligentEditingEvaluationSuite.goldenTasks.first { $0.id == "sentence-rewrite" })

        let result = IntelligentEditingEvaluationRubric.evaluate(
            replacement: "<<<LINEFORM_SELECTED_TEXT>>>",
            task: task
        )

        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.failures.contains(.placeholderOrDummyText))
    }

    func testRubricRejectsApologyOrExplanationInsteadOfReplacement() throws {
        let task = try XCTUnwrap(IntelligentEditingEvaluationSuite.goldenTasks.first { $0.id == "sentence-rewrite" })

        let result = IntelligentEditingEvaluationRubric.evaluate(
            replacement: "I can rewrite this for you: The launch plan is clear, but the final handoff needs a named owner.",
            task: task
        )

        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.failures.contains(.placeholderOrDummyText))
    }

    func testRubricRejectsRewriteThatInventsStorageOrSyncFacts() throws {
        let task = try XCTUnwrap(IntelligentEditingEvaluationSuite.goldenTasks.first { $0.id == "fact-preserving-rewrite" })

        let result = IntelligentEditingEvaluationRubric.evaluate(
            replacement: "Lineform syncs every Markdown file to a private cloud database so teams can collaborate from anywhere.",
            task: task
        )

        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.failures.contains(.lowQualityReplacement))
    }

    func testRubricRejectsRewriteThatMovesLocalFilesToCloudStorage() throws {
        let task = try XCTUnwrap(IntelligentEditingEvaluationSuite.goldenTasks.first { $0.id == "fact-preserving-rewrite" })

        let result = IntelligentEditingEvaluationRubric.evaluate(
            replacement: "Lineform stores Markdown files in iCloud cloud storage so writers can access drafts from anywhere.",
            task: task
        )

        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.failures.contains(.lowQualityReplacement))
    }

    func testRubricRejectsProofreadThatReversesLocalPrivacyMeaning() throws {
        let task = try XCTUnwrap(IntelligentEditingEvaluationSuite.goldenTasks.first { $0.id == "privacy-proofread" })

        let result = IntelligentEditingEvaluationRubric.evaluate(
            replacement: "The editor uploads drafts before writers can keep working locally.",
            task: task
        )

        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.failures.contains(.proofreadChangedMeaningOrStyle))
    }

    func testRubricAllowsValidNoOpProofreadForAlreadyCorrectPrivacySentence() throws {
        let task = try XCTUnwrap(IntelligentEditingEvaluationSuite.goldenTasks.first { $0.id == "privacy-proofread" })

        let result = IntelligentEditingEvaluationRubric.evaluate(
            replacement: "The editor does not upload drafts before writers can keep working locally.",
            task: task
        )

        XCTAssertTrue(result.passed, result.failureSummary)
    }

    func testRubricRejectsCleanMarkdownThatDamagesTableShape() throws {
        let task = try XCTUnwrap(IntelligentEditingEvaluationSuite.goldenTasks.first { $0.id == "table-clean-markdown" })

        let result = IntelligentEditingEvaluationRubric.evaluate(
            replacement: """
            | Setting | Purpose |
            | Type size | Adjust reading scale |
            | Line height | Improve long-session rhythm |
            """,
            task: task
        )

        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.failures.contains(.markdownStructureNotPreserved))
    }

    func testRubricAllowsCleanMarkdownThatOnlyNormalizesTableSpacing() throws {
        let task = try XCTUnwrap(IntelligentEditingEvaluationSuite.goldenTasks.first { $0.id == "table-clean-markdown" })

        let result = IntelligentEditingEvaluationRubric.evaluate(
            replacement: """
            | Setting | Purpose |
            | --- | --- |
            | Type size | Adjust reading scale |
            | Line height | Improve long-session rhythm |
            """,
            task: task
        )

        XCTAssertTrue(result.passed, result.failureSummary)
    }

    func testRubricRejectsDroppedOrderedListMarkersWhenMarkdownMustBePreserved() {
        let task = IntelligentEditingEvaluationTask(
            id: "ordered-list-preservation",
            action: .rewrite,
            selectedText: "1. Keep files local.\n2. Preserve Markdown structure.",
            documentContext: "1. Keep files local.\n2. Preserve Markdown structure.",
            length: .paragraph,
            requiresTransformation: true,
            requiresCompression: false,
            requiresMarkdownPreservation: true
        )

        let result = IntelligentEditingEvaluationRubric.evaluate(
            replacement: "Keep files local.\nPreserve Markdown structure.",
            task: task
        )

        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.failures.contains(.markdownStructureNotPreserved))
    }

    func testRubricRejectsDroppedMarkdownLinksWhenMarkdownMustBePreserved() {
        let task = IntelligentEditingEvaluationTask(
            id: "link-preservation",
            action: .rewrite,
            selectedText: "Open [release notes](https://example.com) before shipping.",
            documentContext: "Open [release notes](https://example.com) before shipping.",
            length: .sentence,
            requiresTransformation: true,
            requiresCompression: false,
            requiresMarkdownPreservation: true
        )

        let result = IntelligentEditingEvaluationRubric.evaluate(
            replacement: "Open release notes before shipping.",
            task: task
        )

        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.failures.contains(.markdownStructureNotPreserved))
    }

    func testRubricAllowsCleanMarkdownWithSpacedLevelTwoHeading() throws {
        let task = try XCTUnwrap(IntelligentEditingEvaluationSuite.goldenTasks.first { $0.id == "weird-whitespace-clean-markdown" })

        let result = IntelligentEditingEvaluationRubric.evaluate(
            replacement: "## Title\n\n- First item\n- Second item",
            task: task
        )

        XCTAssertTrue(result.passed, result.failureSummary)
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

    func testRubricRejectsCleanMarkdownThatLeavesHeadingSpacingUnfixed() throws {
        let task = try XCTUnwrap(IntelligentEditingEvaluationSuite.goldenTasks.first { $0.id == "frontmatter-clean-markdown" })

        let result = IntelligentEditingEvaluationRubric.evaluate(
            replacement: """
            ---
            title: Draft
            ---

            #Title

            - First item
            - Second item
            """,
            task: task
        )

        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.failures.contains(.lowQualityReplacement))
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
            replacement: "The launch plan is clear, but final handoff is still somewhat in someone's hands.",
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

        let report = await Self.liveFoundationModelsEvaluationReport(mode: "single")
        let reportURL = Self.liveEvaluationReportURL(for: "single")
        try report.write(to: reportURL)
        add(try report.attachment(named: "lineform-intelligence-live-eval-single.json"))

        let failures = report.failureSummaries
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testLiveFoundationModelsOptionEvalIsOptIn() async throws {
        guard Self.shouldRunLiveFoundationModelsEval else {
            throw XCTSkip("Set LINEFORM_RUN_LIVE_INTELLIGENCE_EVALS=1 or create /private/tmp/lineform-run-live-intelligence-evals to run live Apple Intelligence evals.")
        }

        let report = await Self.liveFoundationModelsEvaluationReport(mode: "options")
        let reportURL = Self.liveEvaluationReportURL(for: "options")
        try report.write(to: reportURL)
        add(try report.attachment(named: "lineform-intelligence-live-eval-options.json"))

        let failures = report.failureSummaries
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testRepeatedLiveFoundationModelsEvalIsOptIn() async throws {
        guard Self.shouldRunRepeatedLiveFoundationModelsEval else {
            throw XCTSkip("Set LINEFORM_RUN_REPEATED_LIVE_INTELLIGENCE_EVALS=1 or create /private/tmp/lineform-run-repeated-live-intelligence-evals to run repeated live Apple Intelligence evals.")
        }

        var reports: [LiveIntelligenceEvalReport] = []
        for _ in 0..<Self.liveFoundationModelsRepeatCount {
            reports.append(await Self.liveFoundationModelsEvaluationReport(mode: "single"))
            reports.append(await Self.liveFoundationModelsEvaluationReport(mode: "options"))
        }

        let repeatedReport = RepeatedLiveIntelligenceEvalReport(reports: reports)
        let reportURL = Self.liveEvaluationReportURL(for: "repeated")
        try repeatedReport.write(to: reportURL)
        add(try repeatedReport.attachment(named: "lineform-intelligence-live-eval-repeated.json"))

        let failures = reports.flatMap(\.failureSummaries)
        XCTAssertTrue(
            repeatedReport.summary.passed,
            """
            repeated live eval failed:
            runCount=\(repeatedReport.summary.runCount)
            failedRunCount=\(repeatedReport.summary.failedRunCount)
            failedRecordCount=\(repeatedReport.summary.failedRecordCount)
            criticalFailureCount=\(repeatedReport.summary.criticalFailureCount)
            emptyOutputCount=\(repeatedReport.summary.emptyOutputCount)
            duplicateOptionCount=\(repeatedReport.summary.duplicateOptionCount)
            averageScore=\(repeatedReport.summary.averageScore)
            \(failures.joined(separator: "\n"))
            """
        )
    }

    private static func liveFoundationModelsEvaluationReport(mode: String) async -> LiveIntelligenceEvalReport {
        let runner = IntelligentEditingRunner(service: FoundationModelsIntelligentEditingService())
        var records: [LiveIntelligenceEvalRecord] = []

        for task in IntelligentEditingEvaluationSuite.liveTasks {
            let documentText = Self.documentText(for: task)
            let selectedRange = (documentText as NSString).range(of: task.selectedText)
            guard selectedRange.location != NSNotFound else {
                records.append(LiveIntelligenceEvalRecord(task: task, mode: mode, optionIndex: nil, failure: "selected text was not present in live eval document"))
                continue
            }

            do {
                let optionCount = mode == "options"
                    ? IntelligentEditingPresentationPolicy.optionCount(for: Self.request(for: task), selectedText: task.selectedText)
                    : 1
                let suggestions: [IntelligentEditingSuggestion]
                if optionCount > 1 {
                    suggestions = try await runner.runOptions(
                        request: Self.request(for: task),
                        documentText: documentText,
                        selectedRange: selectedRange,
                        optionCount: optionCount
                    )
                } else {
                    suggestions = [
                        try await runner.run(
                            request: Self.request(for: task),
                            documentText: documentText,
                            selectedRange: selectedRange
                        )
                    ]
                }
                let replacements = suggestions.map(\.replacementText)

                if replacements.count != optionCount {
                    records.append(LiveIntelligenceEvalRecord(task: task, mode: mode, optionIndex: nil, failure: "expected \(optionCount) options, received \(replacements.count)"))
                }

                let uniqueReplacements = Set(replacements.map(Self.normalized))
                if mode == "options", uniqueReplacements.count != replacements.count {
                    records.append(LiveIntelligenceEvalRecord(task: task, mode: mode, optionIndex: nil, failure: "duplicate option text"))
                }

                for (index, replacement) in replacements.enumerated() {
                    let result = IntelligentEditingEvaluationRubric.evaluate(replacement: replacement, task: task)
                    records.append(LiveIntelligenceEvalRecord(task: task, mode: mode, optionIndex: mode == "options" ? index + 1 : nil, replacement: replacement, evaluation: result))
                }
            } catch {
                records.append(LiveIntelligenceEvalRecord(task: task, mode: mode, optionIndex: nil, failure: error.localizedDescription))
            }
        }

        return LiveIntelligenceEvalReport(records: records)
    }

    private static var shouldRunLiveFoundationModelsEval: Bool {
        ProcessInfo.processInfo.environment["LINEFORM_RUN_LIVE_INTELLIGENCE_EVALS"] == "1"
            || FileManager.default.fileExists(atPath: "/private/tmp/lineform-run-live-intelligence-evals")
    }

    private static var shouldRunRepeatedLiveFoundationModelsEval: Bool {
        ProcessInfo.processInfo.environment["LINEFORM_RUN_REPEATED_LIVE_INTELLIGENCE_EVALS"] == "1"
            || FileManager.default.fileExists(atPath: "/private/tmp/lineform-run-repeated-live-intelligence-evals")
    }

    private static var liveFoundationModelsRepeatCount: Int {
        let configured = ProcessInfo.processInfo.environment["LINEFORM_LIVE_INTELLIGENCE_REPEAT_COUNT"].flatMap(Int.init) ?? 2
        return max(2, configured)
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

    private static func request(for task: IntelligentEditingEvaluationTask) -> IntelligentEditingRequest {
        if let userInstruction = task.userInstruction {
            return .custom(userInstruction)
        }

        return .action(task.action)
    }

    private static func liveEvaluationReportURL(for mode: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lineform-intelligence-live-eval-\(mode).json")
    }
}

private struct LiveIntelligenceEvalReport: Codable {
    let generatedAt: String
    let summary: LiveIntelligenceEvalSummary
    let records: [LiveIntelligenceEvalRecord]

    init(records: [LiveIntelligenceEvalRecord]) {
        self.generatedAt = ISO8601DateFormatter().string(from: Date())
        self.summary = LiveIntelligenceEvalSummary(records: records)
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

    func attachment(named name: String) throws -> XCTAttachment {
        let data = try JSONEncoder.lineformEvalReportEncoder.encode(self)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = name
        attachment.lifetime = .keepAlways
        return attachment
    }
}

private struct LiveIntelligenceEvalSummary: Codable {
    let totalRecordCount: Int
    let passedRecordCount: Int
    let failedRecordCount: Int
    let criticalFailureCount: Int
    let passRate: Double
    let averageScore: Double

    init(records: [LiveIntelligenceEvalRecord]) {
        totalRecordCount = records.count
        passedRecordCount = records.filter(\.passed).count
        failedRecordCount = totalRecordCount - passedRecordCount
        criticalFailureCount = records.reduce(0) { $0 + $1.criticalFailureCount }

        if totalRecordCount == 0 {
            passRate = 0
            averageScore = 0
        } else {
            passRate = Double(passedRecordCount) / Double(totalRecordCount)
            averageScore = Double(records.reduce(0) { $0 + $1.score }) / Double(totalRecordCount)
        }
    }
}

private struct RepeatedLiveIntelligenceEvalReport: Codable {
    let generatedAt: String
    let summary: RepeatedLiveIntelligenceEvalSummary
    let reports: [LiveIntelligenceEvalReport]

    init(reports: [LiveIntelligenceEvalReport]) {
        self.generatedAt = ISO8601DateFormatter().string(from: Date())
        self.summary = RepeatedLiveIntelligenceEvalSummary(reports: reports)
        self.reports = reports
    }

    func write(to url: URL) throws {
        let data = try JSONEncoder.lineformEvalReportEncoder.encode(self)
        try data.write(to: url, options: .atomic)
    }

    func attachment(named name: String) throws -> XCTAttachment {
        let data = try JSONEncoder.lineformEvalReportEncoder.encode(self)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = name
        attachment.lifetime = .keepAlways
        return attachment
    }
}

private struct RepeatedLiveIntelligenceEvalSummary: Codable {
    let runCount: Int
    let failedRunCount: Int
    let totalRecordCount: Int
    let failedRecordCount: Int
    let criticalFailureCount: Int
    let emptyOutputCount: Int
    let duplicateOptionCount: Int
    let averageScore: Double

    var passed: Bool {
        failedRunCount == 0
            && failedRecordCount == 0
            && criticalFailureCount == 0
            && emptyOutputCount == 0
            && duplicateOptionCount == 0
            && averageScore == 100
    }

    init(reports: [LiveIntelligenceEvalReport]) {
        runCount = reports.count
        failedRunCount = reports.filter { $0.summary.failedRecordCount > 0 || Self.duplicateOptionCount(in: $0.records) > 0 }.count
        totalRecordCount = reports.reduce(0) { $0 + $1.summary.totalRecordCount }
        failedRecordCount = reports.reduce(0) { $0 + $1.summary.failedRecordCount }
        criticalFailureCount = reports.reduce(0) { $0 + $1.summary.criticalFailureCount }
        emptyOutputCount = reports.reduce(0) { partial, report in
            partial + report.records.filter { $0.replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        }
        duplicateOptionCount = reports.reduce(0) { $0 + Self.duplicateOptionCount(in: $1.records) }

        if reports.isEmpty {
            averageScore = 0
        } else {
            averageScore = reports.reduce(0) { $0 + $1.summary.averageScore } / Double(reports.count)
        }
    }

    private static func duplicateOptionCount(in records: [LiveIntelligenceEvalRecord]) -> Int {
        let grouped = Dictionary(grouping: records.filter { $0.mode == "options" && $0.optionIndex != nil }) { record in
            record.taskID
        }

        return grouped.values.reduce(0) { duplicateCount, taskRecords in
            let normalized = taskRecords.map { $0.replacement.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            return duplicateCount + (normalized.count - Set(normalized).count)
        }
    }
}

private struct LiveIntelligenceEvalRecord: Codable {
    let taskID: String
    let action: String
    let userInstruction: String?
    let length: String
    let mode: String
    let optionIndex: Int?
    let selectedText: String
    let documentContext: String
    let replacement: String
    let passed: Bool
    let failures: [String]
    let score: Int
    let qualityBand: String
    let criticalFailureCount: Int

    init(
        task: IntelligentEditingEvaluationTask,
        mode: String,
        optionIndex: Int?,
        replacement: String,
        evaluation: IntelligentEditingEvaluationResult
    ) {
        self.taskID = task.id
        self.action = task.action.rawValue
        self.userInstruction = task.userInstruction
        self.length = task.length.rawValue
        self.mode = mode
        self.optionIndex = optionIndex
        self.selectedText = task.selectedText
        self.documentContext = task.documentContext
        self.replacement = replacement
        self.passed = evaluation.passed
        self.failures = evaluation.failures.map(\.rawValue)
        self.score = evaluation.score
        self.qualityBand = evaluation.qualityBand
        self.criticalFailureCount = evaluation.criticalFailureCount
    }

    init(task: IntelligentEditingEvaluationTask, mode: String, optionIndex: Int?, failure: String) {
        self.taskID = task.id
        self.action = task.action.rawValue
        self.userInstruction = task.userInstruction
        self.length = task.length.rawValue
        self.mode = mode
        self.optionIndex = optionIndex
        self.selectedText = task.selectedText
        self.documentContext = task.documentContext
        self.replacement = ""
        self.passed = false
        self.failures = [failure]
        self.score = 0
        self.qualityBand = "fail"
        self.criticalFailureCount = 1
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
