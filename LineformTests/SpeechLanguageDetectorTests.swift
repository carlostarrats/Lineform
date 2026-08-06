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

    /// Leading whitespace is dropped before the sample is taken, so a document that opens with
    /// blank lines is judged on its prose, not on its indentation.
    func testLeadingWhitespaceDoesNotConsumeTheSample() {
        let padded = String(repeating: "\n", count: 5_000)
            + "The quick brown fox jumps over the lazy dog. It was a bright cold day in April."
        XCTAssertEqual(SpeechLanguageDetector.language(for: padded), "en")
    }

    /// The detector reads a bounded SAMPLE, not the document. Read-aloud runs this on the whole
    /// extracted text, so an uncapped `processString` hitched in proportion to document size for
    /// an answer the first few hundred words already settle. The ratio is the assertion (absolute
    /// milliseconds flake on a loaded runner): a 400× longer document must not cost 400× more.
    func testDetectionCostDoesNotScaleWithDocumentLength() {
        let paragraph = "The quick brown fox jumps over the lazy dog. It was a bright cold day in April. "
        // Both are longer than the sample cap, so both identify from the SAME number of
        // characters — the only thing that differs is how much text sits behind the cap.
        let short = String(repeating: paragraph, count: 60)      // ~4.8 KB
        let long = String(repeating: paragraph, count: 6_000)    // ~480 KB, 100×

        XCTAssertEqual(SpeechLanguageDetector.language(for: short), "en")
        XCTAssertEqual(SpeechLanguageDetector.language(for: long), "en",
                       "the cap must not change the answer")

        func elapsed(_ text: String) -> Double {
            let start = Date()
            for _ in 0..<5 { _ = SpeechLanguageDetector.language(for: text) }
            return Date().timeIntervalSince(start)
        }
        _ = elapsed(short)                    // warm up NaturalLanguage's model load
        let shortCost = max(elapsed(short), 0.0005)
        let longCost = elapsed(long)

        XCTAssertLessThan(longCost, shortCost * 8,
                          "a 100× longer document cost \(longCost / shortCost)× more to identify — "
                              + "the sample cap in SpeechLanguageDetector is gone")
    }
}
