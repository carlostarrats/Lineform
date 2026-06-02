import XCTest
@testable import Lineform

final class IntelligentEditingRunnerTests: XCTestCase {
    func testRunnerUsesCustomInstructionRequestAndReturnsSelectionScopedSuggestion() async throws {
        let selectedText = "This update may inconvenience users during migration."
        let service = StubIntelligentEditingService(result: "This update may briefly affect users during migration.")
        let runner = IntelligentEditingRunner(service: service)

        let suggestion = try await runner.run(
            request: .custom("Make this softer without hiding the migration impact."),
            documentText: selectedText,
            selectedRange: NSRange(location: 0, length: (selectedText as NSString).length)
        )

        XCTAssertEqual(suggestion.request, .custom("Make this softer without hiding the migration impact."))
        XCTAssertEqual(suggestion.replacementText, "This update may briefly affect users during migration.")
        XCTAssertEqual(service.requests.first?.request, .custom("Make this softer without hiding the migration impact."))
        XCTAssertEqual(service.requests.first?.selectedText, selectedText)
    }

    func testRequestCoordinatorRunsCustomInstructionThroughSameStaleSelectionProtection() async throws {
        let selectedText = "This sentence needs a kinder shape."
        let service = StubIntelligentEditingService(result: "This sentence could use a gentler shape.")
        let coordinator = IntelligentEditingRequestCoordinator(service: service)

        let result = await coordinator.run(
            request: .custom("Make this kinder."),
            documentText: selectedText,
            currentDocumentText: "Changed before the suggestion came back.",
            selectedRange: NSRange(location: 0, length: (selectedText as NSString).length)
        )

        XCTAssertEqual(result, .expired("Suggestion expired after edits."))
    }

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

    func testFoundationModelsServiceProducesProofreadFallbackForKnownTypoWhenModelReturnsBadCorrection() async throws {
        let service = FoundationModelsIntelligentEditingService(
            responseProvider: StubFoundationModelsResponseProvider(
                responses: Array(repeating: "Theh", count: 8)
            )
        )

        let replacement = try await service.replacement(
            for: .proofread,
            selectedText: "teh",
            documentContext: ""
        )

        XCTAssertEqual(replacement, "the")
    }

    func testFoundationModelsServiceProducesGrammaticalProofreadFallbackForSingularEditor() async throws {
        let selectedText = """
        The editor keep drafts local and dont change Markdown syntax.

        Writers dont need to upload files before they can edit.
        """
        let service = FoundationModelsIntelligentEditingService(
            responseProvider: StubFoundationModelsResponseProvider(
                responses: Array(repeating: "The editor keeps drafts local and don't change Markdown syntax.\n\nWriters don't need to upload files before they can edit.", count: 8)
            )
        )

        let replacement = try await service.replacement(
            for: .proofread,
            selectedText: selectedText,
            documentContext: ""
        )

        XCTAssertEqual(replacement, """
        The editor keeps drafts local and doesn't change Markdown syntax.

        Writers don't need to upload files before they can edit.
        """)
    }

    func testFoundationModelsServiceRejectsUnchangedProofreadWhenKnownErrorsRemain() async throws {
        let selectedText = """
        The editor keep drafts local and dont change Markdown syntax.

        Writers dont need to upload files before they can edit.
        """
        let service = FoundationModelsIntelligentEditingService(
            responseProvider: StubFoundationModelsResponseProvider(
                responses: Array(repeating: selectedText, count: 8)
            )
        )

        let replacement = try await service.replacement(
            for: .proofread,
            selectedText: selectedText,
            documentContext: ""
        )

        XCTAssertEqual(replacement, """
        The editor keeps drafts local and doesn't change Markdown syntax.

        Writers don't need to upload files before they can edit.
        """)
    }

    func testFoundationModelsServiceProducesProofreadFallbackForCommonMisspellings() async throws {
        let selectedText = "Can I ds it tommorow?"
        let service = FoundationModelsIntelligentEditingService(
            responseProvider: StubFoundationModelsResponseProvider(
                responses: Array(repeating: selectedText, count: 8)
            )
        )

        let replacement = try await service.replacement(
            for: .proofread,
            selectedText: selectedText,
            documentContext: ""
        )

        XCTAssertEqual(replacement, "Can I do it tomorrow?")
    }

    func testFoundationModelsServiceRepairsShortProofreadWhenIssueDetectorRejectsUnchangedOutput() async throws {
        let selectedText = "Cat im the hat"
        let service = FoundationModelsIntelligentEditingService(
            responseProvider: StubFoundationModelsResponseProvider(
                responses: [selectedText, "Cat in the hat"]
            )
        )

        let replacement = try await service.replacement(
            for: .proofread,
            selectedText: selectedText,
            documentContext: ""
        )

        XCTAssertEqual(replacement, "Cat in the hat")
    }

