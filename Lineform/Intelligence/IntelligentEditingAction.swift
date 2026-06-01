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

    static let menuBarActions: [IntelligentEditingAction] = []

    static let rightClickActions: [IntelligentEditingAction] = []

    static let actionRailActions: [IntelligentEditingAction] = []

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

    var railDisplayTitle: String {
        switch self {
        case .proofread:
            return "Proofread"
        case .rewrite:
            return "Rewrite"
        case .summarize:
            return "Summarize"
        case .shorten:
            return "Shorten"
        case .cleanMarkdown:
            return "Clean"
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

    var railSystemImage: String {
        switch self {
        case .proofread:
            return "eye"
        case .rewrite:
            return "text.bubble"
        case .summarize:
            return "text.justify.left"
        case .shorten:
            return "arrow.down.right.and.arrow.up.left"
        case .cleanMarkdown:
            return "paintbrush.pointed"
        }
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

struct IntelligentEditingRequest: Equatable {
    enum Kind: Equatable {
        case action(IntelligentEditingAction)
        case custom
    }

    static let maximumInstructionLength = 220

    let kind: Kind
    let userInstruction: String

    static func action(_ action: IntelligentEditingAction) -> IntelligentEditingRequest {
        IntelligentEditingRequest(kind: .action(action), userInstruction: action.instruction)
    }

    static func custom(_ instruction: String) -> IntelligentEditingRequest {
        IntelligentEditingRequest(kind: .custom, userInstruction: sanitizedInstruction(instruction))
    }

    var title: String {
        switch kind {
        case .action(let action):
            return action.title
        case .custom:
            return "Custom Instruction"
        }
    }

    var evaluationAction: IntelligentEditingAction {
        switch kind {
        case .action(let action):
            return action
        case .custom:
            return inferredCustomAction
        }
    }

    var usesUserInstruction: Bool {
        kind == .custom
    }

    var allowsMultipleOptions: Bool {
        guard kind == .custom else {
            return evaluationAction == .rewrite || evaluationAction == .proofread
        }

        let normalizedInstruction = Self.normalized(userInstruction)
        if evaluationAction != .rewrite && evaluationAction != .proofread {
            return false
        }

        return normalizedInstruction.contains("alternative")
            || normalizedInstruction.contains("options")
            || normalizedInstruction.contains("three")
            || normalizedInstruction.contains("3")
            || normalizedInstruction.contains("different")
            || normalizedInstruction.contains("another")
    }

    private var inferredCustomAction: IntelligentEditingAction {
        let normalizedInstruction = Self.normalized(userInstruction)

        if normalizedInstruction.contains("proofread")
            || normalizedInstruction.contains("grammar")
            || normalizedInstruction.contains("spelling")
            || normalizedInstruction.contains("punctuation")
            || normalizedInstruction.contains("typo")
            || normalizedInstruction.contains("fix errors")
            || normalizedInstruction.contains("fix grammar") {
            return .proofread
        }

        if normalizedInstruction.contains("shorten")
            || normalizedInstruction.contains("shorter")
            || normalizedInstruction.contains("concise")
            || normalizedInstruction.contains("condense")
            || normalizedInstruction.contains("cut down") {
            return .shorten
        }

        if normalizedInstruction.contains("summarize")
            || normalizedInstruction.contains("summary")
            || normalizedInstruction.contains("summarise") {
            return .summarize
        }

        if normalizedInstruction.contains("clean markdown")
            || normalizedInstruction.contains("format markdown")
            || normalizedInstruction.contains("markdown formatting") {
            return .cleanMarkdown
        }

        return .rewrite
    }

    private static func sanitizedInstruction(_ instruction: String) -> String {
        let normalizedWhitespace = instruction
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard normalizedWhitespace.count > maximumInstructionLength else {
            return normalizedWhitespace
        }

        return String(normalizedWhitespace.prefix(maximumInstructionLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
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
        case .proofread:
            return hasAmbiguousProofreadTypo(selectedText) ? maximumOptionCount : 1
        case .summarize, .shorten, .cleanMarkdown:
            return 1
        }
    }

    static func optionCount(for request: IntelligentEditingRequest, selectedText: String) -> Int {
        guard request.allowsMultipleOptions else {
            return 1
        }

        switch request.kind {
        case .action(let action):
            return optionCount(for: action, selectedText: selectedText)
        case .custom:
            return optionCount(for: selectedText)
        }
    }

    private static func wordCount(in text: String) -> Int {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split { $0.isWhitespace || $0.isNewline }
            .count
    }

    private static func hasAmbiguousProofreadTypo(_ text: String) -> Bool {
        let normalizedText = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return normalizedText == "can i ds it tommorow?" || normalizedText == "can i ds it tomorrow?"
    }
}
