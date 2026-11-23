import XCTest
@testable import LineformCore

final class CoordinatedFileAccessTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoordinatedFileAccessTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testWriteThenReadRoundTrips() {
        let file = directory.appendingPathComponent("a.json")
        let data = Data("{\"a\":1}".utf8)
        XCTAssertTrue(CoordinatedFileAccess.write(data, to: file))
        XCTAssertEqual(CoordinatedFileAccess.read(file), data)
    }

    func testReadOfMissingFileIsNil() {
        XCTAssertNil(CoordinatedFileAccess.read(directory.appendingPathComponent("missing.json")))
    }

    func testWriteIntoMissingFolderCreatesIt() {
        let file = directory.appendingPathComponent("one/two/b.json")
        XCTAssertTrue(CoordinatedFileAccess.write(Data("x".utf8), to: file))
        XCTAssertEqual(CoordinatedFileAccess.read(file), Data("x".utf8))
    }

    func testWriteReplacesExistingFile() {
        let file = directory.appendingPathComponent("c.json")
        XCTAssertTrue(CoordinatedFileAccess.write(Data("old".utf8), to: file))
        XCTAssertTrue(CoordinatedFileAccess.write(Data("new".utf8), to: file))
        XCTAssertEqual(CoordinatedFileAccess.read(file), Data("new".utf8))
    }

    func testRemoveDeletesAFile() {
        let file = directory.appendingPathComponent("d.json")
        XCTAssertTrue(CoordinatedFileAccess.write(Data("x".utf8), to: file))
        XCTAssertTrue(CoordinatedFileAccess.remove(file))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testRemoveOfMissingFileReturnsFalse() {
        XCTAssertFalse(CoordinatedFileAccess.remove(directory.appendingPathComponent("missing.json")))
    }

    func testRemoveDeletesAFolderAndItsContents() {
        let folder = directory.appendingPathComponent("folder", isDirectory: true)
        XCTAssertTrue(CoordinatedFileAccess.write(Data("x".utf8), to: folder.appendingPathComponent("e.json")))
        XCTAssertTrue(CoordinatedFileAccess.remove(folder))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testContentsOfMissingFolderIsNil() {
        XCTAssertNil(CoordinatedFileAccess.contents(of: directory.appendingPathComponent("missing", isDirectory: true)))
    }

    func testContentsListsEveryItem() throws {
        XCTAssertTrue(CoordinatedFileAccess.write(Data("1".utf8), to: directory.appendingPathComponent("one.json")))
        XCTAssertTrue(CoordinatedFileAccess.write(Data("2".utf8), to: directory.appendingPathComponent(".hidden.json")))
        let names = try XCTUnwrap(CoordinatedFileAccess.contents(of: directory)).map(\.lastPathComponent).sorted()
        XCTAssertEqual(names, [".hidden.json", "one.json"])
    }

    func testMoveToNewPath() {
        let from = directory.appendingPathComponent("from.json")
        let to = directory.appendingPathComponent("sub/to.json")
        XCTAssertTrue(CoordinatedFileAccess.write(Data("moving".utf8), to: from))
        XCTAssertTrue(CoordinatedFileAccess.move(from, to: to))
        XCTAssertFalse(FileManager.default.fileExists(atPath: from.path))
        XCTAssertEqual(CoordinatedFileAccess.read(to), Data("moving".utf8))
    }

    func testMoveReplacesExistingDestination() {
        let from = directory.appendingPathComponent("from.json")
        let to = directory.appendingPathComponent("to.json")
        XCTAssertTrue(CoordinatedFileAccess.write(Data("new".utf8), to: from))
        XCTAssertTrue(CoordinatedFileAccess.write(Data("old".utf8), to: to))
        XCTAssertTrue(CoordinatedFileAccess.move(from, to: to))
        XCTAssertFalse(FileManager.default.fileExists(atPath: from.path))
        XCTAssertEqual(CoordinatedFileAccess.read(to), Data("new".utf8))
    }

    func testMoveOfMissingSourceFailsAndKeepsDestination() {
        let to = directory.appendingPathComponent("to.json")
        XCTAssertTrue(CoordinatedFileAccess.write(Data("keep".utf8), to: to))
        XCTAssertFalse(CoordinatedFileAccess.move(directory.appendingPathComponent("missing.json"), to: to))
        XCTAssertEqual(CoordinatedFileAccess.read(to), Data("keep".utf8))
    }
}
