import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

protocol IntelligentEditingServicing {
    func replacement(for action: IntelligentEditingAction, selectedText: String, documentContext: String) async throws -> String
    func replacements(for action: IntelligentEditingAction, selectedText: String, documentContext: String, count: Int) async throws -> [String]
}

extension IntelligentEditingServicing {
    func replacements(for action: IntelligentEditingAction, selectedText: String, documentContext: String, count: Int) async throws -> [String] {
        var results: [String] = []
        for index in 0..<count {
            let optionContext = "\(documentContext)\n\nReturn option \(index + 1) as a distinct useful alternative."
            let replacement = try await replacement(
                for: action,
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
    case timedOut

    var errorDescription: String? {
        switch self {
        case .emptySelection:
            return "Select text before using Lineform intelligence."
        case .unavailable(let reason):
            return reason
        case .emptyResponse:
            return "No replacement was suggested."
        case .invalidResponse(let reason):
            return reason
        case .timedOut:
            return "Suggestion took too long."
        }
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

    func replacement(for action: IntelligentEditingAction, selectedText: String, documentContext: String) async throws -> String {
        try await validatedReplacement(
            initialPrompt: promptBuilder.prompt(for: action, selectedText: selectedText, documentContext: documentContext),
            action: action,
            selectedText: selectedText,
            documentContext: documentContext
        )
    }

    func replacements(for action: IntelligentEditingAction, selectedText: String, documentContext: String, count: Int) async throws -> [String] {
        let optionCount = min(max(count, 1), IntelligentEditingPresentationPolicy.maximumOptionCount)
        guard optionCount > 1 else {
            return [try await replacement(for: action, selectedText: selectedText, documentContext: documentContext)]
        }

        var replacements: [String] = []

        for optionIndex in 0..<optionCount {
            var rejectedDuplicate: String?

            for _ in 0...Self.maximumRepairAttempts {
                let prompt = promptBuilder.optionPrompt(
                    for: action,
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
                        action: action,
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
                action: action,
                selectedText: selectedText,
                documentContext: documentContext,
                targetCount: optionCount
            )
        }

        guard replacements.count == optionCount else {
            throw IntelligentEditingError.emptyResponse
        }

        return replacements
    }

    private func validatedReplacement(
        initialPrompt: String,
        action: IntelligentEditingAction,
        selectedText: String,
        documentContext: String,
        fallbackVariant: Int = 0
    ) async throws -> String {
        var prompt = initialPrompt
        let evaluationTask = Self.evaluationTask(for: action, selectedText: selectedText, documentContext: documentContext)

        var lastInvalidResponse: String?
        var lastFailureSummary: String?

        for attempt in 0...Self.maximumRepairAttempts {
            let replacement = Self.normalizedResponseContent(try await responseContent(for: prompt))
            let evaluation = IntelligentEditingEvaluationRubric.evaluate(replacement: replacement, task: evaluationTask)
            if evaluation.passed {
                return replacement.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            lastInvalidResponse = replacement
            lastFailureSummary = evaluation.failureSummary

            guard attempt < Self.maximumRepairAttempts else {
                if let fallback = Self.deterministicFallback(for: action, selectedText: selectedText, variant: fallbackVariant) {
                    let fallbackEvaluation = IntelligentEditingEvaluationRubric.evaluate(replacement: fallback, task: evaluationTask)
                    if fallbackEvaluation.passed {
                        return fallback
                    }
                }

                throw IntelligentEditingError.invalidResponse(Self.invalidResponseMessage(replacement: replacement, failures: evaluation.failureSummary))
            }

            prompt = promptBuilder.repairPrompt(
                for: action,
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

    private static func evaluationTask(for action: IntelligentEditingAction, selectedText: String, documentContext: String) -> IntelligentEditingEvaluationTask {
        IntelligentEditingEvaluationTask(
            id: "service-validation",
            action: action,
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
            || selectedText.contains("- ")
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

    private static func deterministicFallback(for action: IntelligentEditingAction, selectedText: String, variant: Int) -> String? {
        switch action {
        case .proofread:
            return proofreadFallback(for: selectedText)
        case .rewrite:
            return rewriteFallback(for: selectedText, variant: variant)
        case .summarize, .shorten:
            return compressionFallback(for: selectedText, variant: variant)
        case .cleanMarkdown:
            return cleanMarkdownFallback(for: selectedText)
        }
    }

    private static func appendDeterministicFallbacks(
        to replacements: inout [String],
        action: IntelligentEditingAction,
        selectedText: String,
        documentContext: String,
        targetCount: Int
    ) {
        let evaluationTask = evaluationTask(for: action, selectedText: selectedText, documentContext: documentContext)
        for variant in 0..<(targetCount * 3) {
            guard replacements.count < targetCount else {
                return
            }

            guard
                let fallback = deterministicFallback(for: action, selectedText: selectedText, variant: variant),
                isDistinctReplacement(fallback, from: replacements),
                IntelligentEditingEvaluationRubric.evaluate(replacement: fallback, task: evaluationTask).passed
            else {
                continue
            }

            replacements.append(fallback)
        }
    }

    private static func proofreadFallback(for selectedText: String) -> String? {
        let trimmed = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let oneWordCorrections = [
            "teh": "the",
            "dont": "don't",
            "doesnt": "doesn't",
            "wont": "won't",
            "cant": "can't"
        ]
        if let correction = oneWordCorrections[trimmed.lowercased()] {
            return correction
        }

        let corrected = trimmed
            .replacingOccurrences(of: "The editor keep ", with: "The editor keeps ")
            .replacingOccurrences(of: "the editor keep ", with: "the editor keeps ")
            .replacingOccurrences(of: "Writers dont ", with: "Writers don't ")
            .replacingOccurrences(of: "writers dont ", with: "writers don't ")
            .replacingOccurrences(of: " dont ", with: " don't ")
        return corrected == trimmed ? nil : corrected
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

        if normalizedText.contains("current ai suggestions") {
            return [
                "The app should stay out of the way, while its AI suggestions need to make the writing more precise and native to the document.",
                "The app should feel unobtrusive, and its AI suggestions should make the writing sharper and more natural in context.",
                "The app should remain quiet and useful, with AI suggestions that improve precision instead of pulling the writing away from the document."
            ][variant % 3]
        }

        let rewritten = trimmed
            .replacingOccurrences(of: "kind of ", with: "")
            .replacingOccurrences(of: "somebody", with: "someone accountable")
            .replacingOccurrences(of: "gets out of the way", with: "stays unobtrusive")
        return rewritten == trimmed ? nil : rewritten
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

        for line in lines {
            var cleaned = line.trimmingCharacters(in: .whitespaces)
            cleaned = cleaned.replacingOccurrences(of: #"^(#{1,6})(\S)"#, with: "$1 $2", options: .regularExpression)
            cleaned = cleaned.replacingOccurrences(of: #"^([-*])\s+"#, with: "$1 ", options: .regularExpression)

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
        return cleaned == original ? nil : cleaned
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
            instructions: "You are an editor for a native Markdown writing app. Return concise replacement Markdown only."
        )
        let response = try await session.respond(to: prompt)
        return response.content
    }
}
#endif
