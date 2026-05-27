import Foundation

enum IntelligentEditingSelectionLength: String, CaseIterable {
    case oneWord
    case sentence
    case paragraph
    case multipleParagraphs
}

struct IntelligentEditingEvaluationTask: Identifiable {
    let id: String
    let action: IntelligentEditingAction
    let selectedText: String
    let documentContext: String
    let length: IntelligentEditingSelectionLength
    let requiresTransformation: Bool
    let requiresCompression: Bool
    let requiresMarkdownPreservation: Bool
}

enum IntelligentEditingEvaluationFailure: String, Hashable {
    case emptyReplacement
    case placeholderOrDummyText
    case unchangedTransformOutput
    case oversizedShortSelection
    case leakedNearbyContext
    case markdownStructureNotPreserved
    case missingCompression
    case proofreadChangedMeaningOrStyle
    case cleanMarkdownChangedContent
}

struct IntelligentEditingEvaluationResult {
    let failures: [IntelligentEditingEvaluationFailure]

    var passed: Bool {
        failures.isEmpty
    }

    var failureSummary: String {
        failures.map(\.rawValue).joined(separator: ", ")
    }
}

enum IntelligentEditingEvaluationRubric {
    static func evaluate(replacement: String, task: IntelligentEditingEvaluationTask) -> IntelligentEditingEvaluationResult {
        var failures: [IntelligentEditingEvaluationFailure] = []
        let trimmedReplacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSelection = task.selectedText.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedReplacement.isEmpty {
            failures.append(.emptyReplacement)
        }

        if containsPlaceholderOrDummyText(trimmedReplacement) {
            failures.append(.placeholderOrDummyText)
        }

        if task.requiresTransformation && normalized(trimmedReplacement) == normalized(trimmedSelection) {
            failures.append(.unchangedTransformOutput)
        }

        if isOversizedShortSelectionReplacement(trimmedReplacement, for: task) {
            failures.append(.oversizedShortSelection)
        }

        if leaksNearbyContext(trimmedReplacement, task: task) {
            failures.append(.leakedNearbyContext)
        }

        if task.action == .proofread && proofreadChangesMeaningOrStyle(trimmedReplacement, selectedText: trimmedSelection, length: task.length) {
            failures.append(.proofreadChangedMeaningOrStyle)
        }

        if task.requiresMarkdownPreservation && !preservesRequiredMarkdownStructure(trimmedReplacement, selectedText: trimmedSelection) {
            failures.append(.markdownStructureNotPreserved)
        }

        if task.action == .cleanMarkdown && cleanMarkdownChangesContent(trimmedReplacement, selectedText: trimmedSelection) {
            failures.append(.cleanMarkdownChangedContent)
        }

        if task.requiresCompression && wordCount(in: trimmedReplacement) >= wordCount(in: trimmedSelection) {
            failures.append(.missingCompression)
        }

        return IntelligentEditingEvaluationResult(failures: failures)
    }

    static func containsPlaceholderOrDummyText(_ text: String) -> Bool {
        let normalizedText = normalized(text)
        let blockedFragments = [
            "replacement option",
            "<write only replacement",
            "write only replacement",
            "lorem ipsum",
            "todo",
            "placeholder",
            "dummy text",
            "option 1",
            "option 2",
            "option 3",
            "lineform_option",
            "end_lineform_option"
        ]

        return blockedFragments.contains { normalizedText.contains($0) }
    }

    static func isUnchangedTransformOutput(_ replacement: String, selectedText: String) -> Bool {
        normalized(replacement) == normalized(selectedText)
    }

    static func wordCount(in text: String) -> Int {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split { $0.isWhitespace || $0.isNewline }
            .count
    }

    private static func isOversizedShortSelectionReplacement(_ replacement: String, for task: IntelligentEditingEvaluationTask) -> Bool {
        guard task.length == .oneWord || task.length == .sentence else {
            return false
        }

        if task.length == .oneWord {
            let trimmedReplacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
            return replacement.contains("\n")
                || wordCount(in: replacement) > 4
                || trimmedReplacement.hasPrefix("- ")
                || trimmedReplacement.hasPrefix("* ")
                || trimmedReplacement.hasPrefix("#")
        }

        let selectedWordCount = max(1, wordCount(in: task.selectedText))
        return wordCount(in: replacement) > max(selectedWordCount * 2, selectedWordCount + 12)
    }

