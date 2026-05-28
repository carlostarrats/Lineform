import Foundation

struct IntelligentEditingSuggestion: Identifiable, Equatable {
    let id = UUID()
    let request: IntelligentEditingRequest
    let selectedRange: NSRange
    let originalText: String
    let replacementText: String
    let diff: MarkdownDiff

    init(
        action: IntelligentEditingAction,
        selectedRange: NSRange,
        originalText: String,
        replacementText: String,
        diff: MarkdownDiff
    ) {
        self.init(
            request: .action(action),
            selectedRange: selectedRange,
            originalText: originalText,
            replacementText: replacementText,
            diff: diff
        )
    }

    init(
        request: IntelligentEditingRequest,
        selectedRange: NSRange,
        originalText: String,
        replacementText: String,
        diff: MarkdownDiff
    ) {
        self.request = request
        self.selectedRange = selectedRange
        self.originalText = originalText
        self.replacementText = replacementText
        self.diff = diff
    }

    var action: IntelligentEditingAction {
        request.evaluationAction
    }

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
