import XCTest
@testable import LineformCore

/// A temp home and a temp fake container `…/iCloud~com~lineform~app/{Documents,History}`. Two
/// devices are two routers (own homes) on the one container. No test touches the real container.
final class RoutingPassageHistoryStoreTests: XCTestCase {
    private var root: URL!
    private var container: URL!
    private var documents: URL!
    private var outside: URL!
    private let clock = Clock()

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_798_800_000)
        var now: Date { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ seconds: TimeInterval) { lock.lock(); value += seconds; lock.unlock() }
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
        func hit() { lock.lock(); count += 1; lock.unlock() }
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("RoutingHistory-\(UUID().uuidString)", isDirectory: true)
        container = root.appendingPathComponent("Mobile Documents/iCloud~com~lineform~app", isDirectory: true)
        documents = container.appendingPathComponent("Documents", isDirectory: true)
        outside = root.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func home(_ device: String) -> URL { root.appendingPathComponent("home-\(device)", isDirectory: true) }
    private func localDirectory(_ device: String) -> URL { FilePassageHistoryStore.defaultDirectory(home: home(device)) }

    private func router(_ device: String = "mac-A", provider: Flag? = nil) -> RoutingPassageHistoryStore {
        let clock = clock, container = container!
        return RoutingPassageHistoryStore(
            local: FilePassageHistoryStore(directory: localDirectory(device), isConfirmedMissing: { _ in false }),
            device: device,
            containerProvider: { provider?.hit(); return container },
            bookmarkDirectory: localDirectory(device).deletingLastPathComponent().appendingPathComponent("HistoryShared"),
            makeShared: { c in SharedPassageHistoryStore(containerURL: c, device: device, now: { clock.now },
                                                         isConfirmedMissing: { _ in false }) },
            now: { clock.now })
    }

    @discardableResult
    private func file(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "Alpha beta.".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func history(_ texts: [String] = ["One", "Two"], id: UUID = UUID(), offset: TimeInterval = 0) -> DocumentHistory {
        let date = clock.now.addingTimeInterval(offset)
        let versions = texts.map { HistoryVersion(text: $0, author: .you, createdAt: date) }
        return DocumentHistory(passages: [HistoryPassage(
            id: id, level: .sentence, versions: versions, currentIndex: versions.count - 1, parentID: nil,
            parentVersionIndex: nil, contextBefore: "", contextAfter: "", lastTouched: date)])
    }

    private func sharedFolders() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: container.appendingPathComponent("History/v1/Documents").path)) ?? [])
    }

    private func localIndexPaths(_ device: String = "mac-A") -> [String] {
        FilePassageHistoryStore(directory: localDirectory(device)).storedDocumentURLs().map(\.path)
    }

    // MARK: - Classify

    func testClassifyRecognisesTheContainer() {
        let mac = URL(fileURLWithPath: "/Users/w/Library/Mobile Documents/iCloud~com~lineform~app/Documents/Notes/Draft.md")
        XCTAssertEqual(HistoryLocation.classify(mac), .shared(
            container: URL(fileURLWithPath: "/Users/w/Library/Mobile Documents/iCloud~com~lineform~app", isDirectory: true),
            relativePath: "Notes/Draft.md"))
        let phone = URL(fileURLWithPath: "/private/var/mobile/Library/Mobile Documents/iCloud~com~lineform~app/Documents/a.md")
        XCTAssertEqual(HistoryLocation.classify(phone), .shared(
            container: URL(fileURLWithPath: "/private/var/mobile/Library/Mobile Documents/iCloud~com~lineform~app", isDirectory: true),
            relativePath: "a.md"))
        XCTAssertEqual(HistoryLocation.classify(URL(fileURLWithPath: "/Users/w/Library/Mobile Documents/com~apple~CloudDocs/a.md")), .local)
        XCTAssertEqual(HistoryLocation.classify(URL(fileURLWithPath: "/Users/w/Library/Mobile Documents/iCloud~com~lineform~app/Documents")), .local)
        XCTAssertEqual(HistoryLocation.classify(URL(fileURLWithPath: "/Users/w/Library/Mobile Documents/iCloud~com~lineform~app/History/x.json")), .local)
        XCTAssertEqual(HistoryLocation.classify(URL(fileURLWithPath: "/Users/w/Documents/a.md")), .local)
        XCTAssertEqual(HistoryLocation.classify(URL(string: "https://example.com/iCloud~com~lineform~app/Documents/a.md")!), .local)
    }

    // MARK: - Local stays local

    func testDocumentOutsideICloudStaysLocalAndUsesTheUnchangedFormat() throws {
        let url = try file(outside.appendingPathComponent("a.md"))
        let store = router()
        let saved = history()
        store.save(saved, for: url)
        XCTAssertEqual(store.load(for: url), saved)
        let names = try FileManager.default.contentsOfDirectory(atPath: localDirectory("mac-A").path).sorted()
        XCTAssertEqual(names.count, 2)
        XCTAssertTrue(names.contains("index.json"))
        XCTAssertEqual(FilePassageHistoryStore(directory: localDirectory("mac-A")).load(for: url), saved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: container.appendingPathComponent("History").path))
    }

    // MARK: - Migration

    func testExistingMacHistoryMigratesOnFirstLoad() throws {
        let url = try file(documents.appendingPathComponent("Two passages and a child.md"))
        // The 1.9.0 fixture's files, indexed at a document inside the container.
        let source = try XCTUnwrap(Bundle.module.url(forResource: "history-1.9.0", withExtension: nil))
        let id = "7D75E7A0-ED45-4559-9C54-91BB92E1C351"
        try FileManager.default.createDirectory(at: localDirectory("mac-A"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source.appendingPathComponent("\(id).json"),
                                         to: localDirectory("mac-A").appendingPathComponent("\(id).json"))
        let index = [["id": id, "pathKey": FileIdentity.key(for: url)]]
        try JSONSerialization.data(withJSONObject: index).write(to: localDirectory("mac-A").appendingPathComponent("index.json"))
        let expected = FilePassageHistoryStore(directory: localDirectory("mac-A")).load(for: url)
        XCTAssertEqual(expected.passages.count, 3)

        let store = router()
        XCTAssertEqual(store.load(for: url), expected)
        XCTAssertEqual(localIndexPaths(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: localDirectory("mac-A").appendingPathComponent("\(id).json").path))
        let record = container.appendingPathComponent(
            "History/v1/Documents/\(SharedPassageHistoryStore.key(for: "Two passages and a child.md"))/mac-A.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.path))
        // Another device sees it; loading again changes nothing.
        XCTAssertEqual(router("iphone-B").load(for: url), expected)
        XCTAssertEqual(store.load(for: url), expected)
    }

    func testPruneMigratesEveryLocalEntryInsideTheContainer() throws {
        let inA = try file(documents.appendingPathComponent("a.md"))
        let inB = try file(documents.appendingPathComponent("Notes/b.md"))
        let out = try file(outside.appendingPathComponent("c.md"))
        let local = FilePassageHistoryStore(directory: localDirectory("mac-A"))
        let ha = history(["A1", "A2"]), hb = history(["B1", "B2"]), hc = history(["C1", "C2"])
        local.save(ha, for: inA); local.save(hb, for: inB); local.save(hc, for: out)

        let store = router()
        store.prune(now: clock.now)
        XCTAssertEqual(localIndexPaths(), [FileIdentity.key(for: out)])
        XCTAssertEqual(sharedFolders().count, 2)
        let phone = router("iphone-B")
        XCTAssertEqual(phone.load(for: inA), ha)
        XCTAssertEqual(phone.load(for: inB), hb)
        XCTAssertEqual(store.load(for: out), hc)
    }

    // MARK: - Moves

    func testMoveIntoICloudCarriesHistory() throws {
        let old = try file(outside.appendingPathComponent("a.md"))
        let new = documents.appendingPathComponent("a.md")
        let store = router()
        let saved = history()
        store.save(saved, for: old)
        try FileManager.default.moveItem(at: old, to: new)
        store.retarget(from: old, to: new)
        XCTAssertEqual(localIndexPaths(), [])
        XCTAssertEqual(store.load(for: new), saved)
        XCTAssertEqual(router("iphone-B").load(for: new), saved)
    }

    func testMoveOutOfICloudMakesHistoryLocal() throws {
        let old = try file(documents.appendingPathComponent("a.md"))
        let new = outside.appendingPathComponent("a.md")
        let store = router()
        let saved = history()
        store.save(saved, for: old)
        XCTAssertEqual(sharedFolders().count, 1)
        try FileManager.default.moveItem(at: old, to: new)
        store.retarget(from: old, to: new)
        XCTAssertEqual(sharedFolders(), [])
        XCTAssertEqual(localIndexPaths(), [FileIdentity.key(for: new)])
        XCTAssertEqual(store.load(for: new), saved)
    }

    func testFolderRenameInsideICloudCarriesHistory() throws {
        let x = try file(documents.appendingPathComponent("Old/x.md"))
        let y = try file(documents.appendingPathComponent("Old/Deep/y.md"))
        let other = try file(documents.appendingPathComponent("Older/z.md"))
        let store = router()
        let hx = history(["X1", "X2"]), hy = history(["Y1", "Y2"]), hz = history(["Z1", "Z2"])
        store.save(hx, for: x); store.save(hy, for: y); store.save(hz, for: other)
        let newDir = documents.appendingPathComponent("New")
        try FileManager.default.moveItem(at: documents.appendingPathComponent("Old"), to: newDir)
        store.retargetDirectory(from: documents.appendingPathComponent("Old"), to: newDir)
        XCTAssertEqual(sharedFolders().count, 3)
        let phone = router("iphone-B")
        XCTAssertEqual(phone.load(for: newDir.appendingPathComponent("x.md")), hx)
        XCTAssertEqual(phone.load(for: newDir.appendingPathComponent("Deep/y.md")), hy)
        XCTAssertEqual(phone.load(for: other), hz)
        XCTAssertEqual(phone.load(for: x), DocumentHistory(passages: []))
    }

    func testFolderMoveOutOfICloudMakesEachHistoryLocal() throws {
        let x = try file(documents.appendingPathComponent("Old/x.md"))
        let y = try file(documents.appendingPathComponent("Old/Deep/y.md"))
        let store = router()
        let hx = history(["X1", "X2"]), hy = history(["Y1", "Y2"])
        store.save(hx, for: x); store.save(hy, for: y)
        let newDir = outside.appendingPathComponent("Old")
        try FileManager.default.moveItem(at: documents.appendingPathComponent("Old"), to: newDir)
        store.retargetDirectory(from: documents.appendingPathComponent("Old"), to: newDir)
        XCTAssertEqual(sharedFolders(), [])
        XCTAssertEqual(store.load(for: newDir.appendingPathComponent("x.md")), hx)
        XCTAssertEqual(store.load(for: newDir.appendingPathComponent("Deep/y.md")), hy)
        XCTAssertEqual(localIndexPaths().count, 2)
    }

    func testFolderMoveIntoICloudCarriesEachHistory() throws {
        let x = try file(outside.appendingPathComponent("Old/x.md"))
        let store = router()
        let hx = history(["X1", "X2"])
        store.save(hx, for: x)
        let newDir = documents.appendingPathComponent("Old")
        try FileManager.default.moveItem(at: outside.appendingPathComponent("Old"), to: newDir)
        store.retargetDirectory(from: outside.appendingPathComponent("Old"), to: newDir)
        XCTAssertEqual(localIndexPaths(), [])
        XCTAssertEqual(router("iphone-B").load(for: newDir.appendingPathComponent("x.md")), hx)
    }

    /// A real bookmark: the file is moved in Finder while Lineform is closed, then the session's
    /// prune follows it into the container.
    func testClosedDocumentMovedInFinderIntoICloudFollowsAtPrune() throws {
        let old = try file(outside.appendingPathComponent("a.md"))
        let saved = history()
        router().save(saved, for: old)
        let new = documents.appendingPathComponent("Moved.md")
        try FileManager.default.moveItem(at: old, to: new)

        let relaunched = router()
        relaunched.prune(now: clock.now)
        XCTAssertEqual(localIndexPaths(), [])
        XCTAssertEqual(router("iphone-B").load(for: new), saved)
    }

    func testClosedSharedDocumentMovedOutOfICloudFollowsAtPrune() throws {
        let old = try file(documents.appendingPathComponent("a.md"))
        let saved = history()
        router().save(saved, for: old)
        let new = outside.appendingPathComponent("a.md")
        try FileManager.default.moveItem(at: old, to: new)

        let relaunched = router()
        relaunched.prune(now: clock.now)
        XCTAssertEqual(sharedFolders(), [])
        XCTAssertEqual(relaunched.load(for: new), saved)
    }

    // MARK: - Clear History

    /// Review Focus 5: B is offline with old History when A clears. The old History never comes
    /// back; what B touched after the clear survives.
    func testClearOnOneDeviceDropsOldHistoryOnTheOther() throws {
        let url = try file(documents.appendingPathComponent("d.md"))
        let a = router("mac-A"), b = router("iphone-B")
        let old = history(["Old 1", "Old 2"])
        a.save(old, for: url)
        var offline = b.load(for: url)
        XCTAssertEqual(offline, old)

        clock.advance(10)
        a.clearAll()
        a.waitForBackgroundWork()
        XCTAssertEqual(sharedFolders(), [])

        clock.advance(10)
        let fresh = history(["New 1", "New 2"])
        offline.passages += fresh.passages
        b.save(offline, for: url)       // B comes back online: its record still holds the old passage

        for reader in [a, b, router("mac-C")] {
            XCTAssertEqual(reader.load(for: url), fresh)
        }
    }

    func testClearAllRemovesLocalAndSharedForThisDevice() throws {
        let shared = try file(documents.appendingPathComponent("s.md"))
        let local = try file(outside.appendingPathComponent("l.md"))
        let store = router()
        store.save(history(), for: shared)
        store.save(history(), for: local)
        clock.advance(1)
        store.clearAll()
        // At once, before the background work: nothing local, and no shared History comes back.
        XCTAssertEqual(localIndexPaths(), [])
        XCTAssertEqual(store.load(for: shared), DocumentHistory(passages: []))
        store.waitForBackgroundWork()
        XCTAssertEqual(sharedFolders(), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: container.appendingPathComponent("History/v1/Cleared/mac-A.json").path))
        XCTAssertEqual(store.load(for: local), DocumentHistory(passages: []))
        XCTAssertEqual(router("iphone-B").load(for: shared), DocumentHistory(passages: []))
    }

    // MARK: - Delete Version, identity, container lookups

    func testNoteVersionDeletedIsForwardedForSharedDocuments() throws {
        let url = try file(documents.appendingPathComponent("d.md"))
        let a = router("mac-A"), b = router("iphone-B")
        let id = UUID()
        a.save(history(["One", "Two"], id: id), for: url)
        let stale = b.load(for: url)

        let before = a.load(for: url)
        a.noteVersionDeleted(passage: id, at: 0, in: before, for: url)
        clock.advance(1)
        a.save(DocumentHistory(passages: []), for: url)   // the engine removed the two-version passage
        clock.advance(1)
        b.save(stale, for: url)
        XCTAssertEqual(a.load(for: url), DocumentHistory(passages: []))
        XCTAssertEqual(b.load(for: url), DocumentHistory(passages: []))

        // A local document: nothing to forward, nothing changes.
        let localURL = try file(outside.appendingPathComponent("l.md"))
        let saved = history(id: id)
        a.save(saved, for: localURL)
        a.noteVersionDeleted(passage: id, at: 0, in: saved, for: localURL)
        a.save(saved, for: localURL)
        XCTAssertEqual(a.load(for: localURL), saved)
    }

    func testDeviceIdentityIsStableAndPlatformPrefixed() throws {
        let suite = "RoutingHistoryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = HistoryDeviceIdentity.current(platform: "mac", defaults: defaults)
        XCTAssertTrue(first.hasPrefix("mac-"))
        XCTAssertNotNil(UUID(uuidString: String(first.dropFirst(4))))
        XCTAssertEqual(HistoryDeviceIdentity.current(platform: "mac", defaults: defaults), first)
        XCTAssertEqual(defaults.string(forKey: "LineformHistoryDeviceID.v1"), first)

        let phoneSuite = suite + "-phone"
        let phoneDefaults = try XCTUnwrap(UserDefaults(suiteName: phoneSuite))
        defer { phoneDefaults.removePersistentDomain(forName: phoneSuite) }
        let phone = HistoryDeviceIdentity.current(platform: "iphone", defaults: phoneDefaults)
        XCTAssertTrue(phone.hasPrefix("iphone-"))
        XCTAssertNotEqual(phone, first)
    }

    func testNoContainerLookupOnLoadOrSave() throws {
        let provider = Flag()
        let store = router(provider: provider)
        let shared = try file(documents.appendingPathComponent("s.md"))
        let local = try file(outside.appendingPathComponent("l.md"))
        for url in [shared, local] {
            store.save(history(), for: url)
            _ = store.load(for: url)
            store.save(DocumentHistory(passages: []), for: url)
        }
        store.retarget(from: shared, to: documents.appendingPathComponent("t.md"))
        XCTAssertEqual(provider.calls, 0)
        store.prune(now: clock.now)
        XCTAssertEqual(provider.calls, 1)
    }
}
