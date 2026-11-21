import XCTest
@testable import LineformCore

@MainActor
final class DocumentFolderMonitorTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("folder-monitor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A file another writer adds to the folder (through file coordination, as the Files app,
    /// iCloud and other apps do) is reported within two seconds.
    func testFolderMonitorReportsAddedFile() throws {
        let reported = expectation(description: "the monitor reports the new file")
        reported.assertForOverFulfill = false
        let monitor = DocumentFolderMonitor(folderURL: folder) { reported.fulfill() }
        monitor.start()
        defer { monitor.stop() }

        let fileURL = folder.appendingPathComponent("New.md")
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: nil)
            .coordinate(writingItemAt: fileURL, options: [], error: &coordinationError) { url in
                do { try Data("Hello".utf8).write(to: url) } catch { writeError = error }
            }
        XCTAssertNil(coordinationError)
        XCTAssertNil(writeError)

        wait(for: [reported], timeout: 2)
    }

    /// A burst of changes arrives as one callback: the monitor debounces by
    /// `DocumentFolderMonitor.debounceInterval`.
    func testFolderMonitorCoalescesABurst() throws {
        XCTAssertEqual(DocumentFolderMonitor.debounceInterval, 0.3)
        var calls = 0
        let first = expectation(description: "first callback")
        first.assertForOverFulfill = false
        let monitor = DocumentFolderMonitor(folderURL: folder) {
            calls += 1
            first.fulfill()
        }
        monitor.start()
        defer { monitor.stop() }

        let coordinator = NSFileCoordinator(filePresenter: nil)
        for index in 0..<3 {
            var coordinationError: NSError?
            coordinator.coordinate(
                writingItemAt: folder.appendingPathComponent("Burst \(index).md"),
                options: [], error: &coordinationError
            ) { url in try? Data("x".utf8).write(to: url) }
        }

        wait(for: [first], timeout: 2)
        // Let any straggling callback land before counting.
        RunLoop.main.run(until: Date().addingTimeInterval(DocumentFolderMonitor.debounceInterval * 2))
        XCTAssertEqual(calls, 1)
    }

    /// After `stop()` the monitor reports nothing.
    func testStoppedMonitorReportsNothing() throws {
        let reported = expectation(description: "no report after stop")
        reported.isInverted = true
        let monitor = DocumentFolderMonitor(folderURL: folder) { reported.fulfill() }
        monitor.start()
        monitor.stop()

        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: folder.appendingPathComponent("Late.md"), options: [], error: &coordinationError
        ) { url in try? Data("x".utf8).write(to: url) }

        wait(for: [reported], timeout: 1)
    }
}
