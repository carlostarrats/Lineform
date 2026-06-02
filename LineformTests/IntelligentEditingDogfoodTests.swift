import XCTest
@testable import Lineform

final class IntelligentEditingDogfoodTests: XCTestCase {
    func testLiveDogfoodEvalIsOptIn() async throws {
        guard Self.shouldRunLiveDogfoodEval else {
            throw XCTSkip("Create /private/tmp/lineform-run-live-dogfood-evals to run live dogfood evals.")
        }

        let report = await Self.liveDogfoodReport()
        let reportURL = Self.dogfoodReportURL
        try report.write(to: reportURL)
        add(try report.attachment(named: "lineform-intelligence-dogfood-report.json"))

        XCTAssertTrue(
            report.summary.passed,
            """
            dogfood eval failed:
            totalCaseCount=\(report.summary.totalCaseCount)
            passedCaseCount=\(report.summary.passedCaseCount)
            failedCaseCount=\(report.summary.failedCaseCount)
            providerFailureCount=\(report.summary.providerFailureCount)
            optionCountMismatchCount=\(report.summary.optionCountMismatchCount)
            duplicateOptionCount=\(report.summary.duplicateOptionCount)
            cleanFailureCount=\(report.summary.cleanFailureCount)
            watchNoteCount=\(report.summary.watchNoteCount)
            averageScore=\(report.summary.averageScore)
            \(report.failureSummaries.joined(separator: "\n"))
            """
        )
    }

    func testDogfoodPlanCoversCoreManualReviewScenarios() {
        let coveredTags = Set(Self.cases.flatMap(\.tags))
        let requiredTags: Set<String> = [
            "proofread:clean",
            "proofread:messy",
            "proofread:placeholder",
            "proofread:unrecognizable",
            "rewrite:awkward",
            "rewrite:options",
            "summarize:multi-paragraph",
            "shorten:preserve-meaning",
            "markdown:clean",
            "markdown:fenced-code",
            "markdown:structure",
            "dictionary:false-positive-risk",
            "dialect:false-positive-risk",
            "custom:word-swap",
            "custom:tone"
        ]

        XCTAssertTrue(
            coveredTags.isSuperset(of: requiredTags),
            "Missing dogfood tags: \(requiredTags.subtracting(coveredTags).sorted().joined(separator: ", "))"
        )
    }

    func testDogfoodCoordinatorStatesMatchManualUXExpectations() async throws {
        let badText = "slkj sl;jf sl;jf s;afjs"
        let badCoordinator = IntelligentEditingRequestCoordinator(service: FoundationModelsIntelligentEditingService())
        let badResult = await badCoordinator.run(
            action: .proofread,
            documentText: badText,
            currentDocumentText: badText,
            selectedRange: NSRange(location: 0, length: (badText as NSString).length)
        )
        XCTAssertEqual(badResult, .failed("Selection is not recognizable English."))

        let shortText = "cat im the hat"
        let optionsCoordinator = IntelligentEditingRequestCoordinator(
            service: FoundationModelsIntelligentEditingService(
                responseProvider: DogfoodResponseProvider(responses: [
                    """
                    1. Cat in the hat.
                    2. A cat in the hat.
                    3. Cat wearing the hat.
                    """
                ])
            )
        )
        let optionsResult = await optionsCoordinator.run(
            action: .rewrite,
            documentText: shortText,
            currentDocumentText: shortText,
            selectedRange: NSRange(location: 0, length: (shortText as NSString).length)
        )
        guard case .ready(let suggestions, let status) = optionsResult else {
            return XCTFail("Expected ready rewrite options, got \(optionsResult)")
        }
        XCTAssertEqual(status, "3 options ready.")
        XCTAssertEqual(suggestions.map(\.replacementText).count, 3)

        let failingText = "This sentence needs clearer wording."
        let failingCoordinator = IntelligentEditingRequestCoordinator(
            service: DogfoodFailingIntelligentEditingService(
                error: IntelligentEditingError.invalidResponse("Apple Intelligence returned an unusable replacement (unchangedTransformOutput).")
            )
        )
        let failingResult = await failingCoordinator.run(
            action: .rewrite,
            documentText: failingText,
            currentDocumentText: failingText,
            selectedRange: NSRange(location: 0, length: (failingText as NSString).length)
        )
        XCTAssertEqual(failingResult, .failed("Suggestion unavailable."))
    }

