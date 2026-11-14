import Foundation

/// The AI actions a writer can choose on a selection. The raw values are the `action` field sent
/// to the model (never persisted, never localized); `title` is the chrome text.
///
/// The Rewrite ▸ menu (2026-11-14): a LENGTH group (Trim, Cut in Half) and a direction group
/// (Rephrase — which replaced the old directionless "Rewrite" — Simplify, More Formal, More
/// Casual). One word gets Another Word instead.
enum AIAction: String, CaseIterable {
    case trim
    case cutInHalf
    case rephrase
    case simplify
    case moreFormal
    case moreCasual
    case proofread
    /// Offered instead of the Rewrite submenu when the selection is one word.
    case anotherWord
    case markWeakest = "weakestSentences"
    case markLong = "longSentences"

    var title: String {
        switch self {
        case .trim: return String(localized: "Trim")
        case .cutInHalf: return String(localized: "Cut in Half")
        case .rephrase: return String(localized: "Rephrase")
        case .simplify: return String(localized: "Simplify")
        case .moreFormal: return String(localized: "More Formal")
        case .moreCasual: return String(localized: "More Casual")
        case .proofread: return String(localized: "Proofread")
        case .anotherWord: return String(localized: "Another Word")
        case .markWeakest: return String(localized: "Weakest Sentences")
        case .markLong: return String(localized: "Long Sentences")
        }
    }

    /// The Rewrite ▸ submenu, in its two groups (a separator between them).
    static let rewriteMenuGroups: [[AIAction]] = [[.trim, .cutInHalf], [.rephrase, .simplify, .moreFormal, .moreCasual]]

    /// Find actions (the menu's "Find ▸"; `isMark` and the case names predate the rename)
    /// highlight sentences and change nothing.
    var isMark: Bool {
        switch self {
        case .markWeakest, .markLong: return true
        default: return false
        }
    }

    /// Actions whose whole point is a different text. A reply identical to the selection is a
    /// failed answer for them ("returned the same text"), never "No changes suggested" — which
    /// stays for Proofread, where finding no errors is a legitimate answer.
    var mustChangeText: Bool {
        switch self {
        case .trim, .cutInHalf, .rephrase, .simplify, .moreFormal, .moreCasual, .anotherWord: return true
        case .proofread, .markWeakest, .markLong: return false
        }
    }

    /// Proofread reviews one suggestion per correction; every other edit action is one decision.
    var reviewsPerCorrection: Bool { self == .proofread }

    var progressVerb: String {
        switch self {
        case .trim: return String(localized: "Trimming…")
        case .cutInHalf: return String(localized: "Cutting…")
        case .rephrase: return String(localized: "Rephrasing…")
        case .simplify: return String(localized: "Simplifying…")
        case .moreFormal: return String(localized: "Making it more formal…")
        case .moreCasual: return String(localized: "Making it more casual…")
        case .proofread: return String(localized: "Proofreading…")
        case .anotherWord: return String(localized: "Finding another word…")
        case .markWeakest, .markLong: return String(localized: "Finding sentences…")
        }
    }
}