    private static func leaksNearbyContext(_ replacement: String, task: IntelligentEditingEvaluationTask) -> Bool {
        let contextSentences = task.documentContext
            .components(separatedBy: CharacterSet(charactersIn: ".\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 24 }

        let normalizedReplacement = normalized(replacement)
        let normalizedSelection = normalized(task.selectedText)

        return contextSentences.contains { sentence in
            let normalizedSentence = normalized(sentence)
            return !normalizedSelection.contains(normalizedSentence)
                && normalizedReplacement.contains(normalizedSentence)
        } || leaksContextOnlyTerms(replacement, task: task)
    }

    private static func leaksContextOnlyTerms(_ replacement: String, task: IntelligentEditingEvaluationTask) -> Bool {
        let selectedTokens = Set(meaningfulTokens(in: task.selectedText))
        let contextOnlyTokens = Set(meaningfulTokens(in: task.documentContext)).subtracting(selectedTokens)
        guard contextOnlyTokens.count >= 2 else {
            return false
        }

        let replacementTokens = Set(meaningfulTokens(in: replacement))
        return replacementTokens.intersection(contextOnlyTokens).count >= 2
    }

    private static func proofreadChangesMeaningOrStyle(_ replacement: String, selectedText: String, length: IntelligentEditingSelectionLength) -> Bool {
        guard length != .oneWord else {
            return false
        }

        let selectedWordCount = wordCount(in: selectedText)
        guard selectedWordCount > 0 else {
            return false
        }

        if wordCount(in: replacement) > selectedWordCount + 4 {
            return true
        }

        let selectedTokens = Set(meaningfulTokens(in: selectedText))
        let replacementTokens = Set(meaningfulTokens(in: replacement))
        guard !selectedTokens.isEmpty, !replacementTokens.isEmpty else {
            return false
        }

        let overlap = selectedTokens.intersection(replacementTokens).count
        let requiredOverlap = max(1, Int(Double(selectedTokens.count) * 0.5))
        return overlap < requiredOverlap
    }

    private static func cleanMarkdownChangesContent(_ replacement: String, selectedText: String) -> Bool {
        normalizedMarkdownContent(replacement) != normalizedMarkdownContent(selectedText)
    }

    private static func meaningfulTokens(in text: String) -> [String] {
        let stopwords: Set<String> = [
            "a", "an", "and", "are", "as", "at", "be", "but", "by", "for", "from",
            "has", "have", "in", "into", "is", "it", "of", "on", "or", "so", "that",
            "the", "their", "this", "to", "while", "with", "without"
        ]
        return text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 5 && !stopwords.contains($0) }
    }

    private static func normalizedMarkdownContent(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: #"(?m)^---\s*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^#{1,6}\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^\s*[-*]\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"`{1,3}"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[*_>\[\]()]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func preservesRequiredMarkdownStructure(_ replacement: String, selectedText: String) -> Bool {
        if selectedText.contains("```") {
            return replacement.contains("```")
        }

        if selectedText.contains("- ") {
            return replacement.contains("- ")
        }

        if selectedText.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#") {
            return replacement.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#")
        }

        return true
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
}

enum IntelligentEditingEvaluationSuite {
    static let goldenTasks: [IntelligentEditingEvaluationTask] = [
        IntelligentEditingEvaluationTask(
            id: "one-word-proofread",
            action: .proofread,
            selectedText: "teh",
            documentContext: "",
            length: .oneWord,
            requiresTransformation: true,
            requiresCompression: false,
            requiresMarkdownPreservation: false
        ),
        IntelligentEditingEvaluationTask(
            id: "one-word-rewrite-heading",
            action: .rewrite,
            selectedText: "Features",
            documentContext: "# Features\n\n- Native Markdown files\n- Reading controls",
            length: .oneWord,
            requiresTransformation: true,
            requiresCompression: false,
            requiresMarkdownPreservation: false
        ),
        IntelligentEditingEvaluationTask(
            id: "short-phrase-rewrite-title",
            action: .rewrite,
            selectedText: "better writing",
            documentContext: "# better writing\n\nA calmer Markdown editor for long drafts.",
            length: .oneWord,
            requiresTransformation: true,
            requiresCompression: false,
            requiresMarkdownPreservation: false
        ),
        IntelligentEditingEvaluationTask(
            id: "sentence-rewrite",
            action: .rewrite,
            selectedText: "The launch plan is clear but final handoff is still kind of owned by somebody.",
            documentContext: "The launch plan is clear but final handoff is still kind of owned by somebody.\n\nThe appendix contains budget assumptions.",
            length: .sentence,
            requiresTransformation: true,
            requiresCompression: false,
            requiresMarkdownPreservation: false
        ),
        IntelligentEditingEvaluationTask(
            id: "sentence-shorten",
            action: .shorten,
            selectedText: "Lineform gives writers a quiet native editor that keeps Markdown files portable across Finder, iCloud Drive, Git, and other tools.",
            documentContext: "Lineform gives writers a quiet native editor that keeps Markdown files portable across Finder, iCloud Drive, Git, and other tools.",
            length: .sentence,
            requiresTransformation: true,
            requiresCompression: true,
            requiresMarkdownPreservation: false
        ),
        IntelligentEditingEvaluationTask(
            id: "sentence-proofread",
            action: .proofread,
            selectedText: "The editor keep the file local and dont upload drafts.",
            documentContext: "The editor keep the file local and dont upload drafts.",
            length: .sentence,
            requiresTransformation: true,
            requiresCompression: false,
            requiresMarkdownPreservation: false
        ),
        IntelligentEditingEvaluationTask(
            id: "markdown-list-proofread",
            action: .proofread,
            selectedText: """
            - The editor keep files local.
            - Writers dont need a database.
            """,
            documentContext: "",
            length: .paragraph,
            requiresTransformation: true,
            requiresCompression: false,
            requiresMarkdownPreservation: true
        ),
        IntelligentEditingEvaluationTask(
            id: "paragraph-rewrite",
            action: .rewrite,
            selectedText: "The app should feel like a tool that gets out of the way, but the current AI suggestions often make the writing feel less precise and less native to the document.",
            documentContext: "The app should feel like a tool that gets out of the way, but the current AI suggestions often make the writing feel less precise and less native to the document.\n\nRelease notes are tracked separately.",
            length: .paragraph,
            requiresTransformation: true,
            requiresCompression: false,
            requiresMarkdownPreservation: false
        ),
        IntelligentEditingEvaluationTask(
            id: "paragraph-shorten",
            action: .shorten,
            selectedText: "Lineform keeps Markdown files on disk so writers can use Finder, iCloud Drive, and version control without converting their drafts into a private database. The editor should feel native, quiet, and predictable while still making long documents easier to scan.",
            documentContext: "",
            length: .paragraph,
            requiresTransformation: true,
            requiresCompression: true,
            requiresMarkdownPreservation: false
        ),
        IntelligentEditingEvaluationTask(
            id: "paragraph-summarize",
            action: .summarize,
            selectedText: "The reading mode reduces visual noise, centers the text column, and applies reader profiles for type size, line height, paragraph spacing, and theme. These controls are designed for long sessions where writers need to review structure without changing the underlying Markdown file.",
            documentContext: "",
            length: .paragraph,
            requiresTransformation: true,
            requiresCompression: true,
            requiresMarkdownPreservation: false
        ),
        IntelligentEditingEvaluationTask(
            id: "frontmatter-clean-markdown",
            action: .cleanMarkdown,
            selectedText: """
            ---
            title: Draft
            ---

            #Title

            -  First item
            -    Second item
            """,
            documentContext: "",
            length: .multipleParagraphs,
            requiresTransformation: true,
            requiresCompression: false,
            requiresMarkdownPreservation: true
        ),
        IntelligentEditingEvaluationTask(
            id: "multiple-paragraph-summary",
            action: .summarize,
            selectedText: """
            The first release focuses on local Markdown editing with strong reading controls. Writers can keep drafts as normal files and move between write, read, and split modes.

            Future releases may add export workflows, collaboration, and deeper automation. Those features should not compromise the app's local-first privacy model.
            """,
            documentContext: "",
            length: .multipleParagraphs,
            requiresTransformation: true,
            requiresCompression: true,
            requiresMarkdownPreservation: false
        ),
        IntelligentEditingEvaluationTask(
            id: "multiple-paragraph-clean-markdown",
            action: .cleanMarkdown,
            selectedText: """
            # Release notes

            -  Fixed typo
            -    Improved spacing

            ```swift
            let value = 1
            ```
            """,
            documentContext: "",
            length: .multipleParagraphs,
            requiresTransformation: true,
            requiresCompression: false,
            requiresMarkdownPreservation: true
        )
    ]

    static let liveTasks: [IntelligentEditingEvaluationTask] = goldenTasks
}

extension IntelligentEditingAction {
    func requiresNonIdenticalReplacement(for selectedText: String) -> Bool {
        switch self {
        case .rewrite, .summarize, .shorten:
            return true
        case .proofread:
            return false
        case .cleanMarkdown:
            return Self.hasMessyMarkdownFormatting(selectedText)
        }
    }

    private static func hasMessyMarkdownFormatting(_ text: String) -> Bool {
        let patterns = [
            #"(?m)^#{1,6}\S"#,
            #"(?m)^[-*]\s{2,}\S"#,
            #"(?m)^\s{2,}[-*]\s+\S"#,
            #"\n{3,}"#
        ]

        return patterns.contains { pattern in
            text.range(of: pattern, options: .regularExpression) != nil
        }
    }
}