    private static func liveDogfoodReport() async -> DogfoodReport {
        let runner = IntelligentEditingRunner(service: FoundationModelsIntelligentEditingService())
        var records: [DogfoodRecord] = []

        for dogfoodCase in cases {
            let selectedRange = (dogfoodCase.documentContext as NSString).range(of: dogfoodCase.selectedText)
            guard selectedRange.location != NSNotFound else {
                records.append(DogfoodRecord(case: dogfoodCase, failureKind: "setup", failure: "selected text not found in document context"))
                continue
            }

            do {
                let replacements: [String]
                if dogfoodCase.expectedFailureKind == nil, dogfoodCase.optionCount > 1 {
                    let suggestions = try await runner.runOptions(
                        request: dogfoodCase.request,
                        documentText: dogfoodCase.documentContext,
                        selectedRange: selectedRange,
                        optionCount: dogfoodCase.optionCount
                    )
                    replacements = suggestions.map(\.replacementText)
                } else {
                    let suggestion = try await runner.run(
                        request: dogfoodCase.request,
                        documentText: dogfoodCase.documentContext,
                        selectedRange: selectedRange
                    )
                    replacements = [suggestion.replacementText]
                }

                if let expectedFailureKind = dogfoodCase.expectedFailureKind {
                    records.append(DogfoodRecord(
                        case: dogfoodCase,
                        replacements: replacements,
                        failureKind: "expectedFailureNotRaised",
                        failure: "Expected \(expectedFailureKind), got suggestions"
                    ))
                    continue
                }

                records.append(DogfoodRecord(case: dogfoodCase, replacements: replacements))
            } catch {
                if let expectedFailureKind = dogfoodCase.expectedFailureKind, dogfoodCase.matchesExpectedFailure(error) {
                    records.append(DogfoodRecord(case: dogfoodCase, cleanFailureKind: expectedFailureKind, failure: error.localizedDescription))
                } else {
                    records.append(DogfoodRecord(case: dogfoodCase, failureKind: "providerFailure", failure: error.localizedDescription))
                }
            }
        }

        return DogfoodReport(records: records)
    }

    private static var shouldRunLiveDogfoodEval: Bool {
        ProcessInfo.processInfo.environment["LINEFORM_RUN_LIVE_DOGFOOD_EVALS"] == "1"
            || FileManager.default.fileExists(atPath: "/private/tmp/lineform-run-live-dogfood-evals")
    }

