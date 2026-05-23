import Foundation

struct IntelligentEditingRunner {
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

    private func documentContext(for selectedRange: NSRange, in documentText: String) -> String {
        let nsText = documentText as NSString
        let contextRadius = 600
        let location = max(0, selectedRange.location - contextRadius)
        let upperBound = min(nsText.length, selectedRange.location + selectedRange.length + contextRadius)
        return nsText.substring(with: NSRange(location: location, length: upperBound - location))
    }
}
