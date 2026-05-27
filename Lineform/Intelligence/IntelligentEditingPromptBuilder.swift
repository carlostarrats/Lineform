import Foundation

struct IntelligentEditingPromptBuilder {
    func prompt(
        for action: IntelligentEditingAction,
        selectedText: String,
        documentContext: String,
        additionalRequirements: String = ""
    ) -> String {
        if action == .proofread && Self.wordCount(in: selectedText) <= 3 {
            return shortProofreadPrompt(
                selectedText: selectedText,
                documentContext: documentContext,
                additionalRequirements: additionalRequirements
            )
        }

        if action == .rewrite && Self.wordCount(in: selectedText) <= 3 {
            return shortRewritePrompt(
                selectedText: selectedText,
                documentContext: documentContext,
                additionalRequirements: additionalRequirements
            )
        }

        return """
        Task:
        Action: \(action.title)
        \(action.successCriteria)

        Rewrite the selected Markdown only.
        \(action.instruction)

        Output contract:
        - return only the replacement text.
        - Replace exactly the selected Markdown, not nearby context.
        - preserve Markdown whenever possible.
        - Keep links, headings, lists, and emphasis intact.
        - Do not invent facts or add new claims.
        - Do not include text from nearby document context in the replacement.
        - Use nearby context only to understand tone and boundaries. Facts that appear only in nearby context are forbidden in the replacement.

        Invalid outputs:
        - Do not return placeholder text, dummy text, TODO, or Lorem ipsum.
        \(unchangedOutputRule(for: action))
        - Do not copy nearby context into the replacement.
        - Do not include internal control markers, delimiters, option labels, or numbering.
        - Do not wrap the replacement in Markdown code fences unless the selected Markdown is itself only a fenced code block.
        - Do not explain the edit or wrap the replacement in quotes unless the replacement itself needs quotes.

        Quality bar:
        - The replacement must be useful enough to show directly in a writing app.
        - Preserve the selected meaning unless the action is Summarize or Make Shorter.
        - Keep the replacement proportional to the selected Markdown.
        \(action.extraQualityRule)
        \(shortSelectionRule(for: selectedText, action: action))
        \(cleanMarkdownRule(for: action))
        \(proofreadRule(for: action))
        \(additionalRequirementsSection(additionalRequirements))

        Selected Markdown:
        \(selectedText)

        Nearby document context (not selected; do not copy from this section):
        \(documentContext)
        """
    }

    func optionPrompt(
        for action: IntelligentEditingAction,
        selectedText: String,
        documentContext: String,
        optionNumber: Int,
        optionCount: Int,
        priorOptions: [String],
        rejectedDuplicate: String?
    ) -> String {
        let priorOptionsText = priorOptions.isEmpty
            ? "- No accepted prior options yet."
            : priorOptions.enumerated()
                .map { index, option in "- Option \(index + 1): \(Self.preview(option))" }
                .joined(separator: "\n")
        let duplicateText = rejectedDuplicate.map { "\nThe previous attempt repeated an existing option and was rejected: \(Self.preview($0))" } ?? ""

        return prompt(
            for: action,
            selectedText: selectedText,
            documentContext: documentContext,
            additionalRequirements: """
            Option requirements:
            - Return exactly one replacement for option \(optionNumber) of \(optionCount).
            - Do not include option labels, numbering, tags, explanations, or commentary.
            - Do not include internal control markers or any other delimiter text.
            - Make this option meaningfully different from accepted prior options.

            Accepted prior options:
            \(priorOptionsText)\(duplicateText)
            """
        )
    }

