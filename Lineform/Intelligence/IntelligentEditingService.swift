import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

protocol IntelligentEditingServicing {
    func replacement(for action: IntelligentEditingAction, selectedText: String, documentContext: String) async throws -> String
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
        let availability = availabilityService.currentStatus()
        guard availability.isAvailable else {
            throw IntelligentEditingError.unavailable(availability.message)
        }

        let prompt = promptBuilder.prompt(for: action, selectedText: selectedText, documentContext: documentContext)

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
            let session = LanguageModelSession(
                model: model,
                instructions: "You are an editor for a native Markdown writing app. Return concise replacement Markdown only."
            )
            let response = try await session.respond(to: prompt)
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
