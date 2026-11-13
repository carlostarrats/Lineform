import XCTest
@testable import Lineform

final class AIReviewCardPresentationTests: XCTestCase {
    private static let languages = ["es", "fr", "de", "ja", "zh-Hans"]

    private func bundle(_ language: String) throws -> Bundle {
        try XCTUnwrap(
            Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)),
            "\(language).lproj missing from the test host"
        )
    }

    /// One decision per action (spec "AI review: option A"): a short label naming the action,
    /// Reject and Accept — no counter, no Accept All / Reject All.
    func testReviewCardSaysWhatIsReadyAndOffersOneDecision() {
        XCTAssertEqual(AIReviewCardPresentation.title(for: .rewrite), "Rewrite ready")
        XCTAssertEqual(AIReviewCardPresentation.title(for: .trim), "Trim ready")
        XCTAssertEqual(AIReviewCardPresentation.title(for: .cutInHalf), "Cut ready")
        XCTAssertEqual(AIReviewCardPresentation.title(for: .proofread), "Proofread ready")
        XCTAssertTrue(AIReviewCardPresentation.buttonTitles == ("Reject", "Accept"))
        XCTAssertEqual(AIReviewCardPresentation.reviewHint, "Return to accept · Esc to reject")
    }

    func testProgressText() {
        XCTAssertEqual(AIReviewCardPresentation.progressText(for: .trim, provider: .claude), "Trimming with Claude…")
        XCTAssertEqual(AIReviewCardPresentation.progressText(for: .trim, provider: .other), "Trimming with your AI…")
        XCTAssertEqual(AIReviewCardPresentation.progressText(for: .proofread, provider: .chatGPT), "Proofreading with ChatGPT…")
        XCTAssertEqual(AIReviewCardPresentation.progressText(for: .markLong, provider: .google), "Marking with Google…")
        XCTAssertEqual(AIReviewCardPresentation.cancelHint, "Esc to cancel")
        XCTAssertEqual(AIReviewCardPresentation.markHint, "Esc clears marks")
        for action in AIAction.allCases {
            for provider in AIProvider.allCases where provider != .other {
                XCTAssertTrue(AIReviewCardPresentation.progressText(for: action, provider: provider)
                    .contains(provider.displayName), "\(action) \(provider)")
            }
        }
    }

    func testReviewAndProgressTextAreLocalized() throws {
        for language in Self.languages {
            let bundle = try bundle(language)
            for action in AIAction.allCases where !action.isMark {
                XCTAssertNotEqual(AIReviewCardPresentation.title(for: action, bundle: bundle),
                                  AIReviewCardPresentation.title(for: action), "\(language) \(action)")
            }
            let titles = AIReviewCardPresentation.buttonTitles(bundle: bundle)
            XCTAssertNotEqual(titles.accept, "Accept", language)
            XCTAssertNotEqual(titles.reject, "Reject", language)
            XCTAssertNotEqual(AIReviewCardPresentation.cancelHint(bundle: bundle), "Esc to cancel", language)
            XCTAssertNotEqual(AIReviewCardPresentation.markHint(bundle: bundle), "Esc clears marks", language)
            let hint = AIReviewCardPresentation.reviewHint(bundle: bundle)
            XCTAssertNotEqual(hint, "Return to accept · Esc to reject", language)
            XCTAssertTrue(hint.contains("Return") && (hint.contains("Esc") || hint.contains("Échap")), "\(language): \(hint)")
            for action in AIAction.allCases {
                for provider in AIProvider.allCases {
                    let local = AIReviewCardPresentation.progressText(for: action, provider: provider, bundle: bundle)
                    XCTAssertNotEqual(local, AIReviewCardPresentation.progressText(for: action, provider: provider),
                                      "\(language) \(action) \(provider)")
                    if provider != .other {
                        XCTAssertTrue(local.contains(provider.displayName), "\(language): \(local) lost the brand")
                    }
                }
            }
            let local = AIReviewTextView.accessibilityActionTitles(bundle: bundle)
            let english = AIReviewTextView.accessibilityActionTitles()
            XCTAssertEqual(local.count, english.count)
            for (title, source) in zip(local, english) {
                XCTAssertNotEqual(title, source, "\(language): VoiceOver action untranslated")
            }
        }
    }
}
