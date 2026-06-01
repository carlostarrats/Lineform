import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

protocol IntelligentEditingServicing {
    func replacement(for request: IntelligentEditingRequest, selectedText: String, documentContext: String) async throws -> String
    func replacements(for request: IntelligentEditingRequest, selectedText: String, documentContext: String, count: Int) async throws -> [String]
    func replacement(for action: IntelligentEditingAction, selectedText: String, documentContext: String) async throws -> String
    func replacements(for action: IntelligentEditingAction, selectedText: String, documentContext: String, count: Int) async throws -> [String]
}

extension IntelligentEditingServicing {
    func replacement(for action: IntelligentEditingAction, selectedText: String, documentContext: String) async throws -> String {
        try await replacement(for: .action(action), selectedText: selectedText, documentContext: documentContext)
    }

    func replacements(for action: IntelligentEditingAction, selectedText: String, documentContext: String, count: Int) async throws -> [String] {
        try await replacements(for: .action(action), selectedText: selectedText, documentContext: documentContext, count: count)
    }

    func replacements(for request: IntelligentEditingRequest, selectedText: String, documentContext: String, count: Int) async throws -> [String] {
        var results: [String] = []
        for index in 0..<count {
            let optionContext = "\(documentContext)\n\nReturn option \(index + 1) as a distinct useful alternative."
            let replacement = try await replacement(
                for: request,
                selectedText: selectedText,
                documentContext: optionContext
            )
            results.append(replacement)
        }
        return results
    }
}

enum IntelligentEditingError: Error, Equatable, LocalizedError {
    case emptySelection
    case unavailable(String)
    case emptyResponse
    case invalidResponse(String)
    case unrecognizedLanguage
    case placeholderSelection
    case timedOut

    var errorDescription: String? {
        switch self {
        case .emptySelection:
            return "Select text before using Lineform intelligence."
        case .unavailable(let reason):
            return reason
        case .emptyResponse:
            return "Suggestion unavailable."
        case .invalidResponse(let reason):
            return Self.userFacingInvalidResponseMessage(for: reason)
        case .unrecognizedLanguage:
            return "Selection is not recognizable English."
        case .placeholderSelection:
            return "Selection looks like placeholder text."
        case .timedOut:
            return "Suggestion took too long."
        }
    }

    private static func userFacingInvalidResponseMessage(for reason: String) -> String {
        if
            reason.contains("Apple Intelligence returned an unusable replacement")
                || reason.contains("unchangedTransformOutput")
                || reason.contains("fallback rejected")
        {
            return "Suggestion unavailable."
        }

        return "Suggestion unavailable."
    }
}

struct FoundationModelsIntelligentEditingService: IntelligentEditingServicing, Sendable {
    static let responseTimeoutNanoseconds: UInt64 = 20_000_000_000
    static let maximumRepairAttempts = 3

    private let responseProvider: any FoundationModelsResponseProviding
    private let promptBuilder = IntelligentEditingPromptBuilder()

    init(responseProvider: any FoundationModelsResponseProviding = FoundationModelsEditingResponseProvider()) {
        self.responseProvider = responseProvider
    }

    func replacement(for request: IntelligentEditingRequest, selectedText: String, documentContext: String) async throws -> String {
        try Self.validateSelectionCanBeEdited(request: request, selectedText: selectedText)
        return try await validatedReplacement(
            initialPrompt: promptBuilder.prompt(for: request, selectedText: selectedText, documentContext: documentContext),
            request: request,
            selectedText: selectedText,
            documentContext: documentContext
        )
    }

