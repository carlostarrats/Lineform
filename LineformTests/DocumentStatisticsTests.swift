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
