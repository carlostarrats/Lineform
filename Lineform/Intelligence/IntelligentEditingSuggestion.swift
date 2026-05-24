import Foundation

struct IntelligentEditingSuggestion: Identifiable, Equatable {
    let id = UUID()
    let action: IntelligentEditingAction
    let selectedRange: NSRange
    let originalText: String
    let replacementText: String
    let diff: MarkdownDiff

    func canApply(to documentText: String) -> Bool {
        guard let range = Range(selectedRange, in: documentText) else {
            return false
        }

        return String(documentText[range]) == originalText
    }

    func accept(in documentText: String) -> String? {
        guard canApply(to: documentText), let range = Range(selectedRange, in: documentText) else {
            return nil
        }

        var updatedText = documentText
        updatedText.replaceSubrange(range, with: replacementText)
        return updatedText
    }
}
