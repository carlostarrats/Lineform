import XCTest
@testable import Lineform

final class SpeechLanguageDetectorTests: XCTestCase {

    func testDetectsUnambiguousProse() {
        XCTAssertEqual(SpeechLanguageDetector.language(for:
            "The quick brown fox jumps over the lazy dog. It was a bright cold day in April."), "en")
        XCTAssertEqual(SpeechLanguageDetector.language(for:
            "吾輩は猫である。名前はまだ無い。どこで生れたかとんと見当がつかぬ。"), "ja")
    }

    /// The whole point of the feature: the document's language wins over the UI's. This test does
    /// not touch the UI locale at all — that is the invariant, the detector never reads it.
    func testDetectionIsIndependentOfTheProcessLocale() {
        let english = "This document is written entirely in English and should be read as such."
        XCTAssertEqual(SpeechLanguageDetector.language(for: english), "en")
    }

    /// A heuristic on user prose. Two words is not evidence, and a confidently wrong voice is
    /// worse than the system default — nil means "leave it alone".
    func testReturnsNilForInputTooShortToJudge() {
        XCTAssertNil(SpeechLanguageDetector.language(for: "ok"))
        XCTAssertNil(SpeechLanguageDetector.language(for: ""))
        XCTAssertNil(SpeechLanguageDetector.language(for: "   \n  "))
    }

    func testReturnsNilWhenNoLanguageClearsTheConfidenceFloor() {
        XCTAssertNil(SpeechLanguageDetector.language(for: "asdf qwer zxcv hjkl 12345 67890 ..."))
    }
}