    private func shortProofreadPrompt(selectedText: String, documentContext: String, additionalRequirements: String) -> String {
        """
        Task:
        Action: Proofread
        Successful Proofread: fix spelling, grammar, punctuation, or typo errors in the selected word or short phrase only.

        Output contract:
        - return only the corrected replacement text.
        - Return 1-4 words only.
        - Replace exactly the selected Markdown, not nearby context.
        - Do not return a sentence, paragraph, list, heading, or newline.

        Invalid outputs:
        - Do not return placeholder text, dummy text, TODO, or Lorem ipsum.
        - Do not explain the edit or wrap the replacement in quotes.
        - Do not say there was a typo; return the corrected token itself.
        - Do not include internal control markers, delimiters, option labels, or numbering.
        - Do not drop Markdown markers from the selection.

        Quality bar:
        - If the selected text has an error, correct it.
        - If the selected text has no error, return it unchanged.
        - Selection length: one word or short phrase.
        \(additionalRequirementsSection(additionalRequirements))

        Selected Markdown:
        \(selectedText)

        Nearby document context (not selected; do not copy from this section):
        \(documentContext)
        """
    }

    private func shortRewritePrompt(selectedText: String, documentContext: String, additionalRequirements: String) -> String {
        """
        Task:
        Action: Rewrite
        Successful Rewrite: replace the selected word or short phrase with a clearer synonym or label.

        Output contract:
        - return only the replacement text.
        - Return 1-4 words only.
        - Replace exactly the selected Markdown, not nearby context.
        - Do not return a sentence, paragraph, list, heading, or newline.

        Invalid outputs:
        - Do not return placeholder text, dummy text, TODO, or Lorem ipsum.
        - Do not return the selected Markdown unchanged.
        - Do not explain the edit or wrap the replacement in quotes.
        - Do not include internal control markers, delimiters, option labels, or numbering.
        - Do not copy nearby list items, headings, or surrounding document text.

        Quality bar:
        - Choose a useful replacement a writer could insert directly.
        - If the selected word is vague, make it more specific.
        - If there is no nearby context, choose a clearer general-purpose word.
        - Selection length: one word or short phrase.
        - Acceptable examples: "Features" -> "Highlights"; "Overview" -> "Summary"; "better writing" -> "clearer prose".
        - Unacceptable: returning a list, heading, sentence, paragraph, or words copied from nearby context.
        \(additionalRequirementsSection(additionalRequirements))

        Selected Markdown:
        \(selectedText)

        Nearby document context (not selected; do not copy from this section):
        \(documentContext)
        """
    }

    func repairPrompt(
        for action: IntelligentEditingAction,
        selectedText: String,
        documentContext: String,
        rejectedReplacement: String,
        failures: [IntelligentEditingEvaluationFailure]
    ) -> String {
        """
        Action: \(action.title)
        \(action.successCriteria)
        \(action.instruction)

        Return only replacement Markdown for the selected text. Do not explain.
        Do not return placeholder text, dummy text, TODO, Lorem ipsum, or copied nearby context.
        Do not include internal control markers, delimiters, option labels, or numbering.
        Do not wrap the replacement in code fences unless the selected Markdown is itself only a fenced code block.
        Replace exactly the selected Markdown, not the nearby context.
        \(action.extraQualityRule)
        \(shortSelectionRule(for: selectedText, action: action))
        \(cleanMarkdownRule(for: action))
        \(proofreadRule(for: action))

        Previous answer was rejected:
        \(Self.preview(rejectedReplacement))

        Rejection reasons:
        \(failureInstructions(for: failures))

        Selected Markdown:
        \(selectedText)

        Nearby document context, for tone only:
        \(documentContext)

        Return a new replacement now. It must satisfy the action and the output contract.
        """
    }

    private func failureInstructions(for failures: [IntelligentEditingEvaluationFailure]) -> String {
        failures.map { failure in
            switch failure {
            case .emptyReplacement:
                return "- It was empty. Return replacement Markdown."
            case .placeholderOrDummyText:
                return "- It contained placeholder or dummy text. Return real edited user-facing Markdown."
            case .unchangedTransformOutput:
                return "- It repeated the selected Markdown unchanged. Change wording, structure, or length enough to complete the action."
            case .oversizedShortSelection:
                return "- It was too long for the selection. Keep one-word and short-phrase replacements to 1-4 words."
            case .leakedNearbyContext:
                return "- It copied nearby context. Use only the selected Markdown as replaceable source material."
            case .markdownStructureNotPreserved:
                return "- It dropped required Markdown structure. Preserve required headings, lists, links, emphasis, and fenced code."
            case .missingCompression:
                return "- It was not compressed enough. Return at least 25% fewer words than the selected Markdown."
            case .proofreadChangedMeaningOrStyle:
                return "- It rewrote style or meaning during Proofread. Fix only grammar, spelling, punctuation, or obvious typos."
            case .cleanMarkdownChangedContent:
                return "- It changed content during Clean Markdown. Preserve the exact words and code while fixing Markdown formatting."
            }
        }
        .joined(separator: "\n")
    }