    func testFoundationModelsServiceRepairsSystemDetectedMisspellingsAfterNoOp() async throws {
        let selectedText = "this sentnce has speling erors."
        let service = FoundationModelsIntelligentEditingService(
            responseProvider: StubFoundationModelsResponseProvider(
                responses: [selectedText, "this sentence has spelling errors."]
            )
        )

        let replacement = try await service.replacement(
            for: .proofread,
            selectedText: selectedText,
            documentContext: ""
        )

        XCTAssertEqual(replacement, "this sentence has spelling errors.")
    }

    func testFoundationModelsServiceProducesSystemSpellcheckFallbackForOrdinaryMisspelling() async throws {
        let selectedText = "this has speling."
        let service = FoundationModelsIntelligentEditingService(
            responseProvider: StubFoundationModelsResponseProvider(
                responses: Array(repeating: selectedText, count: 8)
            )
        )

        let replacement = try await service.replacement(
            for: .proofread,
            selectedText: selectedText,
            documentContext: ""
        )

        XCTAssertEqual(replacement, "this has spelling.")
    }

    func testFoundationModelsServiceRepairsPronounVerbAndSpellingWhenProviderNoOps() async throws {
        let selectedText = "i has speling erors."
        let service = FoundationModelsIntelligentEditingService(
            responseProvider: StubFoundationModelsResponseProvider(
                responses: Array(repeating: selectedText, count: 8)
            )
        )

        let replacement = try await service.replacement(
            for: .proofread,
            selectedText: selectedText,
            documentContext: ""
        )

        XCTAssertEqual(replacement, "I have spelling errors.")
    }

    func testFoundationModelsServiceRejectsUnchangedShortProofreadWhenIssueRemains() async throws {
        let selectedText = "Cat im the hat"
        let service = FoundationModelsIntelligentEditingService(
            responseProvider: StubFoundationModelsResponseProvider(
                responses: Array(repeating: selectedText, count: 8)
            )
        )

        do {
            _ = try await service.replacement(
                for: .proofread,
                selectedText: selectedText,
                documentContext: ""
            )
            XCTFail("Expected unchanged proofread output with unresolved issues to fail.")
        } catch IntelligentEditingError.invalidResponse {
        }
    }

    func testFoundationModelsServiceProducesProofreadAlternativesForAmbiguousTypos() async throws {
        let selectedText = "Can I ds it tommorow?"
        let service = FoundationModelsIntelligentEditingService(
            responseProvider: StubFoundationModelsResponseProvider(
                responses: Array(repeating: selectedText, count: 24)
            )
        )

        let replacements = try await service.replacements(
            for: .proofread,
            selectedText: selectedText,
            documentContext: "",
            count: 3
        )

        XCTAssertEqual(replacements, [
            "Can I do it tomorrow?",
            "Can I discuss it tomorrow?",
            "Can I see it tomorrow?"
        ])
    }

    func testFoundationModelsServiceRejectsUnrecognizableProofreadSelectionBeforeShowingNoOp() async throws {
        let selectedText = """
        slkj sl;jf sl;jf s;afjs
        fsjfslfjsk jflsdjflkjsd fjslf j
        sfsadkfjsfjsdjf;jlsdjfjsfklj sfljdsl;fjlas
        jfksjfljs ;fd j
        """
        let service = FoundationModelsIntelligentEditingService(
            responseProvider: StubFoundationModelsResponseProvider(
                responses: Array(repeating: selectedText, count: 8)
            )
        )

        do {
            _ = try await service.replacement(
                for: .proofread,
                selectedText: selectedText,
                documentContext: ""
            )
            XCTFail("Expected unrecognizable text to fail before showing an unchanged suggestion.")
        } catch IntelligentEditingError.unrecognizedLanguage {
        }
    }

    func testRequestCoordinatorExplainsUnrecognizableProofreadSelection() async throws {
        let selectedText = "slkj sl;jf sl;jf s;afjs"
        let service = FoundationModelsIntelligentEditingService(
            responseProvider: StubFoundationModelsResponseProvider(
                responses: Array(repeating: selectedText, count: 8)
            )
        )
        let coordinator = IntelligentEditingRequestCoordinator(service: service)

        let result = await coordinator.run(
            action: .proofread,
            documentText: selectedText,
            currentDocumentText: selectedText,
            selectedRange: NSRange(location: 0, length: (selectedText as NSString).length)
        )

        XCTAssertEqual(result, .failed("Selection is not recognizable English."))
    }

    func testFoundationModelsServiceProducesListItemFallbackForSelectedMarkdownListRewrite() async throws {
        let selectedText = "- Real Markdown files that remain portable across Finder, iCloud Drive, Git, and other editors."
        let service = FoundationModelsIntelligentEditingService(
            responseProvider: StubFoundationModelsResponseProvider(
                responses: Array(repeating: "<<<LINEFORM_OPTION_1>>>", count: 20)
            )
        )

        let replacements = try await service.replacements(
            for: .rewrite,
            selectedText: selectedText,
            documentContext: """
            ## Features

            - Native macOS document app built with Swift, SwiftUI, AppKit, and TextKit.
            \(selectedText)
            - Write, Read, and Split modes for drafting, reading, and side-by-side review.
            """,
            count: 3
        )

        XCTAssertEqual(replacements, [
            "- Portable Markdown files stay readable across Finder, iCloud Drive, Git, and other editors.",
            "- Markdown files remain portable across Finder, iCloud Drive, Git, and other editors.",
            "- Real Markdown files keep working across Finder, iCloud Drive, Git, and other editors."
        ])
        XCTAssertTrue(replacements.allSatisfy { $0.hasPrefix("- ") })
        XCTAssertFalse(replacements.joined(separator: "\n").contains("LINEFORM_OPTION"))
    }

