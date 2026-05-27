import Foundation

struct IntelligentEditingPromptBuilder {
    func prompt(for action: IntelligentEditingAction, selectedText: String, documentContext: String) -> String {
        """
        Action: \(action.title)

        Rewrite the selected Markdown only.
        \(action.instruction)

        Rules:
        - preserve Markdown whenever possible.
        - Keep links, headings, lists, and emphasis intact.
        - Do not invent facts or add new claims.
        - Replace exactly the selected Markdown, not nearby context.
        - Do not include text from nearby document context in the replacement.
        - return only the replacement text.
        \(shortSelectionRule(for: selectedText))
        \(cleanMarkdownRule(for: action))

        Selected Markdown:
        \(selectedText)

        Nearby document context:
        \(documentContext)
        """
    }

    private func cleanMarkdownRule(for action: IntelligentEditingAction) -> String {
        action == .cleanMarkdown ? "- Do not rewrite fenced code blocks or front matter." : "- Do not rewrite fenced code blocks unless the selection is only prose inside them."
    }

    private func shortSelectionRule(for selectedText: String) -> String {
        let wordCount = Self.wordCount(in: selectedText)
        guard wordCount <= 3 else {
            return "- Keep the replacement proportional to the selected text."
        }

        return "- The selection is very short. Return only a short word or phrase replacement, with no paragraph, list, heading, or newline."
    }

    private static func wordCount(in text: String) -> Int {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split { $0.isWhitespace || $0.isNewline }
            .count
    }
}