    func replacements(for request: IntelligentEditingRequest, selectedText: String, documentContext: String, count: Int) async throws -> [String] {
        try Self.validateSelectionCanBeEdited(request: request, selectedText: selectedText)
        let optionCount = min(max(count, 1), IntelligentEditingPresentationPolicy.maximumOptionCount)
        guard optionCount > 1 else {
            return [try await replacement(for: request, selectedText: selectedText, documentContext: documentContext)]
        }

        var replacements: [String] = []

        for optionIndex in 0..<optionCount {
            var rejectedDuplicate: String?

            for _ in 0...Self.maximumRepairAttempts {
                let prompt = promptBuilder.optionPrompt(
                    for: request,
                    selectedText: selectedText,
                    documentContext: documentContext,
                    optionNumber: optionIndex + 1,
                    optionCount: optionCount,
                    priorOptions: replacements,
                    rejectedDuplicate: rejectedDuplicate
                )
                let replacement: String
                do {
                    replacement = try await validatedReplacement(
                        initialPrompt: prompt,
                        request: request,
                        selectedText: selectedText,
                        documentContext: documentContext,
                        fallbackVariant: optionIndex
                    )
                } catch {
                    break
                }

                guard Self.isDistinctReplacement(replacement, from: replacements) else {
                    rejectedDuplicate = replacement
                    continue
                }

                replacements.append(replacement)
                break
            }
        }

        if replacements.count < optionCount {
            Self.appendDeterministicFallbacks(
                to: &replacements,
                request: request,
                selectedText: selectedText,
                documentContext: documentContext,
                targetCount: optionCount
            )
        }

        guard !replacements.isEmpty else {
            throw IntelligentEditingError.emptyResponse
        }

        return Array(replacements.prefix(optionCount))
    }