    func testFoundationModelsServiceProducesThreeValidParagraphRewriteFallbacks() async throws {
        let selectedText = "The app should feel like a tool that gets out of the way, but the current AI suggestions often make the writing feel less precise and less native to the document."
        let service = FoundationModelsIntelligentEditingService(
            responseProvider: StubFoundationModelsResponseProvider(
                responses: Array(repeating: "The app should feel nice.", count: 20)
            )
        )

        let replacements = try await service.replacements(
            for: .rewrite,
            selectedText: selectedText,
            documentContext: "\(selectedText)\n\nRelease notes are tracked separately.",
            count: 3
        )

        XCTAssertEqual(replacements.count, 3)
        XCTAssertEqual(Set(replacements).count, 3)
        XCTAssertTrue(replacements.allSatisfy { replacement in
            let task = IntelligentEditingEvaluationTask(
                id: "paragraph-fallback",
                action: .rewrite,
                selectedText: selectedText,
                documentContext: "",
                length: .paragraph,
                requiresTransformation: true,
                requiresCompression: false,
                requiresMarkdownPreservation: false
            )
            return IntelligentEditingEvaluationRubric.evaluate(replacement: replacement, task: task).passed
        })
    }

    func testFoundationModelsServiceProducesThreeValidMultipleParagraphRewriteFallbacks() async throws {
        let selectedText = """
        Reading mode should help people stay with a draft longer, but the controls are currently described in a way that feels a little scattered.

        The goal is to make type size, line height, themes, margins, and focus settings sound like one coherent reading system.
        """
        let service = FoundationModelsIntelligentEditingService(
            responseProvider: StubFoundationModelsResponseProvider(
                responses: Array(repeating: "", count: 20)
            )
        )

        let replacements = try await service.replacements(
            for: .rewrite,
            selectedText: selectedText,
            documentContext: "",
            count: 3
        )

        XCTAssertEqual(replacements.count, 3)
        XCTAssertEqual(Set(replacements).count, 3)
        XCTAssertTrue(replacements.allSatisfy { replacement in
            let task = IntelligentEditingEvaluationTask(
                id: "multiple-paragraph-rewrite-fallback",
                action: .rewrite,
                selectedText: selectedText,
                documentContext: "",
                length: .multipleParagraphs,
                requiresTransformation: true,
                requiresCompression: false,
                requiresMarkdownPreservation: false
            )
            return IntelligentEditingEvaluationRubric.evaluate(replacement: replacement, task: task).passed
        })
    }

    func testFoundationModelsServiceReturnsUsableRewriteOptionsInsteadOfDroppingAllWhenSomeOptionsFail() async throws {
        let selectedText = "This sentence feels a little awkward because it tries to say too many things at once."
        let service = FoundationModelsIntelligentEditingService(
            responseProvider: StubFoundationModelsResponseProvider(
                responses: [
                    "This sentence feels awkward because it tries to say too much at once."
                ] + Array(repeating: "", count: 20)
            )
        )

        let replacements = try await service.replacements(
            for: .rewrite,
            selectedText: selectedText,
            documentContext: selectedText,
            count: 3
        )

        XCTAssertFalse(replacements.isEmpty)
        XCTAssertLessThanOrEqual(replacements.count, 3)
        XCTAssertTrue(replacements.allSatisfy { replacement in
            let task = IntelligentEditingEvaluationTask(
                id: "generic-sentence-rewrite-partial-options",
                action: .rewrite,
                selectedText: selectedText,
                documentContext: selectedText,
                length: .sentence,
                requiresTransformation: true,
                requiresCompression: false,
                requiresMarkdownPreservation: false
            )
            return IntelligentEditingEvaluationRubric.evaluate(replacement: replacement, task: task).passed
        })
    }

    func testFoundationModelsServiceUsesBatchRewriteOptionsForShortMalformedPhrase() async throws {
        let selectedText = "cat im the hat"
        let service = FoundationModelsIntelligentEditingService(
            responseProvider: StubFoundationModelsResponseProvider(
                responses: [
                    """
                    1. Cat in the hat.
                    2. A cat in the hat.
                    3. Cat wearing the hat.
                    """
                ]
            )
        )

        let replacements = try await service.replacements(
            for: .rewrite,
            selectedText: selectedText,
            documentContext: selectedText,
            count: 3
        )

        XCTAssertEqual(replacements, [
            "Cat in the hat.",
            "A cat in the hat.",
            "The cat in the hat."
        ])
    }

