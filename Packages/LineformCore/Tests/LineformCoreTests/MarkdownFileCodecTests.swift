import XCTest
@testable import LineformCore

/// The codec keeps a file's bytes: a leading BOM survives, CRLF is never normalised, and invalid
/// UTF-8 is rejected rather than repaired.
final class MarkdownFileCodecTests: XCTestCase {
    func testBOMSurvivesRoundTrip() throws {
        let bytes = Data([0xEF, 0xBB, 0xBF, 0x23, 0x20, 0x41])
        let text = try XCTUnwrap(MarkdownFileCodec.decode(bytes))
        XCTAssertEqual(text.unicodeScalars.first, "\u{FEFF}")
        XCTAssertEqual(MarkdownFileCodec.encode(text), bytes)
    }

    func testCRLFIsPreserved() throws {
        let bytes = Data("a\r\nb".utf8)
        let text = try XCTUnwrap(MarkdownFileCodec.decode(bytes))
        XCTAssertEqual(text, "a\r\nb")
        XCTAssertEqual(MarkdownFileCodec.encode(text), bytes)
    }

    func testInvalidUTF8IsRejected() {
        XCTAssertNil(MarkdownFileCodec.decode(Data([0xFF, 0xFE, 0x00])))
    }

    func testEmptyDataIsEmptyText() {
        XCTAssertEqual(MarkdownFileCodec.decode(Data()), "")
        XCTAssertEqual(MarkdownFileCodec.encode(""), Data())
    }
}