    private static var dogfoodReportURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lineform-intelligence-dogfood-report.json")
    }

    private static let cases: [DogfoodCase] = [
        DogfoodCase(
            id: "proofread-clean-product-terms",
            action: .proofread,
            selectedText: "Lineform saves Markdown files locally with SwiftUI and TextKit.",
            documentContext: "Lineform saves Markdown files locally with SwiftUI and TextKit.",
            allowUnchanged: true,
            requiredFragments: ["Lineform", "Markdown", "SwiftUI", "TextKit"],
            tags: ["proofread:clean", "dictionary:false-positive-risk"]
        ),
        DogfoodCase(
            id: "proofread-messy-release-note",
            action: .proofread,
            selectedText: "this realease keeps markdown files local and dont upload drafts.",
            documentContext: "this realease keeps markdown files local and dont upload drafts.",
            forbiddenFragments: ["realease", "dont"],
            tags: ["proofread:messy"]
        ),
        DogfoodCase(
            id: "proofread-unrecognizable-keyboard-mash",
            action: .proofread,
            selectedText: "slkj sl;jf sl;jf s;afjs fsjfslfjsk",
            documentContext: "slkj sl;jf sl;jf s;afjs fsjfslfjsk",
            expectedFailureKind: "unrecognizedLanguage",
            tags: ["proofread:unrecognizable"]
        ),
        DogfoodCase(
            id: "proofread-placeholder-lorem",
            action: .proofread,
            selectedText: "Lorem ipsum dolor sit amet.",
            documentContext: "Lorem ipsum dolor sit amet.",
            expectedFailureKind: "placeholderSelection",
            tags: ["proofread:placeholder"]
        ),
        DogfoodCase(
            id: "rewrite-awkward-local-files",
            action: .rewrite,
            selectedText: "The file thing is mostly working but the way it says local and portable is kind of mushy and not clear enough.",
            documentContext: "Draft:\n\nThe file thing is mostly working but the way it says local and portable is kind of mushy and not clear enough.",
            requiredFragments: ["local", "portable"],
            forbiddenFragments: ["mushy"],
            tags: ["rewrite:awkward"]
        ),
        DogfoodCase(
            id: "rewrite-short-options",
            action: .rewrite,
            selectedText: "cat im the hat",
            documentContext: "cat im the hat",
            optionCount: 3,
            forbiddenFragments: ["cat im the hat"],
            tags: ["rewrite:options"]
        ),
        DogfoodCase(
            id: "summarize-local-first-flow",
            action: .summarize,
            selectedText: """
            Lineform keeps documents as plain Markdown or text files on disk. Writers can keep those files in Finder, iCloud Drive, Git, or another editor without moving them into an app-owned database.

            Intelligence features work on selected text and show suggestions before anything is applied. Bad output should fail cleanly instead of changing the document.
            """,
            documentContext: """
            Lineform keeps documents as plain Markdown or text files on disk. Writers can keep those files in Finder, iCloud Drive, Git, or another editor without moving them into an app-owned database.

            Intelligence features work on selected text and show suggestions before anything is applied. Bad output should fail cleanly instead of changing the document.
            """,
            requiredFragments: ["Markdown", "selected text"],
            forbiddenFragments: ["upload"],
            tags: ["summarize:multi-paragraph", "markdown:structure"]
        ),
        DogfoodCase(
            id: "shorten-preserve-privacy",
            action: .shorten,
            selectedText: "The app should keep writing private by default, use real local files, and avoid accounts, analytics, or document upload unless the user explicitly chooses otherwise.",
            documentContext: "The app should keep writing private by default, use real local files, and avoid accounts, analytics, or document upload unless the user explicitly chooses otherwise.",
            requiredFragments: ["private", "local files"],
            forbiddenFragments: ["account required"],
            tags: ["shorten:preserve-meaning"]
        ),
        DogfoodCase(
            id: "clean-markdown-list",
            action: .cleanMarkdown,
            selectedText: "#Notes\n\n-  Keep files local\n-  Review suggestions first",
            documentContext: "#Notes\n\n-  Keep files local\n-  Review suggestions first",
            requiredFragments: ["# Notes", "- Keep files local", "- Review suggestions first"],
            tags: ["markdown:clean", "markdown:structure"]
        ),
        DogfoodCase(
            id: "clean-markdown-fenced-code",
            action: .cleanMarkdown,
            selectedText: """
            #Snippet

            ```swift
            let localFile = true
            ```
            """,
            documentContext: """
            #Snippet

            ```swift
            let localFile = true
            ```
            """,
            requiredFragments: ["# Snippet", "```swift", "let localFile = true", "```"],
            tags: ["markdown:clean", "markdown:fenced-code", "markdown:structure"]
        ),
        DogfoodCase(
            id: "dialect-proofread-colour",
            action: .proofread,
            selectedText: "The colour theme should stay readable.",
            documentContext: "The colour theme should stay readable.",
            allowUnchanged: true,
            requiredFragments: ["colour"],
            watchOnly: true,
            tags: ["dialect:false-positive-risk", "proofread:clean"]
        ),
        DogfoodCase(
            id: "custom-word-swap",
            userInstruction: "Replace robust with simple.",
            selectedText: "Lineform has a robust local file workflow.",
            documentContext: "Lineform has a robust local file workflow.",
            requiredFragments: ["simple", "local file workflow"],
            forbiddenFragments: ["robust"],
            tags: ["custom:word-swap"]
        ),
        DogfoodCase(
            id: "custom-tone",
            userInstruction: "Make this less corporate.",
            selectedText: "We need stakeholder alignment before execution.",
            documentContext: "We need stakeholder alignment before execution.",
            forbiddenFragments: ["stakeholder alignment", "execution"],
            tags: ["custom:tone"]
        )
    ]
}

private struct DogfoodCase {
    let id: String
    let request: IntelligentEditingRequest
    let selectedText: String
    let documentContext: String
    let optionCount: Int
    let allowUnchanged: Bool
    let requiredFragments: [String]
    let forbiddenFragments: [String]
    let watchOnly: Bool
    let expectedFailureKind: String?
    let tags: [String]

    init(
        id: String,
        action: IntelligentEditingAction,
        selectedText: String,
        documentContext: String,
        optionCount: Int = 1,
        allowUnchanged: Bool = false,
        requiredFragments: [String] = [],
        forbiddenFragments: [String] = [],
        watchOnly: Bool = false,
        expectedFailureKind: String? = nil,
        tags: [String]
    ) {
        self.init(
            id: id,
            request: .action(action),
            selectedText: selectedText,
            documentContext: documentContext,
            optionCount: optionCount,
            allowUnchanged: allowUnchanged,
            requiredFragments: requiredFragments,
            forbiddenFragments: forbiddenFragments,
            watchOnly: watchOnly,
            expectedFailureKind: expectedFailureKind,
            tags: tags
        )
    }