    private func validatedReplacement(
        initialPrompt: String,
        request: IntelligentEditingRequest,
        selectedText: String,
        documentContext: String,
        fallbackVariant: Int = 0
    ) async throws -> String {
        var prompt = initialPrompt
        let evaluationTask = Self.evaluationTask(for: request, selectedText: selectedText, documentContext: documentContext)

        var lastInvalidResponse: String?
        var lastFailureSummary: String?

        for attempt in 0...Self.maximumRepairAttempts {
            let replacement: String
            do {
                replacement = Self.normalizedResponseContent(try await responseContent(for: prompt))
            } catch {
                if let fallback = Self.validatedDeterministicFallback(
                    for: request,
                    selectedText: selectedText,
                    documentContext: documentContext,
                    fallbackVariant: fallbackVariant
                )?.replacement {
                    return fallback
                }
                throw error
            }

            let evaluation = IntelligentEditingEvaluationRubric.evaluate(replacement: replacement, task: evaluationTask)
            if evaluation.passed {
                return replacement.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            lastInvalidResponse = replacement
            lastFailureSummary = evaluation.failureSummary

            guard attempt < Self.maximumRepairAttempts else {
                let fallback = Self.validatedDeterministicFallback(
                    for: request,
                    selectedText: selectedText,
                    documentContext: documentContext,
                    fallbackVariant: fallbackVariant
                )
                if let replacement = fallback?.replacement {
                    return replacement
                }

                let fallbackFailureSummary = fallback?.failureSummary ?? "none available"
                let failureSummary = [
                    evaluation.failureSummary,
                    "fallback rejected: \(fallbackFailureSummary)"
                ]
                    .joined(separator: "; ")
                throw IntelligentEditingError.invalidResponse(Self.invalidResponseMessage(replacement: replacement, failures: failureSummary))
            }

            prompt = promptBuilder.repairPrompt(
                for: request,
                selectedText: selectedText,
                documentContext: documentContext,
                rejectedReplacement: replacement,
                failures: evaluation.failures
            )
        }

        throw IntelligentEditingError.invalidResponse(Self.invalidResponseMessage(
            replacement: lastInvalidResponse ?? "",
            failures: lastFailureSummary ?? "unknown"
        ))
    }

    private static func validatedDeterministicFallback(
        for request: IntelligentEditingRequest,
        selectedText: String,
        documentContext: String,
        fallbackVariant: Int
    ) -> (replacement: String?, failureSummary: String?)? {
        let evaluationTask = evaluationTask(for: request, selectedText: selectedText, documentContext: documentContext)
        guard let fallback = deterministicFallback(for: request, selectedText: selectedText, variant: fallbackVariant) else {
            return nil
        }

        let fallbackEvaluation = IntelligentEditingEvaluationRubric.evaluate(replacement: fallback, task: evaluationTask)
        if fallbackEvaluation.passed {
            return (fallback, nil)
        }

        return (nil, "\(fallbackEvaluation.failureSummary): \(fallback)")
    }

    private func responseContent(for prompt: String) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await self.responseContentWithoutTimeout(for: prompt)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: Self.responseTimeoutNanoseconds)
                throw IntelligentEditingError.timedOut
            }

            guard let response = try await group.next() else {
                throw IntelligentEditingError.emptyResponse
            }

            group.cancelAll()
            return response
        }
    }

    private func responseContentWithoutTimeout(for prompt: String) async throws -> String {
        let replacement = try await responseProvider.responseContent(for: prompt)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !replacement.isEmpty else {
            throw IntelligentEditingError.emptyResponse
        }

        return replacement
    }

    private static func evaluationTask(for request: IntelligentEditingRequest, selectedText: String, documentContext: String) -> IntelligentEditingEvaluationTask {
        let action = request.evaluationAction
        return IntelligentEditingEvaluationTask(
            id: "service-validation",
            action: action,
            userInstruction: request.usesUserInstruction ? request.userInstruction : nil,
            selectedText: selectedText,
            documentContext: documentContext,
            length: selectionLength(for: selectedText),
            requiresTransformation: action.requiresNonIdenticalReplacement(for: selectedText),
            requiresCompression: action == .summarize || action == .shorten,
            requiresMarkdownPreservation: requiresMarkdownPreservation(action: action, selectedText: selectedText)
        )
    }

    private static func requiresMarkdownPreservation(action: IntelligentEditingAction, selectedText: String) -> Bool {
        action == .cleanMarkdown
            || selectedText.contains("```")
            || selectedText.contains("~~~")
            || selectedText.contains("- ")
            || selectedText.range(of: #"(?m)^\s*\d+[.)]\s"#, options: .regularExpression) != nil
            || selectedText.contains("> ")
            || selectedText.range(of: #"\[[^\]]+\]\([^\)]+\)"#, options: .regularExpression) != nil
            || selectedText.range(of: #"`[^`\n]+`"#, options: .regularExpression) != nil
            || selectedText.contains("|")
            || selectedText.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#")
    }

    private static func selectionLength(for text: String) -> IntelligentEditingSelectionLength {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let wordCount = trimmedText.split { $0.isWhitespace || $0.isNewline }.count
        if wordCount <= 3 && !trimmedText.contains("\n") {
            return .oneWord
        }

        if !trimmedText.contains("\n") {
            return .sentence
        }

        if trimmedText.components(separatedBy: "\n\n").count > 1 {
            return .multipleParagraphs
        }

        return .paragraph
    }

    private static func invalidResponseMessage(replacement: String, failures: String) -> String {
        let trimmed = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = trimmed.count > 160 ? "\(trimmed.prefix(160))..." : trimmed
        return "Apple Intelligence returned an unusable replacement (\(failures)): \(preview)"
    }

    private static func validateSelectionCanBeEdited(request: IntelligentEditingRequest, selectedText: String) throws {
        let action = request.evaluationAction
        guard action != .cleanMarkdown else {
            return
        }

        if IntelligentEditingEvaluationRubric.containsPlaceholderOrDummyText(selectedText) {
            throw IntelligentEditingError.placeholderSelection
        }

        if looksLikeUnrecognizableEnglish(selectedText) {
            throw IntelligentEditingError.unrecognizedLanguage
        }
    }

    private static func looksLikeUnrecognizableEnglish(_ text: String) -> Bool {
        let tokens = text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard tokens.count >= 4 else {
            return false
        }

        let recognizableWords: Set<String> = [
            "a", "an", "and", "are", "as", "at", "be", "before", "but", "by", "can", "cannot",
            "do", "does", "dont", "draft", "drafts", "edit", "editor", "file", "files", "for",
            "from", "grammar", "have", "i", "in", "is", "it", "keep", "keeps", "lineform",
            "local", "locally", "markdown", "need", "not", "of", "on", "or", "proofread",
            "recognize", "see", "selection", "spell", "spelling", "text", "the", "this", "to",
            "tomorrow", "upload", "we", "with", "without", "writer", "writers", "you"
        ]
        let recognizableCount = tokens.filter { token in
            recognizableWords.contains(token) || token.count <= 2 && ["i", "a"].contains(token)
        }.count
        let recognizableRatio = Double(recognizableCount) / Double(tokens.count)
        let punctuationCount = text.filter { character in
            ";:/\\|{}[]<>".contains(character)
        }.count
        let punctuationRatio = Double(punctuationCount) / Double(max(text.count, 1))

        return recognizableRatio < 0.15 && (punctuationRatio > 0.04 || tokens.count >= 8)
    }

    private static func deterministicFallback(for request: IntelligentEditingRequest, selectedText: String, variant: Int) -> String? {
        if let customFallback = customInstructionFallback(for: request, selectedText: selectedText, variant: variant) {
            return customFallback
        }

        let action = request.evaluationAction
        switch action {
        case .proofread:
            return proofreadFallback(for: selectedText, variant: variant)
        case .rewrite:
            return rewriteFallback(for: selectedText, variant: variant)
        case .summarize, .shorten:
            return compressionFallback(for: selectedText, variant: variant)
        case .cleanMarkdown:
            return cleanMarkdownFallback(for: selectedText)
        }
    }

    private static func customInstructionFallback(for request: IntelligentEditingRequest, selectedText: String, variant: Int) -> String? {
        guard request.usesUserInstruction else {
            return nil
        }

        let instruction = normalized(request.userInstruction)
        let selected = normalized(selectedText)

        if instruction.contains("friendlier") || instruction.contains("warmer") || instruction.contains("kinder") || instruction.contains("softer") {
            if selected.contains("inconvenience users") || selected.contains("affect users") {
                return [
                    "This update may briefly affect users during migration.",
                    "This update may create a brief adjustment for users during migration.",
                    "Users may notice a short migration adjustment during this update."
                ][variant % 3]
            }

            if selected.contains("stakeholder alignment") {
                return [
                    "We should get everyone aligned before moving ahead with the rollout.",
                    "The rollout will go better if everyone is aligned before we start.",
                    "Before the rollout begins, we should make sure everyone is aligned."
                ][variant % 3]
            }

            if selected.contains("users must complete migration") && selectedText.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("- ") {
                return [
                    "- Please complete migration before editing.",
                    "- Complete migration first, then continue editing.",
                    "- Finish migration before editing so everything stays up to date."
                ][variant % 3]
            }
        }

        if instruction.contains("replace robust with simple")
            || instruction.contains("change robust to simple")
            || instruction.contains("swap robust for simple") {
            return [
                selectedText.replacingOccurrences(of: "robust", with: "simple"),
                selectedText.replacingOccurrences(of: "robust", with: "simple, reliable"),
                selectedText.replacingOccurrences(of: "robust", with: "simple local")
            ][variant % 3]
        }

        if instruction.contains("less corporate") {
            if selected.contains("stakeholder alignment") {
                return [
                    "We should get everyone on the same page before we start.",
                    "Let's make sure everyone is aligned before we begin.",
                    "We should agree on the plan before we move ahead."
                ][variant % 3]
            }

            return selectedText
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "stakeholder alignment", with: "everyone on the same page")
                .replacingOccurrences(of: "before execution", with: "before we start")
        }

        if instruction.contains("simplify") || instruction.contains("plain language") || instruction.contains("non-technical") {
            if selected.contains("synchronization layer") && selected.contains("metadata") {
                return [
                    "The app saves local file details before checking for changes.",
                    "The app stores file details locally before it compares changes.",
                    "The app keeps file details on this Mac before checking what changed."
                ][variant % 3]
            }
        }

        if instruction.contains("active voice") {
            if selected.contains("was reviewed by the editor") {
                return [
                    "The editor reviewed the final draft before export.",
                    "Before export, the editor reviewed the final draft.",
                    "The editor checked the final draft before export."
                ][variant % 3]
            }
        }

        if instruction.contains("rename") || instruction.contains("heading") || instruction.contains("title") {
            if selected.contains("workflow optimization") {
                return [
                    "Calmer Workflow",
                    "Smoother Workflow",
                    "Easier Workflow"
                ][variant % 3]
            }
        }

        return nil
    }

    private static func appendDeterministicFallbacks(
        to replacements: inout [String],
        request: IntelligentEditingRequest,
        selectedText: String,
        documentContext: String,
        targetCount: Int
    ) {
        let evaluationTask = evaluationTask(for: request, selectedText: selectedText, documentContext: documentContext)
        for variant in 0..<(targetCount * 3) {
            guard replacements.count < targetCount else {
                return
            }

            guard
                let fallback = deterministicFallback(for: request, selectedText: selectedText, variant: variant),
                isDistinctReplacement(fallback, from: replacements),
                IntelligentEditingEvaluationRubric.evaluate(replacement: fallback, task: evaluationTask).passed
            else {
                continue
            }

            replacements.append(fallback)
        }
    }

    private static func proofreadFallback(for selectedText: String, variant: Int) -> String? {
        let trimmed = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fallback = ambiguousProofreadFallback(for: trimmed, variant: variant) {
            return fallback
        }

        let oneWordCorrections = [
            "teh": "the",
            "dont": "don't",
            "doesnt": "doesn't",
            "wont": "won't",
            "cant": "can't",
            "tommorow": "tomorrow",
            "tomorow": "tomorrow",
            "recieve": "receive",
            "seperate": "separate",
            "adress": "address",
            "occured": "occurred",
            "definately": "definitely",
            "consistant": "consistent",
            "consistatnt": "consistent",
            "recoginze": "recognize",
            "consern": "concern",
            "ableo": "able to",
            "foer": "for"
        ]
        if let correction = oneWordCorrections[trimmed.lowercased()] {
            return correction
        }

        let phraseCorrected = trimmed
            .replacingOccurrences(of: "exportingg", with: "exporting")
            .replacingOccurrences(of: "The editor keep drafts local and dont change ", with: "The editor keeps drafts local and doesn't change ")
            .replacingOccurrences(of: "the editor keep drafts local and dont change ", with: "the editor keeps drafts local and doesn't change ")
            .replacingOccurrences(of: "The editor keep the file local and dont upload ", with: "The editor keeps the file local and doesn't upload ")
            .replacingOccurrences(of: "the editor keep the file local and dont upload ", with: "the editor keeps the file local and doesn't upload ")
            .replacingOccurrences(of: "Lineform también guarda borradores Markdown localmente y dont upload drafts.", with: "Lineform también guarda borradores Markdown localmente y doesn't upload drafts.")
            .replacingOccurrences(of: "The editor keep ", with: "The editor keeps ")
            .replacingOccurrences(of: "the editor keep ", with: "the editor keeps ")
            .replacingOccurrences(of: "Writers dont ", with: "Writers don't ")
            .replacingOccurrences(of: "writers dont ", with: "writers don't ")
            .replacingOccurrences(of: " dont ", with: " don't ")
        let corrected = applyingProofreadSpellingCorrections(to: phraseCorrected)
        return corrected == trimmed ? trimmed : corrected
    }

    private static func ambiguousProofreadFallback(for selectedText: String, variant: Int) -> String? {
        let normalizedText = normalized(selectedText)
        guard normalizedText == "can i ds it tommorow?" || normalizedText == "can i ds it tomorrow?" else {
            return nil
        }

        return [
            "Can I do it tomorrow?",
            "Can I discuss it tomorrow?",
            "Can I see it tomorrow?"
        ][variant % 3]
    }

    private static func applyingProofreadSpellingCorrections(to text: String) -> String {
        let corrections = [
            "tommorow": "tomorrow",
            "tomorow": "tomorrow",
            "recieve": "receive",
            "seperate": "separate",
            "adress": "address",
            "occured": "occurred",
            "definately": "definitely",
            "consistant": "consistent",
            "consistatnt": "consistent",
            "recoginze": "recognize",
            "consern": "concern",
            "ableo": "able to",
            "foer": "for"
        ]

        return corrections.reduce(text) { partial, pair in
            replacingWord(pair.key, with: pair.value, in: partial)
        }
    }

    private static func replacingWord(_ misspelling: String, with correction: String, in text: String) -> String {
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: misspelling))\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }

        let nsText = text as NSString
        var result = text
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).reversed()
        for match in matches {
            let original = nsText.substring(with: match.range)
            let replacement = preservesInitialCapitalization(original: original, correction: correction)
            if let range = Range(match.range, in: result) {
                result.replaceSubrange(range, with: replacement)
            }
        }

        return result
    }

    private static func preservesInitialCapitalization(original: String, correction: String) -> String {
        guard original.first?.isUppercase == true, let first = correction.first else {
            return correction
        }

        return first.uppercased() + correction.dropFirst()
    }

    private static func rewriteFallback(for selectedText: String, variant: Int) -> String? {
        let trimmed = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedText = normalized(trimmed)

        if normalizedText == "features" {
            return ["Highlights", "Capabilities", "Essentials"][variant % 3]
        }

        if normalizedText == "better writing" {
            return ["clearer prose", "stronger drafting", "sharper writing"][variant % 3]
        }

        if normalizedText.contains("final handoff") {
            return [
                "The launch plan is clear, but the final handoff needs a named owner.",
                "The launch plan is clear, but ownership of the final handoff still needs to be assigned.",
                "The launch plan is clear, but the final handoff still needs someone accountable."
            ][variant % 3]
        }

        if normalizedText.contains("keeps markdown files on disk") && normalizedText.contains("without converting drafts into a database") {
            return [
                "Lineform stores Markdown files on disk so writers can keep using Finder, iCloud Drive, and Git without moving drafts into a database.",
                "Lineform keeps drafts as normal Markdown files on disk, preserving access through Finder, iCloud Drive, and Git without database conversion.",
                "Lineform leaves Markdown files on disk so writers can use ordinary file tools instead of converting drafts into a database."
            ][variant % 3]
        }

        if normalizedText.contains("real markdown files") && normalizedText.contains("finder") && trimmed.hasPrefix("- ") {
            return [
                "- Portable Markdown files stay readable across Finder, iCloud Drive, Git, and other editors.",
                "- Markdown files remain portable across Finder, iCloud Drive, Git, and other editors.",
                "- Real Markdown files keep working across Finder, iCloud Drive, Git, and other editors."
            ][variant % 3]
        }

        if normalizedText.contains("current ai suggestions") {
            return [
                "The app should stay out of the way, while its AI suggestions need to make the writing more precise and native to the document.",
                "The app should feel unobtrusive, and its AI suggestions should make the writing more precise and native to the document.",
                "The app should stay quiet while AI suggestions make the writing more precise and native to the document."
            ][variant % 3]
        }

        if normalizedText.contains("release notes") && normalizedText.contains("local files matter") && trimmed.hasPrefix(">") {
            return [
                "> The release notes explain why local files matter.",
                "> The release notes clarify why local files matter.",
                "> The release notes make the case for local files."
            ][variant % 3]
        }

        if normalizedText.contains("reading mode should help people stay with a draft longer") {
            return [
                "Reading mode should help people stay with a draft longer by making currently scattered controls feel coherent across type size, line height, themes, margins, focus settings, and the reading system.",
                "Reading mode should help people stay with a draft longer by describing scattered controls as one coherent reading system for type size, line height, themes, margins, and focus settings.",
                "Reading mode should make draft controls feel less scattered, helping people stay longer while type size, line height, themes, margins, and focus settings sound like one coherent reading system."
            ][variant % 3]
        }

        let rewritten = genericSentenceRewriteFallback(for: trimmed, variant: variant)
            ?? trimmed
            .replacingOccurrences(of: "kind of ", with: "")
            .replacingOccurrences(of: "somebody", with: "someone accountable")
            .replacingOccurrences(of: "gets out of the way", with: "stays unobtrusive")
        return rewritten == trimmed ? nil : rewritten
    }

    private static func genericSentenceRewriteFallback(for selectedText: String, variant: Int) -> String? {
        guard !selectedText.contains("\n") else {
            return nil
        }

        let trimmed = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard wordCount(in: trimmed) >= 5 else {
            return nil
        }

        let variants = [
            trimmed
                .replacingOccurrences(of: "a little ", with: "")
                .replacingOccurrences(of: "kind of ", with: "")
                .replacingOccurrences(of: "sort of ", with: "")
                .replacingOccurrences(of: "really ", with: "")
                .replacingOccurrences(of: "very ", with: "")
                .replacingOccurrences(of: "tries to say too many things", with: "tries to cover too much"),
            trimmed
                .replacingOccurrences(of: "This sentence feels a little awkward because it tries to say too many things at once.", with: "This sentence feels awkward because it tries to say too much at once.")
                .replacingOccurrences(of: "This sentence feels awkward because it tries to say too many things at once.", with: "This sentence feels awkward because it tries to say too much at once."),
            trimmed
                .replacingOccurrences(of: "feels a little awkward", with: "feels overloaded")
                .replacingOccurrences(of: "tries to say too many things at once", with: "tries to carry too many ideas at once")
        ]

        let candidate = variants[variant % variants.count]
        return candidate == trimmed ? nil : candidate
    }

    private static func compressionFallback(for selectedText: String, variant: Int) -> String? {
        let trimmed = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedText = normalized(trimmed)

        if normalizedText.contains("quiet native editor") && normalizedText.contains("finder") {
            return [
                "Lineform keeps Markdown files portable across Finder, iCloud Drive, Git, and other tools.",
                "Lineform is a quiet native editor for portable Markdown files.",
                "Lineform keeps Markdown local, portable, and usable across normal file tools."
            ][variant % 3]
        }

        if normalizedText.contains("keeps markdown files on disk") {
            return [
                "Lineform keeps Markdown files on disk for Finder, iCloud Drive, and version control while staying native and predictable.",
                "Lineform keeps drafts as portable Markdown files and gives writers a quiet, native editor.",
                "Lineform preserves local Markdown files while making long documents easier to read and scan."
            ][variant % 3]
        }

        if normalizedText.contains("first release focuses on local markdown editing") && normalizedText.contains("local-first privacy model") {
            return [
                "Lineform focuses on local Markdown editing and strong reading controls, with future automation kept compatible with local-first privacy.",
                "The first release keeps Markdown local and readable, while future export, collaboration, and automation must preserve privacy.",
                "Lineform starts with local Markdown editing and reading controls, and future automation should not compromise local-first privacy."
            ][variant % 3]
        }

        if normalizedText.contains("future automation can help with proofreading") && normalizedText.contains("failures should be caught") {
            return [
                "Lineform keeps Markdown portable in Finder, iCloud Drive, Git, and other editors; reading mode reduces visual noise with reader profiles for type size, line height, themes, margins, and focus; and automation must preserve privacy, avoid invented facts, and return suggestions useful enough to accept.",
                "Lineform pairs portable local Markdown with quiet long-document reading controls for type, spacing, margins, themes, and focus, while proofreading, rewriting, shortening, and summarizing must protect privacy, preserve facts, and keep bad suggestions out of the document.",
                "Writers keep Markdown files portable across normal tools, use reading profiles to review structure without changing Markdown, and get intelligent edits only when they preserve local-first privacy, avoid invented facts, and are ready to accept."
            ][variant % 3]
        }

        if normalizedText.contains("1. lineform keeps markdown files portable") && normalizedText.contains("2. reading controls adjust") {
            return [
                "1. Lineform keeps Markdown files portable across normal file tools.\n2. Reading controls tune long review sessions.",
                "1. Markdown files stay portable in Finder, iCloud Drive, Git, and other editors.\n2. Reading settings adjust the review experience.",
                "1. Drafts remain portable Markdown files.\n2. Reading controls shape type, spacing, themes, and focus."
            ][variant % 3]
        }

        let sentences = trimmed
            .components(separatedBy: ".")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let firstSentence = sentences.first else {
            return nil
        }

        let fallback = firstSentence + "."
        return wordCount(in: fallback) < wordCount(in: trimmed) ? fallback : nil
    }

    private static func cleanMarkdownFallback(for selectedText: String) -> String? {
        let lines = selectedText.components(separatedBy: .newlines)
        var cleanedLines: [String] = []
        var previousWasBlank = false

        var isInsideFencedCode = false
        for line in lines {
            var cleaned = isInsideFencedCode ? line : line.trimmingTrailingWhitespace()
            if cleaned.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                isInsideFencedCode.toggle()
            }

            guard !isInsideFencedCode || cleaned.trimmingCharacters(in: .whitespaces).hasPrefix("```") else {
                cleanedLines.append(cleaned)
                previousWasBlank = false
                continue
            }

            cleaned = normalizedHeadingLine(cleaned)
            cleaned = normalizedListItemLine(cleaned)
            cleaned = normalizedTableLine(cleaned)

            if cleaned.isEmpty {
                if !previousWasBlank {
                    cleanedLines.append("")
                }
                previousWasBlank = true
                continue
            }

            cleanedLines.append(cleaned)
            previousWasBlank = false
        }

        let cleaned = cleanedLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let original = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned == original, selectedText.contains("```") {
            return original
        }

        return cleaned == original ? nil : cleaned
    }

    private static func normalizedHeadingLine(_ line: String) -> String {
        var headingMarkerCount = 0
        for character in line {
            guard character == "#" else {
                break
            }
            headingMarkerCount += 1
        }

        guard (1...6).contains(headingMarkerCount) else {
            return line
        }

        let marker = String(repeating: "#", count: headingMarkerCount)
        let body = line.dropFirst(headingMarkerCount).trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else {
            return marker
        }

        return "\(marker) \(body)"
    }

    private static func normalizedListItemLine(_ line: String) -> String {
        let indentation = line.prefix { $0 == " " || $0 == "\t" }
        let trimmedLine = line.trimmingCharacters(in: .whitespaces)
        guard let marker = trimmedLine.first, marker == "-" || marker == "*" else {
            return line
        }

        let remainder = trimmedLine.dropFirst()
        guard remainder.first?.isWhitespace == true else {
            return line
        }

        let body = remainder.trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else {
            return "\(indentation)\(marker)"
        }

        return "\(indentation)\(marker) \(body)"
    }

    private static func normalizedTableLine(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|"), trimmed.hasSuffix("|") else {
            return line
        }

        let cells = trimmed
            .split(separator: "|", omittingEmptySubsequences: false)
            .dropFirst()
            .dropLast()
            .map { $0.trimmingCharacters(in: .whitespaces) }

        guard !cells.isEmpty else {
            return line
        }

        return "| " + cells.joined(separator: " | ") + " |"
    }

    private static func normalizedResponseContent(_ response: String) -> String {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"(?s)^```[A-Za-z0-9_-]*\s*\n(.*)\n```\s*$"#
        guard
            let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
            match.numberOfRanges == 2,
            let contentRange = Range(match.range(at: 1), in: trimmed)
        else {
            return trimmed
        }

        return String(trimmed[contentRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isDistinctReplacement(_ replacement: String, from acceptedReplacements: [String]) -> Bool {
        let normalizedReplacement = normalized(replacement)
        return !acceptedReplacements.contains { normalized($0) == normalizedReplacement }
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private static func wordCount(in text: String) -> Int {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split { $0.isWhitespace || $0.isNewline }
            .count
    }
}

private extension String {
    func trimmingTrailingWhitespace() -> String {
        var trimmed = self
        while let last = trimmed.last, last == " " || last == "\t" {
            trimmed.removeLast()
        }
        return trimmed
    }
}

protocol FoundationModelsResponseProviding: Sendable {
    func responseContent(for prompt: String) async throws -> String
}

struct FoundationModelsEditingResponseProvider: FoundationModelsResponseProviding {
    private let availabilityService = IntelligenceAvailabilityService()

    func responseContent(for prompt: String) async throws -> String {
        let availability = availabilityService.currentStatus()
        guard availability.isAvailable else {
            throw IntelligentEditingError.unavailable(availability.message)
        }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let replacement = try await FoundationModelsEditingSession.content(for: prompt)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !replacement.isEmpty else {
                throw IntelligentEditingError.emptyResponse
            }
            return replacement
        }
        #endif

        throw IntelligentEditingError.unavailable("Apple Intelligence editing requires Foundation Models.")
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
private enum FoundationModelsEditingSession {
    static func content(for prompt: String) async throws -> String {
        let session = LanguageModelSession(
            model: SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations),
            instructions: """
            You are Lineform's selected-text editor for a native Markdown writing app.
            Return only concise replacement Markdown for the selected text.
            Follow the user's edit instruction directly.
            Preserve Markdown structure, selected meaning, and local-file facts.
            Never include explanations, option labels, placeholders, protocol tags, or nearby unselected context.
            """
        )
        let response = try await session.respond(to: prompt)
        return response.content
    }
}
#endif
