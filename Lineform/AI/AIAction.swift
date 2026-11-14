import Foundation

/// The AI actions a writer can choose on a selection. The raw values are persisted identity (and
/// the `action` field sent to the model) and are never localized; `title` is the chrome text.
enum AIAction: String, CaseIterable {
    case trim
    case cutInHalf
    case rewrite
    case proofread
    /// Offered instead of the Rewrite submenu when the selection is one word.
    case anotherWord
    case markWeakest = "weakestSentences"
    case markLong = "longSentences"

    var title: String {
        switch self {
        case .trim: return String(localized: "Trim")
        case .cutInHalf: return String(localized: "Cut in half")
        case .rewrite: return String(localized: "Rewrite")
        case .proofread: return String(localized: "Proofread")
        case .anotherWord: return String(localized: "Another Word")
        case .markWeakest: return String(localized: "Weakest Sentences")
        case .markLong: return String(localized: "Long Sentences")
        }
    }

    /// Find actions (the menu's "Find ▸"; `isMark` and the case names predate the rename)
    /// highlight sentences and change nothing.
    var isMark: Bool {
        switch self {
        case .markWeakest, .markLong: return true
        case .trim, .cutInHalf, .rewrite, .proofread, .anotherWord: return false
        }
    }

    /// Actions whose whole point is a different text. A reply identical to the selection is a
    /// failed answer for them ("returned the same text"), never "No changes suggested" — which
    /// stays for Proofread, where finding no errors is a legitimate answer.
    var mustChangeText: Bool {
        switch self {
        case .trim, .cutInHalf, .rewrite, .anotherWord: return true
        case .proofread, .markWeakest, .markLong: return false
        }
    }

    var progressVerb: String {
        switch self {
        case .trim: return String(localized: "Trimming…")
        case .cutInHalf: return String(localized: "Cutting…")
        case .rewrite: return String(localized: "Rewriting…")
        case .proofread: return String(localized: "Proofreading…")
        case .anotherWord: return String(localized: "Finding another word…")
        case .markWeakest, .markLong: return String(localized: "Finding sentences…")
        }
    }
}