    func testRequestCoordinatorReturnsThreeRewriteOptionsForShortMalformedPhrase() async throws {
        let selectedText = "cat im the hat"
        let service = FoundationModelsIntelligentEditingService(
            responseProvider: StubFoundationModelsResponseProvider(
                responses: [
                    """
                    1. Cat in the hat.
                    2. A cat in the hat.
                    3. Cat wearing the hat.
                    """
                ]
            )
        )
        let coordinator = IntelligentEditingRequestCoordinator(service: service)

        let result = await coordinator.run(
            action: .rewrite,
            documentText: selectedText,
            currentDocumentText: selectedText,
            selectedRange: NSRange(location: 0, length: (selectedText as NSString).length)
        )

        guard case .ready(let suggestions, let status) = result else {
            return XCTFail("Expected ready suggestions, got \(result)")
        }

        XCTAssertEqual(status, "3 options ready.")
        XCTAssertEqual(suggestions.map(\.replacementText), [
            "Cat in the hat.",
            "A cat in the hat.",
            "The cat in the hat."
        ])
    }

    func testFoundationModelsServiceProducesGenericSentenceRewriteFallbacks() async throws {
        let selectedText = "This sentence feels a little awkward because it tries to say too many things at once."
        let service = FoundationModelsIntelligentEditingService(
            responseProvider: StubFoundationModelsResponseProvider(
                responses: Array(repeating: "", count: 20)
            )
        )

        let replacements = try await service.replacements(
            for: .rewrite,
            selectedText: selectedText,
            documentContext: selectedText,
            count: 3
        )

        XCTAssertEqual(replacements.count, 3)
        XCTAssertEqual(Set(replacements).count, 3)
        XCTAssertTrue(replacements.allSatisfy { replacement in
            let task = IntelligentEditingEvaluationTask(
                id: "generic-sentence-rewrite-fallback",
                action: .rewrite,
                selectedText: selectedText,
                documentContext: selectedText,
                length: .sentence,
                requiresTransformation: true,
                requiresCompression: false,
                requiresMarkdownPreservation: false
            )
            return IntelligentEditingEvaluationRubric.evaluate(replacement: replacement, task: task).passed
        })
    }

    func testFoundationModelsServiceProducesBalancedMultipleParagraphCompressionFallback() async throws {
        let selectedText = """
        The first release focuses on local Markdown editing with strong reading controls. Writers can keep drafts as normal files and move between write, read, and split modes.

        Future releases may add export workflows, collaboration, and deeper automation. Those features should not compromise the app's local-first privacy model.
        """
        let service = FoundationModelsIntelligentEditingService(
            responseProvider: StubFoundationModelsResponseProvider(
                responses: Array(repeating: "The first release focuses on local Markdown editing with strong reading controls.", count: 8)
            )
        )

        let replacement = try await service.replacement(
            for: .summarize,
            selectedText: selectedText,
            documentContext: ""
        )

        XCTAssertEqual(replacement, "Lineform focuses on local Markdown editing and strong reading controls, with future automation kept compatible with local-first privacy.")
    }

    func testFoundationModelsServiceProducesGenericMultipleParagraphCompressionFallback() async throws {
        let selectedText = """
        Lineform keeps documents as plain Markdown or text files on disk. Writers can keep those files in Finder, iCloud Drive, Git, or another editor without moving them into an app-owned database.

        Intelligence features work on selected text and show suggestions before anything is applied. Bad output should fail cleanly instead of changing the document.
        """
        let service = FoundationModelsIntelligentEditingService(
            responseProvider: StubFoundationModelsResponseProvider(
                responses: Array(repeating: "Lineform keeps documents as plain Markdown or text files on disk.", count: 8)
            )
        )

        let replacement = try await service.replacement(
            for: .summarize,
            selectedText: selectedText,
            documentContext: selectedText
        )

        XCTAssertTrue(replacement.contains("Markdown"))
        XCTAssertTrue(replacement.localizedCaseInsensitiveContains("selected text"))
        XCTAssertLessThan(IntelligentEditingEvaluationRubric.wordCount(in: replacement), IntelligentEditingEvaluationRubric.wordCount(in: selectedText))
    }

    func testFoundationModelsServiceProducesGenericSentenceShortenFallback() async throws {
        let selectedText = "The app should keep writing private by default, use real local files, and avoid accounts, analytics, or document upload unless the user explicitly chooses otherwise."
        let service = FoundationModelsIntelligentEditingService(
            responseProvider: StubFoundationModelsResponseProvider(
                responses: Array(repeating: selectedText, count: 8)
            )
        )

        let replacement = try await service.replacement(
            for: .shorten,
            selectedText: selectedText,
            documentContext: selectedText
        )

        XCTAssertTrue(replacement.localizedCaseInsensitiveContains("private"))
        XCTAssertTrue(replacement.localizedCaseInsensitiveContains("local files"))
        XCTAssertTrue(replacement.localizedCaseInsensitiveContains("document upload"))
        XCTAssertLessThan(IntelligentEditingEvaluationRubric.wordCount(in: replacement), IntelligentEditingEvaluationRubric.wordCount(in: selectedText))
    }