    private static func preview(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 240 else {
            return trimmed
        }

        return "\(trimmed.prefix(240))..."
    }

    private func additionalRequirementsSection(_ requirements: String) -> String {
        let trimmed = requirements.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ""
        }

        return "\n\(trimmed)"
    }

    private func unchangedOutputRule(for action: IntelligentEditingAction) -> String {
        switch action {
        case .rewrite, .summarize, .shorten:
            return "- Do not return the selected Markdown unchanged."
        case .proofread, .cleanMarkdown:
            return "- Return the selected Markdown unchanged only if it already satisfies the action."
        }
    }

    private func cleanMarkdownRule(for action: IntelligentEditingAction) -> String {
        action == .cleanMarkdown ? "- Do not rewrite prose, facts, fenced code blocks, inline code, links, or front matter content. Change Markdown formatting only." : "- Do not rewrite fenced code blocks unless the selection is only prose inside them."
    }

    private func proofreadRule(for action: IntelligentEditingAction) -> String {
        action == .proofread ? "- For Proofread, do not improve style, tone, structure, or word choice unless required to fix an actual error. If the selection is a Markdown list, return a Markdown list with the same number of items and the same list markers." : ""
    }

    private func shortSelectionRule(for selectedText: String, action: IntelligentEditingAction) -> String {
        let wordCount = Self.wordCount(in: selectedText)
        guard wordCount <= 3 else {
            return "- Selection length: sentence, paragraph, or multiple paragraphs. Keep the replacement proportional to the selected text."
        }

        let rewriteRule = action == .rewrite ? " For Rewrite, choose a clearer synonym or label instead of repeating the same word." : ""
        return "- Selection length: one word or short phrase. Return 1-4 words only. Return a replacement label or phrase. Do not return a sentence, paragraph, list, heading, or newline.\(rewriteRule)"
    }

    private static func wordCount(in text: String) -> Int {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split { $0.isWhitespace || $0.isNewline }
            .count
    }
}

private extension IntelligentEditingAction {
    var successCriteria: String {
        switch self {
        case .proofread:
            return "Successful Proofread: fix only grammar, spelling, punctuation, and obvious typos while preserving wording and Markdown structure."
        case .rewrite:
            return "Successful Rewrite: improve flow and clarity while preserving the selected meaning, tone, and facts."
        case .summarize:
            return "Successful Summary: compress the selected Markdown to its essential points without adding claims."
        case .shorten:
            return "Successful Shortening: reduce length while keeping the core meaning and useful specifics."
        case .cleanMarkdown:
            return "Successful Markdown Cleanup: normalize formatting while preserving content, links, headings, lists, emphasis, fenced code, and front matter."
        }
    }

    var extraQualityRule: String {
        switch self {
        case .proofread:
            return "- For Proofread, change only errors. Do not rewrite style. Preserve every Markdown marker, list item, heading, link, and code span exactly unless the marker itself is malformed."
        case .rewrite:
            return "- For Rewrite, change wording enough that the result is not the same sentence with minor punctuation. If a clear improvement is possible, make one; do not give up by returning the selection unchanged."
        case .summarize:
            return "- For Summarize, produce at least 25% fewer words than the selection."
        case .shorten:
            return "- For Make Shorter, produce at least 25% fewer words than the selection."
        case .cleanMarkdown:
            return "- For Clean Markdown, fix Markdown spacing, list marker spacing, blank lines, heading spacing, and obvious formatting inconsistencies. Preserve the original order of headings, paragraphs, lists, front matter, and fenced code. Do not leave messy Markdown unchanged when spacing or structure can be cleaned."
        }
    }
}
