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

    func testMultipleOwnLineUnresolvedAreAllReturned() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Two images, each ALONE on its own line → both render, both flagged when missing.
        let result = ImageExportPreflight.unresolvedLocalReferences(
            in: "![a](a.png)\n![b](sub/b.jpg)", documentDirectory: dir)
        XCTAssertEqual(result.map(\.path).sorted(), ["a.png", "sub/b.jpg"])
    }

    func testMidSentenceImageIsNotFlagged() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // An image NOT alone on its line renders as the inline placeholder, never a real picture —
        // so granting access would accomplish nothing. It must not trigger the prompt.
        let result = ImageExportPreflight.unresolvedLocalReferences(
            in: "See ![x](/abs/desktop.png) in the middle.", documentDirectory: dir)
        XCTAssertTrue(result.isEmpty)
    }

    func testImageInsideCodeFenceIsNotFlagged() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // An own-line image reference inside a fenced code block is CODE, not a rendered image.
        let text = "```\n![x](missing.png)\n```"
        let result = ImageExportPreflight.unresolvedLocalReferences(in: text, documentDirectory: dir)
        XCTAssertTrue(result.isEmpty)
    }
}
