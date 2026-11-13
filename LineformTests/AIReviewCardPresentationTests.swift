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

    func testButtonsSayAllUntilFirstDecisionThenRemaining() {
        XCTAssertEqual(AIReviewCardPresentation.buttonTitles(hasDecided: false).accept, "Accept All")
        XCTAssertEqual(AIReviewCardPresentation.buttonTitles(hasDecided: false).reject, "Reject All")
        XCTAssertEqual(AIReviewCardPresentation.buttonTitles(hasDecided: true).accept, "Accept Remaining")
        XCTAssertEqual(AIReviewCardPresentation.buttonTitles(hasDecided: true).reject, "Reject Remaining")
    }

    func testPositionAndProgressText() {
        XCTAssertEqual(AIReviewCardPresentation.positionText(current: 3, total: 7), "3 of 7")
        XCTAssertEqual(AIReviewCardPresentation.progressText(for: .trim, provider: .claude), "Trimming with Claude…")
        XCTAssertEqual(AIReviewCardPresentation.progressText(for: .trim, provider: .other), "Trimming with your AI…")
        XCTAssertEqual(AIReviewCardPresentation.progressText(for: .proofread, provider: .chatGPT), "Proofreading with ChatGPT…")
        XCTAssertEqual(AIReviewCardPresentation.progressText(for: .markLong, provider: .google), "Marking with Google…")
        XCTAssertEqual(AIReviewCardPresentation.cancelHint, "Esc to cancel")
        XCTAssertEqual(AIReviewCardPresentation.markHint, "Esc clears marks")
        XCTAssertEqual(AIReviewCardPresentation.singleChangeHint, "Return to accept · Esc to dismiss")
        for action in AIAction.allCases {
            for provider in AIProvider.allCases where provider != .other {
                XCTAssertTrue(AIReviewCardPresentation.progressText(for: action, provider: provider)
                    .contains(provider.displayName), "\(action) \(provider)")
            }
        }
    }

    func testPositionAndProgressTextAreLocalized() throws {
        for language in Self.languages {
            let bundle = try bundle(language)
            let position = AIReviewCardPresentation.positionText(current: 3, total: 7, bundle: bundle)
            XCTAssertNotEqual(position, "3 of 7", language)
            XCTAssertTrue(position.contains("3") && position.contains("7"), "\(language): \(position)")
            for hasDecided in [false, true] {
                let titles = AIReviewCardPresentation.buttonTitles(hasDecided: hasDecided, bundle: bundle)
                let english = AIReviewCardPresentation.buttonTitles(hasDecided: hasDecided)
                XCTAssertNotEqual(titles.accept, english.accept, language)
                XCTAssertNotEqual(titles.reject, english.reject, language)
            }
            XCTAssertNotEqual(AIReviewCardPresentation.cancelHint(bundle: bundle), "Esc to cancel", language)
            XCTAssertNotEqual(AIReviewCardPresentation.markHint(bundle: bundle), "Esc clears marks", language)
            let hint = AIReviewCardPresentation.singleChangeHint(bundle: bundle)
            XCTAssertNotEqual(hint, "Return to accept · Esc to dismiss", language)
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
            for hasDecided in [false, true] {
                let local = AIReviewTextView.accessibilityActionTitles(hasDecided: hasDecided, bundle: bundle)
                let english = AIReviewTextView.accessibilityActionTitles(hasDecided: hasDecided)
                XCTAssertEqual(local.count, english.count)
                for (title, source) in zip(local, english) {
                    XCTAssertNotEqual(title, source, "\(language): VoiceOver action untranslated")
                }
            }
        }
    }
}
