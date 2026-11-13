import XCTest
@testable import Lineform

/// Settings ▸ Clear History: the strings, and that confirming empties the store and every open
/// editor's History without anything writing the cleared history back.
@MainActor
final class SettingsClearHistoryTests: XCTestCase {
    private let text = "Alpha beta gamma delta. Epsilon zeta eta theta."
    private let sentence = "Alpha beta gamma delta."
    private let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsClearHistoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A real file store with every call counted: `savesAfterClear` catches a controller that
    /// writes its in-memory history back after the store was emptied.
    private final class SpyHistoryStore: PassageHistoryPersisting {
        let inner: FilePassageHistoryStore
        private(set) var clearAllCount = 0
        private(set) var savesAfterClear = 0

        init(directory: URL) { inner = FilePassageHistoryStore(directory: directory) }

        func load(for url: URL) -> DocumentHistory { inner.load(for: url) }
        func save(_ history: DocumentHistory, for url: URL) {
            if clearAllCount > 0 { savesAfterClear += 1 }
            inner.save(history, for: url)
        }
        func retarget(from old: URL, to new: URL) { inner.retarget(from: old, to: new) }
        func retargetDirectory(from oldDir: URL, to newDir: URL) { inner.retargetDirectory(from: oldDir, to: newDir) }
        func prune(now: Date) {}
        func clearAll() {
            clearAllCount += 1
            inner.clearAll()
        }
    }

    private func makeFile(_ name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// An editor's controller with one kept passage for `url` (nil: untitled, in memory only).
    private func controllerWithHistory(store: PassageHistoryPersisting, url: URL?,
                                       center: NotificationCenter) -> DocumentHistoryController {
        let date = fixedDate
        let controller = DocumentHistoryController(store: store, now: { date }, notificationCenter: center)
        controller.open(url: url, text: text)
        _ = controller.handle(.add((text as NSString).range(of: sentence)), text: text)
        XCTAssertTrue(controller.hasHistory)
        return controller
    }

    func testClearHistoryStringsAreLocalized() throws {
        let english: [(String, String)] = [
            (SettingsModal.clearHistoryTitle, "Clear History"),
            (SettingsModal.clearHistoryNote, "Removes saved versions for every document. Your files are not changed."),
            (SettingsModal.clearHistoryButtonTitle, "Clear…"),
            (SettingsModal.clearHistoryConfirmTitle, "Clear all history?"),
            (SettingsModal.clearHistoryConfirmMessage, "Saved versions for every document will be removed. This can't be undone. Your files are not changed."),
        ]
        for language in ["es", "fr", "de", "ja", "zh-Hans"] {
            let bundle = try XCTUnwrap(
                Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)),
                "\(language).lproj missing from the test host"
            )
            for (_, key) in english {
                let translated = bundle.localizedString(forKey: key, value: nil, table: nil)
                XCTAssertNotEqual(translated, key, "\(language): \"\(key)\" is not translated")
                XCTAssertFalse(translated.isEmpty)
            }
        }
        let preferred = Bundle.main.preferredLocalizations.first ?? "en"
        if preferred == "en" {
            for (value, key) in english { XCTAssertEqual(value, key) }
        }
    }

    func testClearHistoryCallsClearAll() throws {
        let center = NotificationCenter()
        let store = SpyHistoryStore(directory: directory.appendingPathComponent("store", isDirectory: true))
        let a = try makeFile("a.md")
        let b = try makeFile("b.md")
        let inHistoryMode = controllerWithHistory(store: store, url: a, center: center)
        XCTAssertTrue(inHistoryMode.enterHistoryMode(text: text))
        let other = controllerWithHistory(store: store, url: b, center: center)
        let untitled = controllerWithHistory(store: store, url: nil, center: center)
        // A controller on a different store is not this Clear History's business.
        let elsewhere = controllerWithHistory(
            store: FilePassageHistoryStore(directory: directory.appendingPathComponent("elsewhere", isDirectory: true)),
            url: try makeFile("c.md"),
            center: center
        )

        SettingsModal.clearHistory(store: store, center: center)

        XCTAssertEqual(store.clearAllCount, 1)
        XCTAssertFalse(inHistoryMode.hasHistory)
        XCTAssertFalse(inHistoryMode.isHistoryModeActive, "History mode leaves when its history is cleared")
        XCTAssertFalse(other.hasHistory)
        XCTAssertFalse(untitled.hasHistory, "every document — untitled history in memory too")
        XCTAssertTrue(elsewhere.hasHistory)
        XCTAssertEqual(store.savesAfterClear, 0, "nothing writes the cleared history back")

        // Saving or closing afterwards does not resurrect it.
        inHistoryMode.documentSaved(text: text)
        inHistoryMode.close(text: text)
        other.close(text: text)
        XCTAssertEqual(store.savesAfterClear, 0)
        let reopened = DocumentHistoryController(store: store, notificationCenter: center)
        reopened.open(url: a, text: text)
        XCTAssertFalse(reopened.hasHistory)
    }
}
