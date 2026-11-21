import XCTest
@testable import LineformCore

final class DocumentFileWatchingTests: XCTestCase {
    /// The reader decodes with the same codec as the document loader, so a BOM'd file compares
    /// equal to its own in-memory text instead of reloading on every save.
    func testDiskReaderDecodesWithTheFileCodec() throws {
        let source = Data([0xEF, 0xBB, 0xBF]) + Data("# Title\r\n".utf8)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bom-\(UUID().uuidString).md")
        try source.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(FileSystemDiskReader().readText(at: url), MarkdownFileCodec.decode(source))
    }

    func testDiskReaderRejectsInvalidUTF8() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bad-\(UUID().uuidString).md")
        try Data([0xFF, 0xFE, 0x00]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertNil(FileSystemDiskReader().readText(at: url))
    }

    /// `URL` caches resource values per instance, so statting through a stored `URL` froze the
    /// modification date and live reload fired at most once per file. The reader must see a
    /// second external write through the SAME url value it was given the first time.
    func testDiskReaderSeesASecondExternalWriteThroughTheSameURLValue() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stat-\(UUID().uuidString).md")
        try Data("one".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = FileSystemDiskReader()
        let first = reader.modificationDate(at: url)

        try Data("two".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)],
            ofItemAtPath: url.path
        )
        let second = reader.modificationDate(at: url)

        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertNotEqual(first, second)
    }
}
