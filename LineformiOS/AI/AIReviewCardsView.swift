import LineformCore
import SwiftUI

/// The review overlay's words on the iPhone (the AI's cards gave way to the AI sheet, 2026-11-24).
/// The accessibility titles are the Mac overlay's.
enum AIReviewCardsPresentation {
    static var doneTitle: String { String(localized: "Done") }
    static var nextTitle: String { String(localized: "Next") }
    static var stopTitle: String { String(localized: "Stop") }

    /// Accept Change, Reject Change, End Review, Accept All, Next Change, Previous Change — the
    /// overlay's custom actions and the key commands' titles, in that order.
    static func accessibilityActionTitles() -> [String] {
        [
            String(localized: "Accept Change"),
            String(localized: "Reject Change"),
            String(localized: "End Review"),
            AIReviewCardPresentation.acceptAllTitle,
            String(localized: "Next Change"),
            String(localized: "Previous Change"),
        ]
    }
}

/// The top of whatever covers the page's bottom during a review (the AI sheet), in the window:
/// the overlay keeps the current change above it.
struct AIReviewCardTopKey: PreferenceKey {
    static let defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = min(value, nextValue()) }
}