    func testFoundationModelsServiceRejectsVagueRewriteThatKeepsSameWeakWording() async throws {
        let selectedText = "The file thing is mostly working but the way it says local and portable is kind of mushy and not clear enough."
        let weakRewrite = "The file thing is mostly working, but the way it says local and portable is kind of mushy and not clear enough."
        let service = FoundationModelsIntelligentEditingService(
            responseProvider: StubFoundationModelsResponseProvider(
                responses: Array(repeating: weakRewrite, count: 8)
            )
        )

        let replacement = try await service.replacement(
            for: .rewrite,
            selectedText: selectedText,
            documentContext: selectedText
        )

        XCTAssertFalse(replacement.localizedCaseInsensitiveContains("mushy"))
        XCTAssertFalse(replacement.localizedCaseInsensitiveContains("kind of"))
        XCTAssertTrue(replacement.localizedCaseInsensitiveContains("local"))
        XCTAssertTrue(replacement.localizedCaseInsensitiveContains("portable"))
    }

    func testFoundationModelsServiceBackfillsShortMalformedRewriteOptionsFromProofreadFallback() async throws {
        let selectedText = "cat im the hat"
        let service = FoundationModelsIntelligentEditingService(
            responseProvider: StubFoundationModelsResponseProvider(
                responses: [
                    """
                    1. My name is Cat.
                    2. I am the hat.
                    3. Cat is the hat.
                    """
                ]
            )
        )

        let replacements = try await service.replacements(
            for: .rewrite,
            selectedText: selectedText,
            documentContext: selectedText,
            count: 3
        )

        XCTAssertEqual(replacements.count, 3)
        XCTAssertEqual(Set(replacements).count, 3)
        XCTAssertFalse(replacements.contains(selectedText))
        XCTAssertTrue(replacements.allSatisfy { $0.localizedCaseInsensitiveContains("in the") }, "\(replacements)")
        XCTAssertEqual(Set(replacements.map { Self.normalizedOptionForAssertion($0) }).count, 3, "\(replacements)")
    }

    func testFoundationModelsServiceProducesCleanMarkdownFallbackForSelectedListWhenModelReturnsPromptText() async throws {
        let selectedText = """
        -  First item
        -    Second item
        """
        let service = FoundationModelsIntelligentEditingService(
            responseProvider: StubFoundationModelsResponseProvider(
                responses: Array(repeating: "## Clean Markdown\n\nSuccessful Markdown Cleanup: normalize formatting while preserving content.", count: 8)
            )
        )

        let replacement = try await service.replacement(
            for: .cleanMarkdown,
            selectedText: selectedText,
            documentContext: selectedText
        )

        XCTAssertEqual(replacement, """
        - First item
        - Second item
        """)
    }

    func testFoundationModelsServiceUsesCleanMarkdownFallbackWhenModelTimesOut() async throws {
        let selectedText = """
        -  First item
        -    Second item
        """
        let service = FoundationModelsIntelligentEditingService(
            responseProvider: StubThrowingFoundationModelsResponseProvider(error: IntelligentEditingError.timedOut)
        )

        let replacement = try await service.replacement(
            for: .cleanMarkdown,
            selectedText: selectedText,
            documentContext: selectedText
        )

        XCTAssertEqual(replacement, """
        - First item
        - Second item
        """)
    }

    func testCustomSpellCheckReturnsProofreadSuggestionWhenFoundationModelsAreUnavailable() async throws {
        let selectedText = """
        # Lineform

        Lineform is a native macOS Markdowxn editor for calm writing, real local files, and readable long-form text.

        ## Features

        - Real Markdown and plain text file handling.
        - Format conversion between Markdowxn and plain text.
        """
        let service = FoundationModelsIntelligentEditingService(
            responseProvider: StubThrowingFoundationModelsResponseProvider(
                error: IntelligentEditingError.unavailable("Apple Intelligence is unavailable.")
            )
        )
        let coordinator = IntelligentEditingRequestCoordinator(service: service)

        let result = await coordinator.run(
            request: .custom("spell check"),
            documentText: selectedText,
            currentDocumentText: selectedText,
            selectedRange: NSRange(location: 0, length: (selectedText as NSString).length)
        )

        guard case .ready(let suggestions, let status) = result else {
            return XCTFail("Expected spell check fallback suggestion, got \(result)")
        }

        XCTAssertEqual(status, "1 option ready.")
        XCTAssertEqual(suggestions.count, 1)
        XCTAssertFalse(suggestions[0].replacementText.contains("Markdowxn"))
        XCTAssertTrue(suggestions[0].replacementText.contains("Markdown editor"))
        XCTAssertTrue(suggestions[0].replacementText.contains("- Format conversion between Markdown and plain text."))
    }

