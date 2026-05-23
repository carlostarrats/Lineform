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
        - return only the replacement text.
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
}
