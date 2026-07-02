import XCTest
@testable import Lineform

@MainActor
final class DocumentReloadControllerTests: XCTestCase {
    private struct FakeReader: DocumentDiskReading {
        var text: String?
        var date: Date?
        func readText(at url: URL) -> String? { text }
        func modificationDate(at url: URL) -> Date? { date }
    }

    private func url() -> URL { URL(fileURLWithPath: "/tmp/lineform-test.md") }

    func testCleanExternalChangeReloads() {
        let controller = DocumentReloadController(diskReader: FakeReader(text: "x"), debounceInterval: 0)
        controller.update(url: url(), syncedText: "old")
        controller.applyDiskSnapshot(url: url(), diskText: "disk-new", modificationDate: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(controller.lastReload?.text, "disk-new")
        XCTAssertEqual(controller.lastReload?.modificationDate, Date(timeIntervalSince1970: 100))
    }

    func testUnsavedInMemoryEditsAreNotClobbered() {
        let controller = DocumentReloadController(diskReader: FakeReader(text: "x"), debounceInterval: 0)
        controller.update(url: url(), syncedText: "old")
        controller.currentText = "user typed"   // diverged from the synced baseline
        controller.applyDiskSnapshot(url: url(), diskText: "disk-new", modificationDate: nil)
        XCTAssertNil(controller.lastReload)
    }

    func testUnchangedDiskIsIgnored() {
        let controller = DocumentReloadController(diskReader: FakeReader(text: "x"), debounceInterval: 0)
        controller.update(url: url(), syncedText: "same")
        controller.applyDiskSnapshot(url: url(), diskText: "same", modificationDate: nil)
        XCTAssertNil(controller.lastReload)
    }

    func testNoURLDoesNotReload() {
        let controller = DocumentReloadController(diskReader: FakeReader(text: "x"), debounceInterval: 0)
        controller.update(url: nil, syncedText: "old")
        controller.applyDiskSnapshot(url: url(), diskText: "disk-new", modificationDate: nil)
        XCTAssertNil(controller.lastReload)
    }

    func testStaleSnapshotURLIsIgnored() {
        let controller = DocumentReloadController(diskReader: FakeReader(text: "x"), debounceInterval: 0)
        controller.update(url: url(), syncedText: "old")
        controller.applyDiskSnapshot(url: URL(fileURLWithPath: "/tmp/other.md"), diskText: "disk-new", modificationDate: nil)
        XCTAssertNil(controller.lastReload)
    }

    func testNilDiskTextIsIgnored() {
        let controller = DocumentReloadController(diskReader: FakeReader(text: nil), debounceInterval: 0)
        controller.update(url: url(), syncedText: "old")
        controller.applyDiskSnapshot(url: url(), diskText: nil, modificationDate: nil)
        XCTAssertNil(controller.lastReload)
    }

    func testReloadAdvancesSyncedBaseline() {
        // After a reload, a subsequent unchanged snapshot must not reload again.
        let controller = DocumentReloadController(diskReader: FakeReader(text: "x"), debounceInterval: 0)
        controller.update(url: url(), syncedText: "old")
        controller.applyDiskSnapshot(url: url(), diskText: "v2", modificationDate: nil)
        XCTAssertEqual(controller.lastReload?.text, "v2")
        controller.clearLastReload()
        controller.currentText = "v2"   // the view applied the reload
        controller.applyDiskSnapshot(url: url(), diskText: "v2", modificationDate: nil)
        XCTAssertNil(controller.lastReload)
    }

    func testDebouncedReloadFromDiskReadsOffMainThenPublishes() {
        let controller = DocumentReloadController(diskReader: FakeReader(text: "disk-new"), debounceInterval: 0.05)
        controller.update(url: url(), syncedText: "old")
        controller.fileDidChange()
        let expectation = expectation(description: "reload")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            if controller.lastReload?.text == "disk-new" { expectation.fulfill() }
        }
        wait(for: [expectation], timeout: 1.5)
    }
}
