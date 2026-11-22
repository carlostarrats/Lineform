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

    /// A coordinated delete (Files, iCloud) reaches the owner through `onDelete`, not `onChange`.
    func testWatcherReportsACoordinatedDeleteThroughOnDelete() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("delete-\(UUID().uuidString).md")
        try Data("doomed".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let watcher = DocumentFileWatcher(url: url)
        let deleted = expectation(description: "onDelete")
        deleted.assertForOverFulfill = false
        watcher.onDelete = { deleted.fulfill() }
        NSFileCoordinator.addFilePresenter(watcher)
        defer { NSFileCoordinator.removeFilePresenter(watcher) }

        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil)
            .coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { deleteURL in
                try? FileManager.default.removeItem(at: deleteURL)
            }
        XCTAssertNil(coordinationError)

        wait(for: [deleted], timeout: 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// A change notice for a file that is gone counts as a delete when the owner asked for deletes.
    func testChangeToAMissingFileIsReportedAsADelete() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).md")
        let watcher = DocumentFileWatcher(url: url)
        var events: [String] = []
        watcher.onChange = { events.append("change") }
        watcher.onDelete = { events.append("delete") }

        watcher.presentedItemDidChange()

        XCTAssertEqual(events, ["delete"])
    }

    /// Without `onDelete` (the Mac), a change notice is still a change, whatever is on disk.
    func testWithoutOnDeleteAChangeIsStillAChange() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).md")
        let watcher = DocumentFileWatcher(url: url)
        var events: [String] = []
        watcher.onChange = { events.append("change") }

        watcher.presentedItemDidChange()

        XCTAssertEqual(events, ["change"])
    }

    /// The coordinator announces a deletion for a `.forReplacing` write too; that is a change.
    func testReplacingWriteIsAChangeNotADelete() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("replace-\(UUID().uuidString).md")
        try Data("one".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let watcher = DocumentFileWatcher(url: url)
        let lock = NSLock()
        nonisolated(unsafe) var events: [String] = []
        let changed = expectation(description: "onChange")
        changed.assertForOverFulfill = false
        watcher.onChange = { lock.withLock { events.append("change") }; changed.fulfill() }
        watcher.onDelete = { lock.withLock { events.append("delete") } }
        NSFileCoordinator.addFilePresenter(watcher)
        defer { NSFileCoordinator.removeFilePresenter(watcher) }

        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil)
            .coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { writeURL in
                try? Data("two".utf8).write(to: writeURL, options: .atomic)
            }

        wait(for: [changed], timeout: 3)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(lock.withLock { events }.filter { $0 == "delete" }, [])
    }

    /// Without `onDelete` (the Mac) the watcher does not take part in deletes or writer handoffs.
    func testWithoutOnDeleteTheWatcherDoesNotAnswerDeleteCallbacks() {
        let watcher = DocumentFileWatcher(url: FileManager.default.temporaryDirectory)
        let accommodate = #selector(NSFilePresenter.accommodatePresentedItemDeletion(completionHandler:))
        let relinquish = #selector(NSFilePresenter.relinquishPresentedItem(toWriter:))
        XCTAssertFalse(watcher.responds(to: accommodate))
        XCTAssertFalse(watcher.responds(to: relinquish))

        watcher.onDelete = {}
        XCTAssertTrue(watcher.responds(to: accommodate))
        XCTAssertTrue(watcher.responds(to: relinquish))
    }

    /// An external rename (Files, iCloud) is a move, not a delete: once the watcher has seen
    /// `presentedItemDidMove`, the old path being empty is not reported through `onDelete`.
    func testCoordinatedMoveReportsOnMoveAndNeverOnDelete() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("move-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Before.md")
        let destination = folder.appendingPathComponent("After.md")
        try Data("moving".utf8).write(to: url)

        let watcher = DocumentFileWatcher(url: url)
        let lock = NSLock()
        nonisolated(unsafe) var events: [String] = []
        let moved = expectation(description: "onMove")
        watcher.onMove = { newURL in
            lock.withLock { events.append("move \(newURL.lastPathComponent)") }
            moved.fulfill()
        }
        watcher.onDelete = { lock.withLock { events.append("delete") } }
        watcher.onChange = { lock.withLock { events.append("change") } }
        NSFileCoordinator.addFilePresenter(watcher)
        defer { NSFileCoordinator.removeFilePresenter(watcher) }

        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        coordinator.coordinate(
            writingItemAt: url, options: .forMoving,
            writingItemAt: destination, options: .forReplacing,
            error: &coordinationError
        ) { from, to in
            coordinator.item(at: from, willMoveTo: to)
            try? FileManager.default.moveItem(at: from, to: to)
            coordinator.item(at: from, didMoveTo: to)
        }
        XCTAssertNil(coordinationError)

        wait(for: [moved], timeout: 3)
        // Give a delete, if one were coming after the writer, time to land.
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(lock.withLock { events }.filter { $0 == "delete" }, [], "a rename is not a delete")
        XCTAssertEqual(lock.withLock { events }.first, "move After.md")
    }

    /// After a move, a change notice for the (now empty) old path is not a delete either.
    func testChangeAfterAMoveIsNotADelete() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("moved-away-\(UUID().uuidString).md")
        let watcher = DocumentFileWatcher(url: url)
        var events: [String] = []
        watcher.onMove = { _ in events.append("move") }
        watcher.onChange = { events.append("change") }
        watcher.onDelete = { events.append("delete") }

        watcher.presentedItemDidMove(to: url.deletingLastPathComponent().appendingPathComponent("Elsewhere.md"))
        watcher.presentedItemDidChange()

        XCTAssertEqual(events, ["move", "change"])
    }
}
