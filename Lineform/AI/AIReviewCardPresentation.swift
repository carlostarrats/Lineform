import Foundation

/// The copy on the AI's floating cards. Every string is localized HERE, at its definition (a
/// `String` passed to `Text`/`Button` takes the verbatim overload). `bundle` exists so tests can
/// resolve each language through its `.lproj`.
enum AIReviewCardPresentation {
    /// The review card's label: what is ready ("Rewrite ready"). Mark never opens a review; its
    /// cases name the action so the switch stays total.
    static func title(for action: AIAction, bundle: Bundle = .main) -> String {
        switch action {
        case .trim: return String(localized: "Trim ready", bundle: bundle)
        case .cutInHalf: return String(localized: "Cut ready", bundle: bundle)
        case .rephrase: return String(localized: "Rephrase ready", bundle: bundle)
        case .simplify: return String(localized: "Simpler version ready", bundle: bundle)
        case .moreFormal: return String(localized: "More formal version ready", bundle: bundle)
        case .moreCasual: return String(localized: "More casual version ready", bundle: bundle)
        case .proofread: return String(localized: "Proofread ready", bundle: bundle)
        case .anotherWord: return String(localized: "Word ready", bundle: bundle)
        case .markWeakest, .markLong: return action.title
        case .custom: return String(localized: "Suggestion ready", bundle: bundle)
        }
    }

    /// The card's label for a review: Proofread counts its corrections ("Proofread · 2 of 4");
    /// every other action is one change ("Rephrase ready").
    static func title(for session: AIReviewSession, bundle: Bundle = .main) -> String {
        guard session.action.reviewsPerCorrection, let position = session.position else {
            return title(for: session.action, bundle: bundle)
        }
        return String(localized: "Proofread · \(position.index) of \(position.count)", bundle: bundle)
    }

    /// Proofread's keys, on its card: ← / → move between corrections.
    static func reviewHint(for session: AIReviewSession, bundle: Bundle = .main) -> String {
        guard session.action.reviewsPerCorrection else { return reviewHint(bundle: bundle) }
        return proofreadHint(bundle: bundle)
    }

    static func proofreadHint(bundle: Bundle = .main) -> String {
        String(localized: "Return to accept · Esc to reject · ← → to move", bundle: bundle)
    }

    /// Accept All is offered only while two or more corrections are left.
    static func offersAcceptAll(_ session: AIReviewSession) -> Bool {
        session.action.reviewsPerCorrection && session.pending.count >= 2
    }

    static var acceptAllTitle: String { acceptAllTitle(bundle: .main) }
    static func acceptAllTitle(bundle: Bundle) -> String { String(localized: "Accept All", bundle: bundle) }

    /// One change, one decision: Reject, then Accept (the prominent one, trailing).
    static var buttonTitles: (reject: String, accept: String) { buttonTitles(bundle: .main) }
    static func buttonTitles(bundle: Bundle) -> (reject: String, accept: String) {
        (String(localized: "Reject", bundle: bundle), String(localized: "Accept", bundle: bundle))
    }

    /// The card's Try Again icon button (label and tooltip): the same action again, on the same text.
    static var retryTitle: String { retryTitle(bundle: .main) }
    static func retryTitle(bundle: Bundle) -> String { String(localized: "Try Again", bundle: bundle) }
    static let retrySymbol = "arrow.clockwise"

    /// The review's modal keys, on the card so they are discoverable.
    static var reviewHint: String { reviewHint(bundle: .main) }
    static func reviewHint(bundle: Bundle) -> String {
        String(localized: "Return to accept · Esc to reject", bundle: bundle)
    }

    /// "Trimming with Claude…"; for Other, "Trimming with your AI…" (its address is not a name).
    static func progressText(for action: AIAction, provider: AIProvider, bundle: Bundle = .main) -> String {
        guard provider != .other else {
            switch action {
            case .trim: return String(localized: "Trimming with your AI…", bundle: bundle)
            case .cutInHalf: return String(localized: "Cutting with your AI…", bundle: bundle)
            case .rephrase: return String(localized: "Rephrasing with your AI…", bundle: bundle)
            case .simplify: return String(localized: "Simplifying with your AI…", bundle: bundle)
            case .moreFormal: return String(localized: "Making it more formal with your AI…", bundle: bundle)
            case .moreCasual: return String(localized: "Making it more casual with your AI…", bundle: bundle)
            case .proofread: return String(localized: "Proofreading with your AI…", bundle: bundle)
            case .anotherWord: return String(localized: "Finding another word with your AI…", bundle: bundle)
            case .markWeakest, .markLong: return String(localized: "Finding sentences with your AI…", bundle: bundle)
            case .custom: return String(localized: "Working with your AI…", bundle: bundle)
            }
        }
        let name = provider.displayName
        switch action {
        case .trim: return String(localized: "Trimming with \(name)…", bundle: bundle)
        case .cutInHalf: return String(localized: "Cutting with \(name)…", bundle: bundle)
        case .rephrase: return String(localized: "Rephrasing with \(name)…", bundle: bundle)
        case .simplify: return String(localized: "Simplifying with \(name)…", bundle: bundle)
        case .moreFormal: return String(localized: "Making it more formal with \(name)…", bundle: bundle)
        case .moreCasual: return String(localized: "Making it more casual with \(name)…", bundle: bundle)
        case .proofread: return String(localized: "Proofreading with \(name)…", bundle: bundle)
        case .anotherWord: return String(localized: "Finding another word with \(name)…", bundle: bundle)
        case .markWeakest, .markLong: return String(localized: "Finding sentences with \(name)…", bundle: bundle)
        case .custom: return String(localized: "Working with \(name)…", bundle: bundle)
        }
    }

    /// A Rewrite, Trim, Cut in half or Another Word reply identical to the selection: "ChatGPT
    /// returned the same text. Try again."; for Other, "Your AI returned…" (as `progressText`).
    static func sameTextMessage(provider: AIProvider, bundle: Bundle = .main) -> String {
        guard provider != .other else {
            return String(localized: "Your AI returned the same text. Try again.", bundle: bundle)
        }
        let name = provider.displayName
        return String(localized: "\(name) returned the same text. Try again.", bundle: bundle)
    }

    static var cancelHint: String { cancelHint(bundle: .main) }
    static func cancelHint(bundle: Bundle) -> String { String(localized: "Esc to cancel", bundle: bundle) }

    static var markHint: String { markHint(bundle: .main) }
    static func markHint(bundle: Bundle) -> String { String(localized: "Esc clears highlights", bundle: bundle) }

    static var closeTitle: String { String(localized: "Close") }
    static var reviewCardLabel: String { String(localized: "Suggested changes") }
}