    init(
        id: String,
        userInstruction: String,
        selectedText: String,
        documentContext: String,
        optionCount: Int = 1,
        allowUnchanged: Bool = false,
        requiredFragments: [String] = [],
        forbiddenFragments: [String] = [],
        watchOnly: Bool = false,
        expectedFailureKind: String? = nil,
        tags: [String]
    ) {
        self.init(
            id: id,
            request: .custom(userInstruction),
            selectedText: selectedText,
            documentContext: documentContext,
            optionCount: optionCount,
            allowUnchanged: allowUnchanged,
            requiredFragments: requiredFragments,
            forbiddenFragments: forbiddenFragments,
            watchOnly: watchOnly,
            expectedFailureKind: expectedFailureKind,
            tags: tags
        )
    }

    private init(
        id: String,
        request: IntelligentEditingRequest,
        selectedText: String,
        documentContext: String,
        optionCount: Int,
        allowUnchanged: Bool,
        requiredFragments: [String],
        forbiddenFragments: [String],
        watchOnly: Bool,
        expectedFailureKind: String?,
        tags: [String]
    ) {
        self.id = id
        self.request = request
        self.selectedText = selectedText
        self.documentContext = documentContext
        self.optionCount = optionCount
        self.allowUnchanged = allowUnchanged
        self.requiredFragments = requiredFragments
        self.forbiddenFragments = forbiddenFragments
        self.watchOnly = watchOnly
        self.expectedFailureKind = expectedFailureKind
        self.tags = tags
    }

    var evaluationTask: IntelligentEditingEvaluationTask {
        let action = request.evaluationAction
        return IntelligentEditingEvaluationTask(
            id: id,
            action: action,
            userInstruction: request.usesUserInstruction ? request.userInstruction : nil,
            selectedText: selectedText,
            documentContext: documentContext,
            length: selectedText.contains("\n\n") ? .multipleParagraphs : .sentence,
            requiresTransformation: allowUnchanged ? false : action.requiresNonIdenticalReplacement(for: selectedText),
            requiresCompression: action == .summarize || action == .shorten,
            requiresMarkdownPreservation: action == .cleanMarkdown || selectedText.contains("- ") || selectedText.contains("#")
        )
    }

    func matchesExpectedFailure(_ error: Error) -> Bool {
        guard let expectedFailureKind else {
            return false
        }

        switch (expectedFailureKind, error) {
        case ("unrecognizedLanguage", IntelligentEditingError.unrecognizedLanguage):
            return true
        case ("placeholderSelection", IntelligentEditingError.placeholderSelection):
            return true
        default:
            return error.localizedDescription.contains(expectedFailureKind)
        }
    }
}

private struct DogfoodReport: Codable {
    let generatedAt: String
    let summary: DogfoodSummary
    let records: [DogfoodRecord]

    init(records: [DogfoodRecord]) {
        self.generatedAt = ISO8601DateFormatter().string(from: Date())
        self.records = records
        self.summary = DogfoodSummary(records: records)
    }

    var failureSummaries: [String] {
        records
            .filter { !$0.passed }
            .map { "\($0.id): \($0.failures.joined(separator: ", ")) | \($0.replacements.joined(separator: " || "))" }
    }

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }

    func attachment(named name: String) throws -> XCTAttachment {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = name
        attachment.lifetime = .keepAlways
        return attachment
    }
}

private struct DogfoodSummary: Codable {
    let totalCaseCount: Int
    let passedCaseCount: Int
    let failedCaseCount: Int
    let providerFailureCount: Int
    let optionCountMismatchCount: Int
    let duplicateOptionCount: Int
    let cleanFailureCount: Int
    let watchNoteCount: Int
    let averageScore: Int

    var passed: Bool {
        failedCaseCount == 0
            && providerFailureCount == 0
            && optionCountMismatchCount == 0
            && duplicateOptionCount == 0
    }

    init(records: [DogfoodRecord]) {
        totalCaseCount = records.count
        passedCaseCount = records.filter(\.passed).count
        failedCaseCount = totalCaseCount - passedCaseCount
        providerFailureCount = records.filter { $0.failureKind == "providerFailure" }.count
        optionCountMismatchCount = records.filter { $0.failures.contains("optionCountMismatch") }.count
        duplicateOptionCount = records.filter { $0.failures.contains("duplicateOptions") }.count
        cleanFailureCount = records.filter { $0.cleanFailureKind != nil }.count
        watchNoteCount = records.reduce(0) { $0 + $1.watchNotes.count }
        let scores = records.flatMap(\.scores)
        averageScore = scores.isEmpty ? 0 : scores.reduce(0, +) / scores.count
    }
}

