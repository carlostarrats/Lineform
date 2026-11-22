import XCTest
@testable import LineformCore

/// A new document is named from its first line. Each test pins one rule.
final class DocumentNamingTests: XCTestCase {
    private var untitled: String { String(localized: "Untitled", bundle: .module) }

    func testUnsafeCharactersAndEmphasisBecomeSpaces() {
        XCTAssertEqual(DocumentNaming.baseName(fromText: "# Notes: 1/2 *draft*"), "Notes 1 2 draft")
    }

    func testFirstNonBlankLineIsUsedAndTrimmed() {
        XCTAssertEqual(DocumentNaming.baseName(fromText: "   \n\n  Hello world  \nmore"), "Hello world")
    }

    func testOnlyMarkersFallsBackToUntitled() {
        XCTAssertEqual(DocumentNaming.baseName(fromText: "#"), untitled)
        XCTAssertEqual(DocumentNaming.untitledBaseName, untitled)
    }

    func testTaskListMarkersAreStripped() {
        XCTAssertEqual(DocumentNaming.baseName(fromText: "- [ ] Buy milk"), "Buy milk")
    }

    func testLeadingDotsAreDropped() {
        XCTAssertEqual(DocumentNaming.baseName(fromText: ".hidden"), "hidden")
    }

    func testEmptyTextHasNoName() {
        XCTAssertNil(DocumentNaming.baseName(fromText: ""))
    }

    func testWhitespaceOnlyTextHasNoName() {
        XCTAssertNil(DocumentNaming.baseName(fromText: "   \n  "))
    }

    func testLongLineCutsAtWordBoundary() throws {
        // 80 characters: words of 9 letters + a space, so a boundary falls in the last 15.
        let line = String(repeating: "abcdefghi ", count: 8)
        XCTAssertEqual(line.count, 80)
        let name = try XCTUnwrap(DocumentNaming.baseName(fromText: line))
        XCTAssertLessThanOrEqual(name.count, 60)
        XCTAssertGreaterThanOrEqual(name.count, 45)
        XCTAssertTrue(line.hasPrefix(name + " "), "cut must land on a word boundary: \(name)")
    }

    func testLongLineWithoutBoundaryCutsHard() throws {
        let name = try XCTUnwrap(DocumentNaming.baseName(fromText: String(repeating: "a", count: 80)))
        XCTAssertEqual(name, String(repeating: "a", count: 60))
    }

    func testEmojiIsNotSplit() throws {
        let thumb: Character = "👍🏽"
        let name = try XCTUnwrap(DocumentNaming.baseName(fromText: String(repeating: thumb, count: 70)))
        XCTAssertFalse(name.isEmpty)
        XCTAssertLessThanOrEqual(name.count, 60)
        XCTAssertTrue(name.allSatisfy { $0 == thumb }, "a cluster was split")
        XCTAssertEqual(name.unicodeScalars.count, name.count * 2)
    }

    /// A file name must fit the file system's 255-byte name limit with room for " N.md".
    func testLongMultibyteNameFitsTheFileNameByteLimit() throws {
        let name = try XCTUnwrap(DocumentNaming.baseName(fromText: String(repeating: "👍🏽", count: 70)))
        XCTAssertLessThanOrEqual(name.utf8.count, DocumentNaming.maximumBaseNameBytes)
        let unique = DocumentNaming.uniqueFileName(base: name, existingNames: [])
        XCTAssertLessThanOrEqual(unique.utf8.count + " 999".utf8.count, 255)
    }

    func testUniqueFileNameIgnoresCase() {
        XCTAssertEqual(
            DocumentNaming.uniqueFileName(base: "Notes", existingNames: ["notes.md", "Notes 2.md"]),
            "Notes 3.md"
        )
    }

    func testUniqueFileNameUsesBaseWhenFree() {
        XCTAssertEqual(DocumentNaming.uniqueFileName(base: "Notes", existingNames: ["Other.md"]), "Notes.md")
    }

    /// "Untitled" is translated in every shipped language, from the package's own catalog.
    func testUntitledIsTranslatedInEveryLanguage() throws {
        let expected = ["en": "Untitled", "es": "Sin título", "fr": "Sans titre", "de": "Ohne Titel",
                        "ja": "名称未設定", "zh-Hans": "未命名"]
        for (language, value) in expected {
            let bundle = try XCTUnwrap(
                Bundle.lineformCore.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)),
                "\(language).lproj missing from the test host"
            )
            XCTAssertEqual(bundle.localizedString(forKey: "Untitled", value: nil, table: nil), value, language)
        }
    }
}
