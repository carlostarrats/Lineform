import Foundation

enum IntelligentEditingAction: String, CaseIterable, Identifiable {
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

    var title: String {
        switch self {
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
        String(IntelligentEditingAction.allCases.firstIndex(of: self)! + 1)
    }
}