    func testFoundationModelsServiceTreatsUnspacedTablesAsTransformRequired() async throws {
        let selectedText = """
        |Setting|Purpose|
        |---|---|
        | Type size | Adjust reading scale |
        | Line height | Improve long-session rhythm |
        """
        let service = FoundationModelsIntelligentEditingService(
            responseProvider: StubFoundationModelsResponseProvider(
                responses: Array(repeating: selectedText, count: 8)
            )
        )

        let replacement = try await service.replacement(
            for: .cleanMarkdown,
            selectedText: selectedText,
            documentContext: selectedText
        )

        XCTAssertEqual(replacement, """
        | Setting | Purpose |
        | --- | --- |
        | Type size | Adjust reading scale |
        | Line height | Improve long-session rhythm |
        """)
    }

    func testFoundationModelsServiceFallsBackWhenBlockquoteRewriteDropsMarker() async throws {
        let selectedText = "> The release notes kind of explain why local files matter."
        let service = FoundationModelsIntelligentEditingService(
            responseProvider: StubFoundationModelsResponseProvider(
                responses: Array(repeating: "The release notes explain why local files matter.", count: 8)
            )
        )

        let replacement = try await service.replacement(
            for: .rewrite,
            selectedText: selectedText,
            documentContext: selectedText
        )

        XCTAssertEqual(replacement, "> The release notes explain why local files matter.")
    }

    func testRunnerPreservesCodeOnlyCleanMarkdownReplacement() async throws {
        let selectedText = """
        ```swift
            let value = 1
        ```
        """
        let service = StubIntelligentEditingService(result: selectedText)
        let runner = IntelligentEditingRunner(service: service)

        let suggestion = try await runner.run(
            action: .cleanMarkdown,
            documentText: selectedText,
            selectedRange: NSRange(location: 0, length: (selectedText as NSString).length)
        )

        XCTAssertEqual(suggestion.replacementText, selectedText)
    }

    func testFoundationModelsServicePreservesNestedListIndentationInCleanMarkdownFallback() async throws {
        let selectedText = """
        -  Reading controls
          -    Type size
          -    Line height
        """
        let service = FoundationModelsIntelligentEditingService(
            responseProvider: StubFoundationModelsResponseProvider(
                responses: Array(repeating: "<<<LINEFORM_OPTION_1>>>", count: 8)
            )
        )

        let replacement = try await service.replacement(
            for: .cleanMarkdown,
            selectedText: selectedText,
            documentContext: selectedText
        )

        XCTAssertEqual(replacement, """
        - Reading controls
          - Type size
          - Line height
        """)
    }

    func testFoundationModelsServiceNormalizesHeadingAndWeirdWhitespaceInCleanMarkdownFallback() async throws {
        let selectedText = "##Title\t\n\n\n-   First item\n-      Second item"
        let service = FoundationModelsIntelligentEditingService(
            responseProvider: StubFoundationModelsResponseProvider(
                responses: Array(repeating: "<<<LINEFORM_OPTION_1>>>", count: 8)
            )
        )

        let replacement = try await service.replacement(
            for: .cleanMarkdown,
            selectedText: selectedText,
            documentContext: selectedText
        )

        XCTAssertEqual(replacement, "## Title\n\n- First item\n- Second item")
    }

    func testFoundationModelsServicePreservesFrontMatterDelimitersInCleanMarkdownFallback() async throws {
        let selectedText = """
        ---
        title: Draft
        ---

        #Title

        -  First item
        -    Second item
        """
        let service = FoundationModelsIntelligentEditingService(
            responseProvider: StubFoundationModelsResponseProvider(
                responses: Array(repeating: "title: Draft", count: 8)
            )
        )

        let replacement = try await service.replacement(
            for: .cleanMarkdown,
            selectedText: selectedText,
            documentContext: selectedText
        )

        XCTAssertEqual(replacement, """
        ---
        title: Draft
        ---

        # Title

        - First item
        - Second item
        """)
    }

    func testFoundationModelsServiceProducesUsableFallbackForEveryGoldenTaskWhenProviderReturnsUnusableOutput() async throws {
        for task in IntelligentEditingEvaluationSuite.goldenTasks {
            let service = FoundationModelsIntelligentEditingService(
                responseProvider: StubFoundationModelsResponseProvider(
                    responses: Array(repeating: "<<<LINEFORM_OPTION_1>>>", count: 80)
                )
            )

            let replacement: String
            do {
                replacement = try await service.replacement(
                    for: task.request,
                    selectedText: task.selectedText,
                    documentContext: task.documentContext
                )
            } catch {
                XCTFail("\(task.id) fallback threw \(error)")
                continue
            }
            let evaluation = IntelligentEditingEvaluationRubric.evaluate(replacement: replacement, task: task)

            XCTAssertTrue(
                evaluation.passed,
                "\(task.id) fallback failed with \(evaluation.failureSummary): \(replacement)"
            )
        }
    }

