import Foundation

struct IntelligentEditingRunner {
    static let documentContextRadius = 240

    let service: IntelligentEditingServicing

    func run(action: IntelligentEditingAction, documentText: String, selectedRange: NSRange) async throws -> IntelligentEditingSuggestion {
        guard selectedRange.length > 0, let range = Range(selectedRange, in: documentText) else {
            throw IntelligentEditingError.emptySelection
        }

        let selectedText = String(documentText[range])
        let replacement = try await service.replacement(
            for: action,
            selectedText: selectedText,
            documentContext: documentContext(for: selectedRange, in: documentText)
        )

        return IntelligentEditingSuggestion(
            action: action,
            selectedRange: selectedRange,
            originalText: selectedText,
            replacementText: replacement,
            diff: MarkdownDiff.make(original: selectedText, replacement: replacement)
        )
    }

    func runOptions(action: IntelligentEditingAction, documentText: String, selectedRange: NSRange, optionCount: Int) async throws -> [IntelligentEditingSuggestion] {
        guard selectedRange.length > 0, let range = Range(selectedRange, in: documentText) else {
            throw IntelligentEditingError.emptySelection
        }

        let selectedText = String(documentText[range])
        let cappedOptionCount = min(max(optionCount, 1), IntelligentEditingPresentationPolicy.maximumOptionCount)
        let replacements = try await service.replacements(
            for: action,
            selectedText: selectedText,
            documentContext: documentContext(for: selectedRange, in: documentText),
            count: cappedOptionCount
        )

        let suggestions = replacements
            .prefix(cappedOptionCount)
            .map { replacement in
                IntelligentEditingSuggestion(
                    action: action,
                    selectedRange: selectedRange,
                    originalText: selectedText,
                    replacementText: replacement,
                    diff: MarkdownDiff.make(original: selectedText, replacement: replacement)
                )
            }

        guard !suggestions.isEmpty else {
            throw IntelligentEditingError.emptyResponse
        }

        return suggestions
    }

    private func documentContext(for selectedRange: NSRange, in documentText: String) -> String {
        let nsText = documentText as NSString
        let location = max(0, selectedRange.location - Self.documentContextRadius)
        let upperBound = min(nsText.length, selectedRange.location + selectedRange.length + Self.documentContextRadius)
        return nsText.substring(with: NSRange(location: location, length: upperBound - location))
    }
}
