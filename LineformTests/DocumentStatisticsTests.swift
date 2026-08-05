import XCTest
@testable import Lineform

final class DocumentStatisticsTests: XCTestCase {
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
}

final class DocumentStatisticsCJKTests: XCTestCase {
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
        let text = EditorStatusFormatter.statisticsText(for: stats)
        XCTAssertFalse(text.contains("words"))
        XCTAssertTrue(text.contains("\(stats.characterCount)"))
    }

    func testLatinStatisticsTextUnchanged() {
        let stats = DocumentStatistics(text: "one two three")
        XCTAssertEqual(EditorStatusFormatter.statisticsText(for: stats), "3 words — 13 characters")
    }

    func testCJKAccessibilityLabelOmitsWordCount() {
        let stats = DocumentStatistics(text: "吾輩は猫である。名前はまだ無い。")
        XCTAssertFalse(EditorStatusFormatter.statusAccessibilityText(for: stats).contains("words"))
    }
}