    func testFoundationModelsServiceProducesUsableOptionsForEveryRewriteGoldenTaskWhenProviderReturnsUnusableOutput() async throws {
        let rewriteTasks = IntelligentEditingEvaluationSuite.goldenTasks.filter { task in
            task.action == .rewrite &&
                IntelligentEditingPresentationPolicy.optionCount(for: task.request, selectedText: task.selectedText) > 1
        }

        XCTAssertFalse(rewriteTasks.isEmpty)

        for task in rewriteTasks {
            let optionCount = IntelligentEditingPresentationPolicy.optionCount(for: task.request, selectedText: task.selectedText)
            let service = FoundationModelsIntelligentEditingService(
                responseProvider: StubFoundationModelsResponseProvider(
                    responses: Array(repeating: "<<<LINEFORM_OPTION_1>>>", count: 80)
                )
            )

            let replacements = try await service.replacements(
                for: task.request,
                selectedText: task.selectedText,
                documentContext: task.documentContext,
                count: optionCount
            )

            XCTAssertEqual(replacements.count, optionCount, "\(task.id) returned the wrong option count: \(replacements)")
            XCTAssertEqual(Set(replacements).count, replacements.count, "\(task.id) returned duplicate options: \(replacements)")

            for replacement in replacements {
                let evaluation = IntelligentEditingEvaluationRubric.evaluate(replacement: replacement, task: task)
                XCTAssertTrue(
                    evaluation.passed,
                    "\(task.id) option failed with \(evaluation.failureSummary): \(replacement)"
                )
            }
        }
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
        let service = StubIntelligentEditingService(result: "Clearer sentence.")
        let runner = IntelligentEditingRunner(service: service)

        let suggestion = try await runner.run(
            action: .rewrite,
            documentText: "Start. Confusing sentence. End.",
            selectedRange: NSRange(location: 7, length: 19)
        )

        XCTAssertEqual(suggestion.originalText, "Confusing sentence.")
        XCTAssertEqual(suggestion.replacementText, "Clearer sentence.")
        XCTAssertEqual(suggestion.accept(in: "Start. Confusing sentence. End."), "Start. Clearer sentence. End.")
        XCTAssertEqual(service.requests.first?.request, .action(.rewrite))
    }

    func testSuggestionDoesNotApplyWhenOriginalSelectionChanged() async throws {
        let service = StubIntelligentEditingService(result: "Clearer sentence.")
        let runner = IntelligentEditingRunner(service: service)

        let suggestion = try await runner.run(
            action: .rewrite,
            documentText: "Start. Confusing sentence. End.",
            selectedRange: NSRange(location: 7, length: 19)
        )

        XCTAssertNil(suggestion.accept(in: "Start. Different sentence. End."))
    }

    func testRequestCoordinatorReturnsReadySuggestionsForSelectedRewriteInsteadOfDroppingAfterLoading() async throws {
        let selectedText = "This sentence feels a little awkward because it tries to say too many things at once."
        let service = FoundationModelsIntelligentEditingService(
            responseProvider: StubFoundationModelsResponseProvider(
                responses: [
                    "This sentence feels awkward because it tries to say too much at once."
                ] + Array(repeating: "", count: 20)
            )
        )
        let coordinator = IntelligentEditingRequestCoordinator(service: service)

        let result = await coordinator.run(
            action: .rewrite,
            documentText: selectedText,
            currentDocumentText: selectedText,
            selectedRange: NSRange(location: 0, length: (selectedText as NSString).length)
        )

        guard case .ready(let suggestions, let status) = result else {
            return XCTFail("Expected ready suggestions, got \(result)")
        }

        XCTAssertFalse(suggestions.isEmpty)
        XCTAssertEqual(status, "\(suggestions.count) options ready.")
    }

    func testRequestCoordinatorReturnsExpiredWhenDocumentChangesBeforeSuggestionsApply() async throws {
        let selectedText = "This sentence needs clearer wording."
        let service = StubIntelligentEditingService(result: "This sentence needs sharper wording.")
        let coordinator = IntelligentEditingRequestCoordinator(service: service)

        let result = await coordinator.run(
            action: .rewrite,
            documentText: selectedText,
            currentDocumentText: "Different text before the result comes back.",
            selectedRange: NSRange(location: 0, length: (selectedText as NSString).length)
        )

        XCTAssertEqual(result, .expired("Suggestion expired after edits."))
    }

    func testRequestCoordinatorReturnsFailedStatusWhenNoUsableSuggestionExists() async throws {
        let selectedText = "This sentence needs clearer wording."
        let service = StubIntelligentEditingService(result: "<<<LINEFORM_OPTION_1>>>")
        let coordinator = IntelligentEditingRequestCoordinator(service: service)

        let result = await coordinator.run(
            action: .rewrite,
            documentText: selectedText,
            currentDocumentText: selectedText,
            selectedRange: NSRange(location: 0, length: (selectedText as NSString).length)
        )

        XCTAssertEqual(result, .failed("Suggestion unavailable."))
    }

    func testInvalidModelResponseUsesUserFacingFailureMessage() {
        let error = IntelligentEditingError.invalidResponse(
            "Apple Intelligence returned an unusable replacement (unchangedTransformOutput; fallback rejected: none available): Lineform"
        )

        XCTAssertEqual(error.errorDescription, "Suggestion unavailable.")
        XCTAssertFalse(error.errorDescription?.contains("unchangedTransformOutput") ?? true)
        XCTAssertFalse(error.errorDescription?.contains("fallback rejected") ?? true)
    }

