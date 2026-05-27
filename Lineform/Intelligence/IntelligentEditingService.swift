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

struct FoundationModelsIntelligentEditingService: IntelligentEditingServicing {
    static let responseTimeoutNanoseconds: UInt64 = 20_000_000_000
    static let maximumRepairAttempts = 2

    private let availabilityService = IntelligenceAvailabilityService()
    private let promptBuilder = IntelligentEditingPromptBuilder()

    func replacement(for action: IntelligentEditingAction, selectedText: String, documentContext: String) async throws -> String {
        var prompt = promptBuilder.prompt(for: action, selectedText: selectedText, documentContext: documentContext)
        let evaluationTask = Self.evaluationTask(for: action, selectedText: selectedText, documentContext: documentContext)

        var lastInvalidResponse: String?
        var lastFailureSummary: String?

        for attempt in 0...Self.maximumRepairAttempts {
            let replacement = try await responseContent(for: prompt)
            let evaluation = IntelligentEditingEvaluationRubric.evaluate(replacement: replacement, task: evaluationTask)
            if evaluation.passed {
                return replacement.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            lastInvalidResponse = replacement
            lastFailureSummary = evaluation.failureSummary

            guard attempt < Self.maximumRepairAttempts else {
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

    func replacements(for action: IntelligentEditingAction, selectedText: String, documentContext: String, count: Int) async throws -> [String] {
        let optionCount = min(max(count, 1), IntelligentEditingPresentationPolicy.maximumOptionCount)
        guard optionCount > 1 else {
            return [try await replacement(for: action, selectedText: selectedText, documentContext: documentContext)]
        }

        let basePrompt = promptBuilder.prompt(for: action, selectedText: selectedText, documentContext: documentContext)
        let prompt = """
        \(basePrompt)

        Return exactly \(optionCount) distinct useful alternatives in this exact tagged format:
        \(IntelligentEditingOptionResponseParser.exampleFormat(for: optionCount))

        Put one real replacement between each start tag and end tag.
        Never return placeholder, dummy, or unchanged text.
        Do not include commentary outside the tags.
        """

        let content = try await responseContent(for: prompt)
        let evaluationTask = Self.evaluationTask(for: action, selectedText: selectedText, documentContext: documentContext)
        let options = IntelligentEditingOptionResponseParser.parse(content, expectedCount: optionCount)
            .filter { IntelligentEditingEvaluationRubric.evaluate(replacement: $0, task: evaluationTask).passed }
        guard !options.isEmpty else {
            throw IntelligentEditingError.emptyResponse
        }
        return options
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

    private static func evaluationTask(for action: IntelligentEditingAction, selectedText: String, documentContext: String) -> IntelligentEditingEvaluationTask {
        IntelligentEditingEvaluationTask(
            id: "service-validation",
            action: action,
            selectedText: selectedText,
            documentContext: documentContext,
            length: selectionLength(for: selectedText),
            requiresTransformation: action.requiresNonIdenticalReplacement(for: selectedText),
            requiresCompression: action == .summarize || action == .shorten,
            requiresMarkdownPreservation: action == .cleanMarkdown
        )
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

enum IntelligentEditingOptionResponseParser {
    static func exampleFormat(for count: Int) -> String {
        (1...count)
            .map { index in
                """
                <<<LINEFORM_OPTION_\(index)>>>
                <<<END_LINEFORM_OPTION_\(index)>>>
                """
            }
            .joined(separator: "\n")
    }

    static func parse(_ response: String, expectedCount: Int) -> [String] {
        let taggedOptions = (1...expectedCount).compactMap { index in
            taggedOption(index, in: response)
        }

        if !taggedOptions.isEmpty {
            return taggedOptions
        }

        return Array(fallbackOptions(in: response).prefix(expectedCount))
    }

    private static func taggedOption(_ index: Int, in response: String) -> String? {
        let startTag = "<<<LINEFORM_OPTION_\(index)>>>"
        let endTag = "<<<END_LINEFORM_OPTION_\(index)>>>"

        guard
            let startRange = response.range(of: startTag),
            let endRange = response.range(of: endTag, range: startRange.upperBound..<response.endIndex)
        else {
            return nil
        }

        let option = response[startRange.upperBound..<endRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return option.isEmpty || isPlaceholder(option) ? nil : option
    }

    private static func isPlaceholder(_ option: String) -> Bool {
        let normalized = option
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return normalized.hasPrefix("replacement option")
            || normalized.hasPrefix("<write only replacement")
            || normalized.hasPrefix("option ")
    }

    private static func fallbackOptions(in response: String) -> [String] {
        let lines = response
            .components(separatedBy: .newlines)
            .map { strippedListMarker(from: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.isEmpty && !isPlaceholder($0) }

        if !lines.isEmpty {
            return lines
        }

        let trimmedResponse = response.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedResponse.isEmpty || isPlaceholder(trimmedResponse) ? [] : [trimmedResponse]
    }

    private static func strippedListMarker(from line: String) -> String {
        let patterns = [
            #"^\d+[\.)]\s+"#,
            #"^[-*]\s+"#
        ]

        for pattern in patterns {
            if let range = line.range(of: pattern, options: .regularExpression) {
                return String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return line
    }
}
