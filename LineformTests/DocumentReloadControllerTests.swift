import XCTest
@testable import Lineform

@MainActor
final class DocumentReloadControllerTests: XCTestCase {
    @MainActor
    private final class FakeDirty: DocumentDirtyProviding {
        var isDocumentEdited: Bool
        init(_ v: Bool) { isDocumentEdited = v }
    }

    private final class FakeReader: DocumentDiskReading {
        var text: String?
        var date: Date?
        init(text: String?, date: Date? = nil) { self.text = text; self.date = date }
        func readText(at url: URL) -> String? { text }
        func modificationDate(at url: URL) -> Date? { date }
    }

    private func url() -> URL { URL(fileURLWithPath: "/tmp/lineform-test.md") }

    func testCleanChangedFilePublishesReload() {
        let reader = FakeReader(text: "disk", date: Date(timeIntervalSince1970: 100))
        let controller = DocumentReloadController(diskReader: reader, debounceInterval: 0)
        controller.currentText = "memory"
        controller.update(url: url(), dirtyProvider: FakeDirty(false))
        controller.evaluate()
        XCTAssertEqual(controller.lastReload?.text, "disk")
        XCTAssertEqual(controller.lastReload?.modificationDate, Date(timeIntervalSince1970: 100))
    }

    func testDirtyFileDoesNotReload() {
        let reader = FakeReader(text: "disk")
        let controller = DocumentReloadController(diskReader: reader, debounceInterval: 0)
        controller.currentText = "memory"
        controller.update(url: url(), dirtyProvider: FakeDirty(true))
        controller.evaluate()
        XCTAssertNil(controller.lastReload)
    }

    func testUnchangedFileDoesNotReload() {
        let reader = FakeReader(text: "same")
        let controller = DocumentReloadController(diskReader: reader, debounceInterval: 0)
        controller.currentText = "same"
        controller.update(url: url(), dirtyProvider: FakeDirty(false))
        controller.evaluate()
        XCTAssertNil(controller.lastReload)
    }

    func testNoURLDoesNotReload() {
        let reader = FakeReader(text: "disk")
        let controller = DocumentReloadController(diskReader: reader, debounceInterval: 0)
        controller.currentText = "memory"
        controller.update(url: nil, dirtyProvider: FakeDirty(false))
        controller.evaluate()
        XCTAssertNil(controller.lastReload)
    }

    func testUnreadableDiskDoesNotReload() {
        let reader = FakeReader(text: nil)
        let controller = DocumentReloadController(diskReader: reader, debounceInterval: 0)
        controller.currentText = "memory"
        controller.update(url: url(), dirtyProvider: FakeDirty(false))
        controller.evaluate()
        XCTAssertNil(controller.lastReload)
    }

    func testDebouncedChangeEventuallyReloads() {
        let reader = FakeReader(text: "disk")
        let controller = DocumentReloadController(diskReader: reader, debounceInterval: 0.05)
        controller.currentText = "memory"
        controller.update(url: url(), dirtyProvider: FakeDirty(false))
        controller.fileDidChange()
        let expectation = expectation(description: "reload")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if controller.lastReload?.text == "disk" { expectation.fulfill() }
        }
        wait(for: [expectation], timeout: 1.0)
    }
}
