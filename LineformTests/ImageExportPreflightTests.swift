import XCTest
@testable import Lineform

final class ImageExportPreflightTests: XCTestCase {
    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("preflight-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testResolvableLocalImageIsNotFlagged() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        FileManager.default.createFile(atPath: dir.appendingPathComponent("pic.png").path, contents: Data())

        let result = ImageExportPreflight.unresolvedLocalReferences(
            in: "text\n![cat](pic.png)\nmore", documentDirectory: dir)
        XCTAssertTrue(result.isEmpty)
    }

    func testMissingLocalImageIsFlagged() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = ImageExportPreflight.unresolvedLocalReferences(
            in: "![cat](missing.png)", documentDirectory: dir)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.path, "missing.png")
    }

    func testRemoteImageIsNeverFlagged() {
        let result = ImageExportPreflight.unresolvedLocalReferences(
            in: "![x](https://example.com/a.png)\n![y](data:image/png;base64,AAAA)",
            documentDirectory: makeTempDir())
        XCTAssertTrue(result.isEmpty)
    }

    func testNonImageExtensionIsNotFlagged() {
        let result = ImageExportPreflight.unresolvedLocalReferences(
            in: "![notes](notes.txt)", documentDirectory: makeTempDir())
        XCTAssertTrue(result.isEmpty)
    }

    func testMultipleUnresolvedAreAllReturned() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = ImageExportPreflight.unresolvedLocalReferences(
            in: "![a](a.png) inline ![b](sub/b.jpg)", documentDirectory: dir)
        XCTAssertEqual(result.map(\.path).sorted(), ["a.png", "sub/b.jpg"])
    }
}