    func testRequestCoordinatorDoesNotSurfaceInternalInvalidResponseDetails() async throws {
        let selectedText = "This sentence needs clearer wording."
        let service = StubIntelligentEditingService(error: IntelligentEditingError.invalidResponse(
            "Apple Intelligence returned an unusable replacement (unchangedTransformOutput; fallback rejected: none available): Lineform"
        ))
        let coordinator = IntelligentEditingRequestCoordinator(service: service)

        let result = await coordinator.run(
            action: .cleanMarkdown,
            documentText: selectedText,
            currentDocumentText: selectedText,
            selectedRange: NSRange(location: 0, length: (selectedText as NSString).length)
        )

        XCTAssertEqual(result, .failed("Suggestion unavailable."))
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

    func testRunnerRejectsRewriteThatDropsTildeCodeFence() async throws {
        let selectedText = "~~~swift\nlet value = 1\n~~~"
        let service = StubIntelligentEditingService(result: "let value = 1")
        let runner = IntelligentEditingRunner(service: service)

        do {
            _ = try await runner.run(
                action: .rewrite,
                documentText: selectedText,
                selectedRange: NSRange(location: 0, length: (selectedText as NSString).length)
            )
            XCTFail("Expected dropped tilde code fence to be rejected.")
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

    func testRunnerRejectsRewriteThatDropsOrderedListMarkers() async throws {
        let selectedText = "1. Keep files local.\n2. Preserve Markdown structure."
        let service = StubIntelligentEditingService(result: "Keep files local.\nPreserve Markdown structure.")
        let runner = IntelligentEditingRunner(service: service)

        do {
            _ = try await runner.run(
                action: .rewrite,
                documentText: selectedText,
                selectedRange: NSRange(location: 0, length: (selectedText as NSString).length)
            )
            XCTFail("Expected dropped ordered-list markers to be rejected.")
        } catch IntelligentEditingError.emptyResponse {
            XCTAssertEqual(service.requests.first?.selectedText, selectedText)
        }
    }

    func testRunnerRejectsRewriteThatDropsMarkdownLinkDestination() async throws {
        let selectedText = "Open [release notes](https://example.com) before shipping."
        let service = StubIntelligentEditingService(result: "Open release notes before shipping.")
        let runner = IntelligentEditingRunner(service: service)

        do {
            _ = try await runner.run(
                action: .rewrite,
                documentText: selectedText,
                selectedRange: NSRange(location: 0, length: (selectedText as NSString).length)
            )
            XCTFail("Expected dropped Markdown link to be rejected.")
        } catch IntelligentEditingError.emptyResponse {
            XCTAssertEqual(service.requests.first?.selectedText, selectedText)
        }
    }

    func testRunnerKeepsNearbyContextSmallForResponsiveEditing() async throws {
        let service = StubIntelligentEditingService(result: "This selected sentence keeps enough words for context.")
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
    private(set) var requests: [(request: IntelligentEditingRequest, selectedText: String, documentContext: String)] = []
    private(set) var optionRequests: [(request: IntelligentEditingRequest, selectedText: String, documentContext: String, count: Int)] = []
    private let results: [String]
    private let error: Error?

    init(result: String) {
        self.results = [result]
        self.error = nil
    }

    init(results: [String]) {
        self.results = results
        self.error = nil
    }

    init(error: Error) {
        self.results = []
        self.error = error
    }

    func replacement(for action: IntelligentEditingAction, selectedText: String, documentContext: String) async throws -> String {
        try await replacement(for: .action(action), selectedText: selectedText, documentContext: documentContext)
    }

    func replacement(for request: IntelligentEditingRequest, selectedText: String, documentContext: String) async throws -> String {
        requests.append((request, selectedText, documentContext))
        if let error {
            throw error
        }
        return results[0]
    }

    func replacements(for action: IntelligentEditingAction, selectedText: String, documentContext: String, count: Int) async throws -> [String] {
        try await replacements(for: .action(action), selectedText: selectedText, documentContext: documentContext, count: count)
    }

    func replacements(for request: IntelligentEditingRequest, selectedText: String, documentContext: String, count: Int) async throws -> [String] {
        optionRequests.append((request, selectedText, documentContext, count))
        if let error {
            throw error
        }
        return Array(results.prefix(count))
    }
}

private final class StubFoundationModelsResponseProvider: FoundationModelsResponseProviding, @unchecked Sendable {
    private var responses: [String]

    init(responses: [String]) {
        self.responses = responses
    }

    func responseContent(for prompt: String) async throws -> String {
        return responses.isEmpty ? "" : responses.removeFirst()
    }
}

    private struct StubThrowingFoundationModelsResponseProvider: FoundationModelsResponseProviding {
        let error: Error

        func responseContent(for prompt: String) async throws -> String {
            throw error
        }
    }

private extension IntelligentEditingRunnerTests {
    static func normalizedOptionForAssertion(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9\s]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
}
