import Foundation

enum IntelligentEditingAction: String, CaseIterable, Identifiable {
    case proofread
    case rewrite
    case summarize
    case shorten
    case cleanMarkdown

    var id: String {
        rawValue
    }

    static let menuBarActions: [IntelligentEditingAction] = [
        .proofread,
        .rewrite,
        .summarize,
        .shorten,
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
            return [.cleanMarkdown, .proofread, .rewrite]
        }

        if wordCount >= 100 {
            return [.shorten, .summarize, .proofread]
        }

        return [.rewrite, .proofread, .shorten]
    }

    var title: String {
        switch self {
        case .proofread:
            return "Proofread"
        case .rewrite:
            return "Rewrite"
        case .summarize:
            return "Summarize"
        case .shorten:
            return "Make Shorter"
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
        case .shorten:
            return "Make the selection shorter while keeping the essential meaning."
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

enum IntelligentEditingPresentationPolicy {
    static let maximumOptionCount = 3
    static let multiOptionWordLimit = 100

    static func optionCount(for selectedText: String) -> Int {
        let count = wordCount(in: selectedText)
        guard count > 3 else {
            return 1
        }

        return count < multiOptionWordLimit ? maximumOptionCount : 1
    }

    static func optionCount(for action: IntelligentEditingAction, selectedText: String) -> Int {
        switch action {
        case .rewrite:
            return optionCount(for: selectedText)
        case .proofread, .summarize, .shorten, .cleanMarkdown:
            return 1
        }
    }

    private static func wordCount(in text: String) -> Int {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split { $0.isWhitespace || $0.isNewline }
            .count
    }
}
