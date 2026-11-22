import XCTest
@testable import LineformCore

/// Moved from the Mac's `DocumentStatisticsTests`. The statistics themselves have always been
/// package code; the wording moved with `DocumentStatusText`. Runs under the test plan's `en`.
final class DocumentStatusTextTests: XCTestCase {
    func testCountsWordsAndCharacters() {
        let stats = DocumentStatistics(text: "One calm line.\n\nTwo more words.")

        XCTAssertEqual(stats.wordCount, 6)
        XCTAssertEqual(stats.characterCount, 31)
    }

    func testEmptyDocumentHasZeroCounts() {
        let stats = DocumentStatistics(text: " \n\t")

        XCTAssertEqual(stats.wordCount, 0)
        XCTAssertEqual(stats.characterCount, 3)
    }

    func testWordCountingDoesNotDependOnAllocatingSeparatedComponents() {
        let text = "One-two three_4\nfive...six"
        let stats = DocumentStatistics(text: text)

        XCTAssertEqual(stats.wordCount, 6)
        XCTAssertEqual(stats.characterCount, (text as NSString).length)
    }

    func testJapaneseDocumentIsPredominantlyCJK() {
        let stats = DocumentStatistics(text: "吾輩は猫である。名前はまだ無い。")
        XCTAssertTrue(stats.isPredominantlyCJK)
    }

    func testEnglishDocumentIsNot() {
        XCTAssertFalse(DocumentStatistics(text: "The quick brown fox.").isPredominantlyCJK)
    }

    func testEnglishDocumentQuotingOneJapaneseSentenceKeepsWordCount() {
        let text = """
        The novel opens with a famous line. 吾輩は猫である。 It is narrated by a cat, \
        and the rest of this paragraph is English prose that outweighs the quotation \
        by a comfortable margin for the majority rule.
        """
        XCTAssertFalse(DocumentStatistics(text: text).isPredominantlyCJK)
    }

    func testHangulDoesNotTriggerSuppression() {
        XCTAssertFalse(DocumentStatistics(text: "나는 고양이로소이다 이름은 아직 없다").isPredominantlyCJK)
    }

    func testEmptyDocumentIsNot() {
        XCTAssertFalse(DocumentStatistics(text: "").isPredominantlyCJK)
    }

    func testCJKStatisticsTextReportsCharactersOnly() {
        let stats = DocumentStatistics(text: "吾輩は猫である。名前はまだ無い。")
        let text = DocumentStatusText.counts(stats)
        XCTAssertFalse(text.contains("words"))
        XCTAssertTrue(text.contains("\(stats.characterCount)"))
    }

    func testLatinStatisticsTextUnchanged() {
        let stats = DocumentStatistics(text: "one two three")
        XCTAssertEqual(DocumentStatusText.counts(stats), "3 words — 13 characters")
    }

    func testCJKAccessibilityLabelOmitsWordCount() {
        let stats = DocumentStatistics(text: "吾輩は猫である。名前はまだ無い。")
        XCTAssertFalse(DocumentStatusText.countsAccessibilityText(stats).contains("words"))
        XCTAssertEqual(DocumentStatusText.countsAccessibilityText(DocumentStatistics(text: "one two")),
                       "Document contains 2 words and 7 characters")
    }

    func testSaveStateWording() {
        XCTAssertEqual(DocumentStatusText.saveState(isSaved: true, isAutosaved: false), "Saved")
        XCTAssertEqual(DocumentStatusText.saveState(isSaved: true, isAutosaved: true), "Autosaved")
        XCTAssertEqual(DocumentStatusText.saveState(isSaved: false, isAutosaved: true), "Unsaved changes")
        XCTAssertEqual(DocumentStatusText.saveState(isSaved: false, isAutosaved: false), "Unsaved changes")
    }

    /// The package copy of each key resolves in every language (the app's copy is pinned
    /// identical by `LocalizationCatalogTests`).
    func testWordingLocalizesFromThePackageCatalog() throws {
        let german = try XCTUnwrap(Bundle.lineformCore.path(forResource: "de", ofType: "lproj").flatMap(Bundle.init(path:)))
        XCTAssertEqual(german.localizedString(forKey: "Saved", value: nil, table: nil), "Gesichert")
        XCTAssertNotEqual(german.localizedString(forKey: "%lld words — %lld characters", value: nil, table: nil),
                          "%lld words — %lld characters")
    }
}
