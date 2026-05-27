import Foundation

enum IntelligentEditingAction: String, CaseIterable, Identifiable {
    case proofread
    case rewrite
    case summarize
    case improveReadability
    case makeClearer
    case simplify
    case shorten
    case fixGrammar
    case makeScannable
    case turnIntoBullets
    case cleanMarkdown

    var id: String {
        rawValue
    }

    static let menuBarActions: [IntelligentEditingAction] = [
        .proofread,
        .rewrite,
        .summarize,
        .improveReadability,
        .makeClearer,
        .simplify,
        .shorten,
        .makeScannable,
        .turnIntoBullets,
        .cleanMarkdown
    ]

    static let rightClickActions: [IntelligentEditingAction] = [
        .cleanMarkdown
    ]

    static func contextualActions(for selectedText: String) -> [IntelligentEditingAction] {
        let normalizedText = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let wordCount = normalizedText
            .split { $0.isWhitespace || $0.isNewline }
            .count

        if isMarkdownHeavy(normalizedText) {
            return [.cleanMarkdown, .makeScannable, .proofread, .rewrite, .shorten]
        }

        if wordCount >= 80 {
            return [.summarize, .shorten, .makeScannable, .rewrite, .proofread]
        }

        if normalizedText.contains("\n") || normalizedText.contains(";") {
            return [.makeScannable, .makeClearer, .shorten, .proofread, .cleanMarkdown]
        }

        return [.rewrite, .makeClearer, .proofread, .shorten, .improveReadability]
    }

    var title: String {
        switch self {
        case .proofread:
            return "Proofread"
        case .rewrite:
            return "Rewrite"
        case .summarize:
            return "Summarize"
        case .improveReadability:
            return "Improve Readability"
        case .makeClearer:
            return "Make Clearer"
        case .simplify:
            return "Simplify"
        case .shorten:
            return "Shorten"
        case .fixGrammar:
            return "Fix Grammar"
        case .makeScannable:
            return "Make Scannable"
        case .turnIntoBullets:
            return "Turn into Bullets"
        case .cleanMarkdown:
            return "Clean Markdown"
        }
    }

    var instruction: String {
        switch self {
        case .proofread:
            return "Fix grammar, spelling, punctuation, and obvious typos only."
        case .rewrite:
            return "Rewrite the selected text with better flow while preserving the meaning and tone."
        case .summarize:
            return "Summarize the selected text concisely while preserving the essential points."
        case .improveReadability:
            return "Improve flow, sentence rhythm, and readability without changing the meaning."
        case .makeClearer:
            return "Make the writing clearer and more direct without adding new ideas."
        case .simplify:
            return "Use simpler language while preserving the author's intent."
        case .shorten:
            return "Make the selection shorter while keeping the essential meaning."
        case .fixGrammar:
            return "Fix grammar, spelling, punctuation, and obvious wording issues only."
        case .makeScannable:
            return "Make the selection easier to scan with concise structure and spacing."
        case .turnIntoBullets:
            return "Convert the selection into clear Markdown bullet points."
        case .cleanMarkdown:
            return "Clean Markdown formatting while preserving content and structure."
        }
    }

    var keyEquivalent: String {
        let keyEquivalents = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-"]
        return keyEquivalents[IntelligentEditingAction.allCases.firstIndex(of: self)!]
    }

    private static func isMarkdownHeavy(_ text: String) -> Bool {
        let markdownMarkers = [
            "# ",
            "## ",
            "- ",
            "* ",
            "> ",
            "```",
            "[",
            "](",
            "`"
        ]

        let markerCount = markdownMarkers.reduce(0) { count, marker in
            text.contains(marker) ? count + 1 : count
        }

        return markerCount >= 2 || text.hasPrefix("#") || text.hasPrefix("- ")
    }
}
