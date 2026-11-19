import Foundation

/// The AI actions a writer can choose on a selection. The raw values are the `action` field sent
/// to the model (never persisted, never localized); `title` is the chrome text.
///
/// The Rewrite ▸ menu (2026-11-14): a LENGTH group (Trim, Cut in Half) and a direction group
/// (Rephrase — which replaced the old directionless "Rewrite" — Simplify, More Formal, More
/// Casual). One word gets Another Word instead.
public enum AIAction: String, CaseIterable, Sendable {
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
    /// The selection toolbar's comment with no action picked: the writer's note IS the instruction.
    /// Never on the context menu (it has nowhere to type a note).
    case custom

    public var title: String {
        switch self {
        case .trim: return String(localized: "Trim", bundle: .module)
        case .cutInHalf: return String(localized: "Cut in Half", bundle: .module)
        case .rephrase: return String(localized: "Rephrase", bundle: .module)
        case .simplify: return String(localized: "Simplify", bundle: .module)
        case .moreFormal: return String(localized: "More Formal", bundle: .module)
        case .moreCasual: return String(localized: "More Casual", bundle: .module)
        case .proofread: return String(localized: "Proofread", bundle: .module)
        case .anotherWord: return String(localized: "Another Word", bundle: .module)
        case .markWeakest: return String(localized: "Weakest Sentences", bundle: .module)
        case .markLong: return String(localized: "Long Sentences", bundle: .module)
        case .custom: return String(localized: "Custom", bundle: .module)
        }
    }

    /// The Rewrite ▸ submenu, in its two groups (a separator between them).
    public static let rewriteMenuGroups: [[AIAction]] = [[.trim, .cutInHalf], [.rephrase, .simplify, .moreFormal, .moreCasual]]

    /// Find actions (the menu's "Find ▸"; `isMark` and the case names predate the rename)
    /// highlight sentences and change nothing.
    public var isMark: Bool {
        switch self {
        case .markWeakest, .markLong: return true
        default: return false
        }
    }

    /// Actions whose whole point is a different text. A reply identical to the selection is a
    /// failed answer for them ("returned the same text"), never "No changes suggested" — which
    /// stays for Proofread, where finding no errors is a legitimate answer.
    public var mustChangeText: Bool {
        switch self {
        case .trim, .cutInHalf, .rephrase, .simplify, .moreFormal, .moreCasual, .anotherWord, .custom: return true
        case .proofread, .markWeakest, .markLong: return false
        }
    }

    /// Proofread reviews one suggestion per correction; every other edit action is one decision.
    public var reviewsPerCorrection: Bool { self == .proofread }

    public var progressVerb: String {
        switch self {
        case .trim: return String(localized: "Trimming…", bundle: .module)
        case .cutInHalf: return String(localized: "Cutting…", bundle: .module)
        case .rephrase: return String(localized: "Rephrasing…", bundle: .module)
        case .simplify: return String(localized: "Simplifying…", bundle: .module)
        case .moreFormal: return String(localized: "Making it more formal…", bundle: .module)
        case .moreCasual: return String(localized: "Making it more casual…", bundle: .module)
        case .proofread: return String(localized: "Proofreading…", bundle: .module)
        case .anotherWord: return String(localized: "Finding another word…", bundle: .module)
        case .markWeakest, .markLong: return String(localized: "Finding sentences…", bundle: .module)
        case .custom: return String(localized: "Working…", bundle: .module)
        }
    }
}
