import Foundation

struct IntelligentEditingSuggestion: Identifiable, Equatable {
    let id = UUID()
    let action: IntelligentEditingAction
    let selectedRange: NSRange
    let originalText: String
    let replacementText: String
    let diff: MarkdownDiff

    func accept(in documentText: String) -> String {
        guard let range = Range(selectedRange, in: documentText) else {
            return documentText
        }

        var updatedText = documentText
        updatedText.replaceSubrange(range, with: replacementText)
        return updatedText
    }
}
