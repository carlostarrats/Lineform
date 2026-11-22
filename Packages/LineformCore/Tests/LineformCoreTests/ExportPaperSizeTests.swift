import CoreGraphics
import XCTest
@testable import LineformCore

/// The paper sizes both apps export to. The Mac's export sheet, print setup and the iPhone's
/// exporter all read this one table, so the values are pinned here exactly as the Mac shipped them.
final class ExportPaperSizeTests: XCTestCase {
    func testSizesMatchMac() {
        XCTAssertEqual(ExportPaperSize.allCases, [.usLetter, .usLegal, .tabloid, .a4, .a3, .a5])
        XCTAssertEqual(ExportPaperSize.allCases.map(\.sizeInPoints), [
            CGSize(width: 612, height: 792),
            CGSize(width: 612, height: 1008),
            CGSize(width: 792, height: 1224),
            CGSize(width: 595, height: 842),
            CGSize(width: 842, height: 1191),
            CGSize(width: 420, height: 595),
        ])
    }

    func testContentSizeSubtractsPresetMargins() {
        XCTAssertEqual(ExportPaperSize.usLetter.contentSize(preset: .styled), CGSize(width: 468, height: 648))
        XCTAssertEqual(ExportPaperSize.a4.contentSize(preset: .standard), CGSize(width: 451, height: 698))
    }

    func testClosestPortraitHandlesLandscape() {
        XCTAssertEqual(ExportPaperSize.closest(toPortrait: CGSize(width: 842, height: 595)), .a4)
        XCTAssertEqual(ExportPaperSize.closest(toPortrait: CGSize(width: 612, height: 792)), .usLetter)
        XCTAssertEqual(ExportPaperSize.closest(toPortrait: CGSize(width: 1008, height: 612)), .usLegal)
    }

    func testRegionalDefault() {
        XCTAssertEqual(ExportPaperSize.regionalDefault(regionCode: "US"), .usLetter)
        XCTAssertEqual(ExportPaperSize.regionalDefault(regionCode: "CA"), .usLetter)
        XCTAssertEqual(ExportPaperSize.regionalDefault(regionCode: "MX"), .usLetter)
        XCTAssertEqual(ExportPaperSize.regionalDefault(regionCode: "PH"), .usLetter)
        XCTAssertEqual(ExportPaperSize.regionalDefault(regionCode: "CL"), .usLetter)
        XCTAssertEqual(ExportPaperSize.regionalDefault(regionCode: "CO"), .usLetter)
        XCTAssertEqual(ExportPaperSize.regionalDefault(regionCode: "VE"), .usLetter)
        XCTAssertEqual(ExportPaperSize.regionalDefault(regionCode: "GT"), .usLetter)
        XCTAssertEqual(ExportPaperSize.regionalDefault(regionCode: "PR"), .usLetter)
        XCTAssertEqual(ExportPaperSize.regionalDefault(regionCode: "DE"), .a4)
        XCTAssertEqual(ExportPaperSize.regionalDefault(regionCode: "GB"), .a4)
        XCTAssertEqual(ExportPaperSize.regionalDefault(regionCode: nil), .a4)
    }

    func testDisplayNamesLocalizedInEveryLanguage() throws {
        XCTAssertEqual(ExportPaperSize.allCases.map(\.displayName),
                       ["US Letter", "US Legal", "Tabloid", "A4", "A3", "A5"])
        // English is the key itself (the catalog carries no explicit "en" entry); every other
        // language must carry its own translation in the package catalog.
        let missing = "<missing>"
        for language in ["es", "fr", "de", "ja", "zh-Hans"] {
            let bundle = try XCTUnwrap(
                Bundle.lineformCore.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)),
                "\(language).lproj missing from the test host"
            )
            for key in ["US Letter", "US Legal", "Tabloid", "A4", "A3", "A5"] {
                let value = bundle.localizedString(forKey: key, value: missing, table: nil)
                XCTAssertNotEqual(value, missing, "\(key) missing in \(language)")
                XCTAssertFalse(value.isEmpty, "\(key) empty in \(language)")
            }
        }
    }
}