private struct DogfoodRecord: Codable {
    let id: String
    let action: String
    let userInstruction: String?
    let tags: [String]
    let selectedText: String
    let replacements: [String]
    let scores: [Int]
    let qualityBands: [String]
    let passed: Bool
    let failures: [String]
    let watchNotes: [String]
    let failureKind: String?
    let cleanFailureKind: String?

    init(case dogfoodCase: DogfoodCase, replacements: [String]) {
        var failures: [String] = []
        var scores: [Int] = []
        var qualityBands: [String] = []
        if replacements.count != dogfoodCase.optionCount {
            failures.append("optionCountMismatch")
        }

        let normalizedReplacements = replacements.map(Self.normalized)
        if normalizedReplacements.count != Set(normalizedReplacements).count {
            failures.append("duplicateOptions")
        }

        for replacement in replacements {
            let evaluation = IntelligentEditingEvaluationRubric.evaluate(
                replacement: replacement,
                task: dogfoodCase.evaluationTask
            )
            scores.append(evaluation.score)
            qualityBands.append(evaluation.qualityBand)
            failures.append(contentsOf: evaluation.failures.map(\.rawValue))

            if !dogfoodCase.allowUnchanged, Self.normalized(replacement) == Self.normalized(dogfoodCase.selectedText) {
                failures.append("unchangedDogfoodOutput")
            }

            for fragment in dogfoodCase.requiredFragments where !replacement.localizedCaseInsensitiveContains(fragment) {
                failures.append("missingRequiredFragment:\(fragment)")
            }

            for fragment in dogfoodCase.forbiddenFragments where replacement.localizedCaseInsensitiveContains(fragment) {
                failures.append("containsForbiddenFragment:\(fragment)")
            }
        }

        self.id = dogfoodCase.id
        self.action = dogfoodCase.request.evaluationAction.rawValue
        self.userInstruction = dogfoodCase.request.usesUserInstruction ? dogfoodCase.request.userInstruction : nil
        self.tags = dogfoodCase.tags
        self.selectedText = dogfoodCase.selectedText
        self.replacements = replacements
        self.scores = scores
        self.qualityBands = Array(Set(qualityBands)).sorted()
        let sortedFailures = Array(Set(failures)).sorted()
        self.failures = dogfoodCase.watchOnly ? [] : sortedFailures
        self.watchNotes = dogfoodCase.watchOnly ? sortedFailures : []
        self.passed = self.failures.isEmpty
        self.failureKind = nil
        self.cleanFailureKind = nil
    }

    init(case dogfoodCase: DogfoodCase, failureKind: String, failure: String) {
        self.init(case: dogfoodCase, replacements: [], failureKind: failureKind, failure: failure)
    }

    init(case dogfoodCase: DogfoodCase, replacements: [String], failureKind: String, failure: String) {
        self.id = dogfoodCase.id
        self.action = dogfoodCase.request.evaluationAction.rawValue
        self.userInstruction = dogfoodCase.request.usesUserInstruction ? dogfoodCase.request.userInstruction : nil
        self.tags = dogfoodCase.tags
        self.selectedText = dogfoodCase.selectedText
        self.replacements = replacements
        self.scores = []
        self.qualityBands = []
        self.passed = false
        self.failures = [failure]
        self.watchNotes = []
        self.failureKind = failureKind
        self.cleanFailureKind = nil
    }

    init(case dogfoodCase: DogfoodCase, cleanFailureKind: String, failure: String) {
        self.id = dogfoodCase.id
        self.action = dogfoodCase.request.evaluationAction.rawValue
        self.userInstruction = dogfoodCase.request.usesUserInstruction ? dogfoodCase.request.userInstruction : nil
        self.tags = dogfoodCase.tags
        self.selectedText = dogfoodCase.selectedText
        self.replacements = []
        self.scores = []
        self.qualityBands = []
        self.passed = true
        self.failures = []
        self.watchNotes = []
        self.failureKind = nil
        self.cleanFailureKind = cleanFailureKind
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9\s]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
}

private final class DogfoodFailingIntelligentEditingService: IntelligentEditingServicing {
    let error: Error

    init(error: Error) {
        self.error = error
    }

    func replacement(for request: IntelligentEditingRequest, selectedText: String, documentContext: String) async throws -> String {
        throw error
    }

    func replacements(for request: IntelligentEditingRequest, selectedText: String, documentContext: String, count: Int) async throws -> [String] {
        throw error
    }
}

private struct DogfoodResponseProvider: FoundationModelsResponseProviding {
    let responses: [String]

    func responseContent(for prompt: String) async throws -> String {
        responses.first ?? ""
    }
}
