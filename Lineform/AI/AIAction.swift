import Foundation

/// The AI actions a writer can choose on a selection. The raw values are persisted identity (and
/// the `action` field sent to the model) and are never localized; `title` is the chrome text.
enum AIAction: String, CaseIterable {
    case trim
    case cutInHalf
    case rewrite
    case proofread
    case markWeakest = "weakestSentences"
    case markLong = "longSentences"

    var title: String {
        switch self {
        case .trim: return String(localized: "Trim")
        case .cutInHalf: return String(localized: "Cut in half")
        case .rewrite: return String(localized: "Rewrite")
        case .proofread: return String(localized: "Proofread")
        case .markWeakest: return String(localized: "Weakest sentences")
        case .markLong: return String(localized: "Long sentences")
        }
    }

    /// Mark actions highlight sentences and change nothing.
    var isMark: Bool {
        switch self {
        case .markWeakest, .markLong: return true
        case .trim, .cutInHalf, .rewrite, .proofread: return false
        }
    }

    var progressVerb: String {
        switch self {
        case .trim: return String(localized: "Trimming…")
        case .cutInHalf: return String(localized: "Cutting…")
        case .rewrite: return String(localized: "Rewriting…")
        case .proofread: return String(localized: "Proofreading…")
        case .markWeakest, .markLong: return String(localized: "Marking…")
        }
    }
}
