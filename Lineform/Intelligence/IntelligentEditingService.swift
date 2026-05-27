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

    var errorDescription: String? {
        switch self {
        case .emptySelection:
            return "Select text before using Lineform intelligence."
        case .unavailable(let reason):
            return reason
        case .emptyResponse:
            return "No replacement was suggested."
        }
    }
}

struct FoundationModelsIntelligentEditingService: IntelligentEditingServicing {
    private let availabilityService = IntelligenceAvailabilityService()
    private let promptBuilder = IntelligentEditingPromptBuilder()

    func replacement(for action: IntelligentEditingAction, selectedText: String, documentContext: String) async throws -> String {
        let prompt = promptBuilder.prompt(for: action, selectedText: selectedText, documentContext: documentContext)
        return try await responseContent(for: prompt)
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

        Do not include commentary outside the tags.
        """

        let content = try await responseContent(for: prompt)
        let options = IntelligentEditingOptionResponseParser.parse(content, expectedCount: optionCount)
        guard !options.isEmpty else {
            throw IntelligentEditingError.emptyResponse
        }
        return options
    }

    private func responseContent(for prompt: String) async throws -> String {
        let availability = availabilityService.currentStatus()
        guard availability.isAvailable else {
            throw IntelligentEditingError.unavailable(availability.message)
        }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let response = try await FoundationModelsEditingSession.shared.respond(to: prompt)
            let replacement = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
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
private final class FoundationModelsEditingSession {
    static let shared = LanguageModelSession(
        model: SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations),
        instructions: "You are an editor for a native Markdown writing app. Return concise replacement Markdown only."
    )
}
#endif

enum IntelligentEditingOptionResponseParser {
    static func exampleFormat(for count: Int) -> String {
        (1...count)
            .map { index in
                """
                <<<LINEFORM_OPTION_\(index)>>>
                Replacement option \(index)
                <<<END_LINEFORM_OPTION_\(index)>>>
                """
            }
            .joined(separator: "\n")
    }

    static func parse(_ response: String, expectedCount: Int) -> [String] {
        (1...expectedCount).compactMap { index in
            taggedOption(index, in: response)
        }
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
        return option.isEmpty ? nil : option
    }
}
