import XCTest
@testable import Lineform

final class SaveAsFormatDescriptionTests: XCTestCase {
    func testEachFormatHasADistinctNonEmptyDescription() {
        let descriptions = SaveAsFormat.allCases.map(\.description)
        XCTAssertFalse(descriptions.contains(where: \.isEmpty))
        XCTAssertEqual(Set(descriptions).count, SaveAsFormat.allCases.count)
    }

    func testStyledPDFDescriptionMentionsImages() {
        XCTAssertTrue(SaveAsFormat.styledPDF.description.lowercased().contains("image"))
    }

    func testNormalPDFDescriptionMentionsSource() {
        XCTAssertTrue(SaveAsFormat.pdf.description.lowercased().contains("source"))
    }
}
