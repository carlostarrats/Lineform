import XCTest
@testable import Lineform

final class ImageResolverTests: XCTestCase {
    private var tempDirectoryURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectoryURL {
            try? FileManager.default.removeItem(at: tempDirectoryURL)
        }
        tempDirectoryURL = nil
        try super.tearDownWithError()
    }

    func testHttpUrlIsRemote() {
        XCTAssertEqual(
            ImageResolver.resolve(path: "http://example.com/a.png", documentDirectory: nil),
            .remote
        )
    }

    func testHttpsUrlIsRemote() {
        XCTAssertEqual(
            ImageResolver.resolve(path: "https://example.com/a.png", documentDirectory: nil),
            .remote
        )
    }

    func testDataUrlIsRemote() {
        XCTAssertEqual(
            ImageResolver.resolve(path: "data:image/png;base64,AAAA", documentDirectory: nil),
            .remote
        )
    }

    func testAbsoluteExistingImageIsLocalFile() throws {
        let fileURL = tempDirectoryURL.appendingPathComponent("pic.png")
        FileManager.default.createFile(atPath: fileURL.path, contents: Data())

        let result = ImageResolver.resolve(path: fileURL.path, documentDirectory: nil)

        guard case let .localFile(resolvedURL) = result else {
            XCTFail("Expected .localFile, got \(result)")
            return
        }
        XCTAssertEqual(resolvedURL.standardizedFileURL, fileURL.standardizedFileURL)
    }

    func testRelativeImageResolvesAgainstDocumentDirectory() throws {
        let subdirectoryURL = tempDirectoryURL.appendingPathComponent("img", isDirectory: true)
        try FileManager.default.createDirectory(at: subdirectoryURL, withIntermediateDirectories: true)
        let fileURL = subdirectoryURL.appendingPathComponent("pic.png")
        FileManager.default.createFile(atPath: fileURL.path, contents: Data())

        let result = ImageResolver.resolve(path: "img/pic.png", documentDirectory: tempDirectoryURL)

        guard case let .localFile(resolvedURL) = result else {
            XCTFail("Expected .localFile, got \(result)")
            return
        }
        XCTAssertEqual(resolvedURL.standardizedFileURL, fileURL.standardizedFileURL)
    }

    func testMissingFileIsUnresolved() {
        XCTAssertEqual(
            ImageResolver.resolve(path: "nope.png", documentDirectory: tempDirectoryURL),
            .unresolved
        )
    }

    func testNonImageExtensionIsUnresolved() {
        let fileURL = tempDirectoryURL.appendingPathComponent("notes.txt")
        FileManager.default.createFile(atPath: fileURL.path, contents: Data())

        XCTAssertEqual(
            ImageResolver.resolve(path: fileURL.path, documentDirectory: nil),
            .unresolved
        )
    }

    func testRelativePathWithNilDirectoryIsUnresolved() {
        XCTAssertEqual(
            ImageResolver.resolve(path: "pic.png", documentDirectory: nil),
            .unresolved
        )
    }
}
