import Foundation

enum IntelligentEditingProofreadChangeReview {
    struct PartialAcceptance: Equatable {
        let documentText: String
        let remainingSuggestion: IntelligentEditingSuggestion?
    }

    struct Item: Equatable, Identifiable {
        let index: Int
        let change: MarkdownDiff.Change
        let originalText: String
        let replacementText: String

        var id: Int {
            index
        }

        var previewText: String {
            "\(originalText) -> \(replacementText)"
        }
    }

    static func items(for suggestion: IntelligentEditingSuggestion) -> [Item] {
        guard suggestion.action == .proofread else {
            return []
        }

        return suggestion.diff.changes.enumerated().map { index, change in
            let segment = changedSegment(
                originalLine: change.originalLine,
                replacementLine: change.replacementLine
            )
            return Item(
                index: index,
                change: change,
                originalText: segment.original,
                replacementText: segment.replacement
            )
        }
    }

    static func previewText(for suggestion: IntelligentEditingSuggestion, changeIndex: Int) -> String {
        let reviewItems = items(for: suggestion)
        guard !reviewItems.isEmpty else {
            return suggestion.replacementText.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return reviewItems[clamped(changeIndex, count: reviewItems.count)].previewText
    }

    static func acceptChange(
        in documentText: String,
        suggestion: IntelligentEditingSuggestion,
        changeIndex: Int
    ) -> PartialAcceptance? {
        guard suggestion.action == .proofread, suggestion.canApply(to: documentText) else {
            return nil
        }

        let reviewItems = items(for: suggestion)
        guard !reviewItems.isEmpty else {
            return nil
        }

        let item = reviewItems[clamped(changeIndex, count: reviewItems.count)]
        var selectedLines = suggestion.originalText.components(separatedBy: .newlines)
        let lineIndex = item.change.lineNumber - 1
        guard selectedLines.indices.contains(lineIndex) else {
            return nil
        }

        selectedLines[lineIndex] = item.change.replacementLine
        let updatedSelectionText = selectedLines.joined(separator: "\n")

        guard let selectedRange = Range(suggestion.selectedRange, in: documentText) else {
            return nil
        }

        var updatedDocumentText = documentText
        updatedDocumentText.replaceSubrange(selectedRange, with: updatedSelectionText)

        let remainingDiff = MarkdownDiff.make(
            original: updatedSelectionText,
            replacement: suggestion.replacementText
        )
        guard !remainingDiff.changes.isEmpty else {
            return PartialAcceptance(documentText: updatedDocumentText, remainingSuggestion: nil)
        }

        let remainingSuggestion = IntelligentEditingSuggestion(
            request: suggestion.request,
            selectedRange: NSRange(location: suggestion.selectedRange.location, length: (updatedSelectionText as NSString).length),
            originalText: updatedSelectionText,
            replacementText: suggestion.replacementText,
            diff: remainingDiff
        )
        return PartialAcceptance(documentText: updatedDocumentText, remainingSuggestion: remainingSuggestion)
    }

    private static func changedSegment(originalLine: String, replacementLine: String) -> (original: String, replacement: String) {
        let trimmedOriginalLine = originalLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedReplacementLine = replacementLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let originalCharacters = Array(originalLine)
        let replacementCharacters = Array(replacementLine)

        var prefixCount = 0
        while
            prefixCount < originalCharacters.count,
            prefixCount < replacementCharacters.count,
            originalCharacters[prefixCount] == replacementCharacters[prefixCount]
        {
            prefixCount += 1
        }

        var suffixCount = 0
        while
            suffixCount < originalCharacters.count - prefixCount,
            suffixCount < replacementCharacters.count - prefixCount,
            originalCharacters[originalCharacters.count - 1 - suffixCount] == replacementCharacters[replacementCharacters.count - 1 - suffixCount]
        {
            suffixCount += 1
        }

        let originalChanged = String(originalCharacters[prefixCount..<(originalCharacters.count - suffixCount)])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let replacementChanged = String(replacementCharacters[prefixCount..<(replacementCharacters.count - suffixCount)])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if shouldShowWholeLine(
            originalLine: trimmedOriginalLine,
            originalChanged: originalChanged,
            replacementChanged: replacementChanged
        ) {
            return (trimmedOriginalLine, trimmedReplacementLine)
        }

        let originalWord = expandedChangedWord(
            in: originalLine,
            changedStart: prefixCount,
            changedEnd: originalCharacters.count - suffixCount
        )
        let replacementWord = expandedChangedWord(
            in: replacementLine,
            changedStart: prefixCount,
            changedEnd: replacementCharacters.count - suffixCount
        )

        return (
            originalWord.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? trimmedOriginalLine,
            replacementWord.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? trimmedReplacementLine
        )
    }

    private static func shouldShowWholeLine(
        originalLine: String,
        originalChanged: String,
        replacementChanged: String
    ) -> Bool {
        if wordCount(in: originalLine) <= 8 {
            return true
        }

        let grammarTokens: Set<String> = [
            "a", "an", "are", "at", "by", "for", "from", "has", "have", "in",
            "is", "of", "on", "the", "to", "was", "were"
        ]
        let originalToken = normalizedWord(originalChanged)
        let replacementToken = normalizedWord(replacementChanged)

        return grammarTokens.contains(originalToken) || grammarTokens.contains(replacementToken)
    }

    private static func expandedChangedWord(in text: String, changedStart: Int, changedEnd: Int) -> String {
        let characters = Array(text)
        guard !characters.isEmpty else {
            return ""
        }

        var lowerBound = min(max(changedStart, 0), characters.count)
        var upperBound = min(max(changedEnd, lowerBound), characters.count)

        while lowerBound > 0, isWordLike(characters[lowerBound - 1]) {
            lowerBound -= 1
        }

        while upperBound < characters.count, isWordLike(characters[upperBound]) {
            upperBound += 1
        }

        return String(characters[lowerBound..<upperBound])
    }

    private static func isWordLike(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "'" || character == "-"
    }

    private static func wordCount(in text: String) -> Int {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split { $0.isWhitespace || $0.isNewline }
            .count
    }

    private static func normalizedWord(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            .lowercased()
    }

    private static func clamped(_ index: Int, count: Int) -> Int {
        min(max(index, 0), count - 1)
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
