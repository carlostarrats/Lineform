import Foundation

struct IntelligentEditingRunner {
    static let documentContextRadius = 240

    let service: IntelligentEditingServicing

    func run(action: IntelligentEditingAction, documentText: String, selectedRange: NSRange) async throws -> IntelligentEditingSuggestion {
        guard selectedRange.length > 0, let range = Range(selectedRange, in: documentText) else {
            throw IntelligentEditingError.emptySelection
        }

        let selectedText = String(documentText[range])
        let rawReplacement = try await service.replacement(
            for: action,
            selectedText: selectedText,
            documentContext: documentContext(for: selectedRange, selectedText: selectedText, in: documentText)
        )
        let replacement = try Self.validatedReplacement(rawReplacement, for: selectedText)

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
        let rawReplacements = try await service.replacements(
            for: action,
            selectedText: selectedText,
            documentContext: documentContext(for: selectedRange, selectedText: selectedText, in: documentText),
            count: cappedOptionCount
        )
        let replacements = rawReplacements.compactMap { rawReplacement in
            try? Self.validatedReplacement(rawReplacement, for: selectedText)
        }

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

    private func documentContext(for selectedRange: NSRange, selectedText: String, in documentText: String) -> String {
        guard !Self.isShortSelection(selectedText) else {
            return ""
        }

        let nsText = documentText as NSString
        let location = max(0, selectedRange.location - Self.documentContextRadius)
        let upperBound = min(nsText.length, selectedRange.location + selectedRange.length + Self.documentContextRadius)
        return nsText.substring(with: NSRange(location: location, length: upperBound - location))
    }

    private static func validatedReplacement(_ replacement: String, for selectedText: String) throws -> String {
        let trimmedReplacement = normalizedReplacement(replacement, for: selectedText)
        guard !trimmedReplacement.isEmpty else {
            throw IntelligentEditingError.emptyResponse
        }

        guard !isPlaceholderReplacement(trimmedReplacement) else {
            throw IntelligentEditingError.emptyResponse
        }

        guard replacementIsInScope(trimmedReplacement, for: selectedText) else {
            throw IntelligentEditingError.emptyResponse
        }

        return trimmedReplacement
    }

    private static func replacementIsInScope(_ replacement: String, for selectedText: String) -> Bool {
        guard isShortSelection(selectedText) else {
            return true
        }

        let selectedWordCount = wordCount(in: selectedText)
        let replacementWordCount = wordCount(in: replacement)
        let maximumReplacementWords = max(8, selectedWordCount * 4)

        guard replacementWordCount <= maximumReplacementWords else {
            return false
        }

        if replacement.contains("\n") {
            return false
        }

        let trimmedReplacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedReplacement.hasPrefix("- ") || trimmedReplacement.hasPrefix("* ") || trimmedReplacement.hasPrefix("#") {
            return false
        }

        return true
    }

    private static func isShortSelection(_ text: String) -> Bool {
        wordCount(in: text) <= 3 && !text.trimmingCharacters(in: .whitespacesAndNewlines).contains("\n")
    }

    private static func isPlaceholderReplacement(_ replacement: String) -> Bool {
        let normalized = replacement
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return normalized.hasPrefix("replacement option")
            || normalized.hasPrefix("<write only replacement")
            || normalized.hasPrefix("option ")
    }

    private static func normalizedReplacement(_ replacement: String, for selectedText: String) -> String {
        let trimmedReplacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isShortSelection(selectedText), let quotedReplacement = quotedReplacement(in: trimmedReplacement) else {
            return trimmedReplacement
        }

        return quotedReplacement
    }

    private static func quotedReplacement(in text: String) -> String? {
        let quotePairs: [(Character, Character)] = [
            ("\"", "\""),
            ("'", "'"),
            ("\u{201C}", "\u{201D}"),
            ("\u{2018}", "\u{2019}")
        ]

        for (openingQuote, closingQuote) in quotePairs {
            guard
                let openingIndex = text.firstIndex(of: openingQuote),
                let closingIndex = text[text.index(after: openingIndex)...].firstIndex(of: closingQuote)
            else {
                continue
            }

            let quoted = text[text.index(after: openingIndex)..<closingIndex]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !quoted.isEmpty {
                return quoted
            }
        }

        return nil
    }

    private static func wordCount(in text: String) -> Int {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split { $0.isWhitespace || $0.isNewline }
            .count
    }
}
