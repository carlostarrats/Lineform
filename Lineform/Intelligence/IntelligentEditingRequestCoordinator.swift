import Foundation

struct IntelligentEditingRequestCoordinator {
    enum Result: Equatable {
        case ready([IntelligentEditingSuggestion], String)
        case expired(String)
        case failed(String)
    }

    let service: any IntelligentEditingServicing

    func run(
        action: IntelligentEditingAction,
        documentText: String,
        currentDocumentText: String,
        selectedRange: NSRange
    ) async -> Result {
        let runner = IntelligentEditingRunner(service: service)

        do {
            let optionCount = IntelligentEditingPresentationPolicy.optionCount(for: action, selectedText: selectedText(in: documentText, selectedRange: selectedRange))
            let suggestions: [IntelligentEditingSuggestion]

            if optionCount > 1 {
                suggestions = try await runner.runOptions(
                    action: action,
                    documentText: documentText,
                    selectedRange: selectedRange,
                    optionCount: optionCount
                )
            } else {
                suggestions = [
                    try await runner.run(
                        action: action,
                        documentText: documentText,
                        selectedRange: selectedRange
                    )
                ]
            }

            let applicableSuggestions = suggestions.filter { $0.canApply(to: currentDocumentText) }
            guard !applicableSuggestions.isEmpty else {
                return .expired("Suggestion expired after edits.")
            }

            return .ready(applicableSuggestions, Self.readyStatus(for: applicableSuggestions.count))
        } catch is CancellationError {
            return .failed("Suggestion canceled.")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "Suggestion unavailable."
            return .failed(message)
        }
    }

    private func selectedText(in documentText: String, selectedRange: NSRange) -> String {
        guard selectedRange.length > 0, let range = Range(selectedRange, in: documentText) else {
            return ""
        }

        return String(documentText[range])
    }

    static func readyStatus(for optionCount: Int) -> String {
        optionCount == 1 ? "1 option ready." : "\(optionCount) options ready."
    }
}
