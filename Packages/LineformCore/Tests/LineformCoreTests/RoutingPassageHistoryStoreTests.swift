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

    private func router(_ device: String = "mac-A", provider: Flag? = nil, reachable: Bool = true) -> RoutingPassageHistoryStore {
        let clock = clock, container = container!
        return RoutingPassageHistoryStore(
            local: FilePassageHistoryStore(directory: localDirectory(device), isConfirmedMissing: { _ in false }),
            containerProvider: { provider?.hit(); return reachable ? container : nil },
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

    private func bookmarksURL(_ device: String = "mac-A") -> URL {
        localDirectory(device).deletingLastPathComponent().appendingPathComponent("HistoryShared/bookmarks.json")
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
        store.saveAndWait(saved, for: url)
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
        store.waitForBackgroundWork()
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
        store.waitForBackgroundWork()
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
        store.saveAndWait(saved, for: old)
        try FileManager.default.moveItem(at: old, to: new)
        store.retarget(from: old, to: new)
        store.waitForBackgroundWork()
        XCTAssertEqual(localIndexPaths(), [])
        XCTAssertEqual(store.load(for: new), saved)
        XCTAssertEqual(router("iphone-B").load(for: new), saved)
    }

    func testMoveOutOfICloudMakesHistoryLocal() throws {
        let old = try file(documents.appendingPathComponent("a.md"))
        let new = outside.appendingPathComponent("a.md")
        let store = router()
        let saved = history()
        store.saveAndWait(saved, for: old)
        XCTAssertEqual(sharedFolders().count, 1)
        try FileManager.default.moveItem(at: old, to: new)
        store.retarget(from: old, to: new)
        store.waitForBackgroundWork()
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
        store.saveAndWait(hx, for: x); store.saveAndWait(hy, for: y); store.saveAndWait(hz, for: other)
        let newDir = documents.appendingPathComponent("New")
        try FileManager.default.moveItem(at: documents.appendingPathComponent("Old"), to: newDir)
        store.retargetDirectory(from: documents.appendingPathComponent("Old"), to: newDir)
        store.waitForBackgroundWork()
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
        store.saveAndWait(hx, for: x); store.saveAndWait(hy, for: y)
        let newDir = outside.appendingPathComponent("Old")
        try FileManager.default.moveItem(at: documents.appendingPathComponent("Old"), to: newDir)
        store.retargetDirectory(from: documents.appendingPathComponent("Old"), to: newDir)
        store.waitForBackgroundWork()
        XCTAssertEqual(sharedFolders(), [])
        XCTAssertEqual(store.load(for: newDir.appendingPathComponent("x.md")), hx)
        XCTAssertEqual(store.load(for: newDir.appendingPathComponent("Deep/y.md")), hy)
        XCTAssertEqual(localIndexPaths().count, 2)
    }

    func testFolderMoveIntoICloudCarriesEachHistory() throws {
        let x = try file(outside.appendingPathComponent("Old/x.md"))
        let store = router()
        let hx = history(["X1", "X2"])
        store.saveAndWait(hx, for: x)
        let newDir = documents.appendingPathComponent("Old")
        try FileManager.default.moveItem(at: outside.appendingPathComponent("Old"), to: newDir)
        store.retargetDirectory(from: outside.appendingPathComponent("Old"), to: newDir)
        store.waitForBackgroundWork()
        XCTAssertEqual(localIndexPaths(), [])
        XCTAssertEqual(router("iphone-B").load(for: newDir.appendingPathComponent("x.md")), hx)
    }

    /// A real bookmark: the file is moved in Finder while Lineform is closed, then the session's
    /// prune follows it into the container.
    func testClosedDocumentMovedInFinderIntoICloudFollowsAtPrune() throws {
        let old = try file(outside.appendingPathComponent("a.md"))
        let saved = history()
        router().saveAndWait(saved, for: old)
        let new = documents.appendingPathComponent("Moved.md")
        try FileManager.default.moveItem(at: old, to: new)

        let relaunched = router()
        relaunched.prune(now: clock.now)
        relaunched.waitForBackgroundWork()
        XCTAssertEqual(localIndexPaths(), [])
        XCTAssertEqual(router("iphone-B").load(for: new), saved)
    }

    func testClosedSharedDocumentMovedOutOfICloudFollowsAtPrune() throws {
        let old = try file(documents.appendingPathComponent("a.md"))
        let saved = history()
        router().saveAndWait(saved, for: old)
        let new = outside.appendingPathComponent("a.md")
        try FileManager.default.moveItem(at: old, to: new)

        let relaunched = router()
        relaunched.prune(now: clock.now)
        relaunched.waitForBackgroundWork()
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
        a.saveAndWait(old, for: url)
        var offline = b.load(for: url)
        XCTAssertEqual(offline, old)

        clock.advance(10)
        a.clearAll()
        a.waitForBackgroundWork()
        XCTAssertEqual(sharedFolders(), [])

        clock.advance(10)
        let fresh = history(["New 1", "New 2"])
        offline.passages += fresh.passages
        b.saveAndWait(offline, for: url)       // B comes back online: its record still holds the old passage

        for reader in [a, b, router("mac-C")] {
            XCTAssertEqual(reader.load(for: url), fresh)
        }
    }

    func testClearAllRemovesLocalAndSharedForThisDevice() throws {
        let shared = try file(documents.appendingPathComponent("s.md"))
        let local = try file(outside.appendingPathComponent("l.md"))
        let store = router()
        store.saveAndWait(history(), for: shared)
        store.saveAndWait(history(), for: local)
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
        a.saveAndWait(history(["One", "Two"], id: id), for: url)
        let stale = b.load(for: url)

        let before = a.load(for: url)
        a.noteVersionDeleted(passage: id, at: 0, in: before, for: url)
        clock.advance(1)
        a.saveAndWait(DocumentHistory(passages: []), for: url)   // the engine removed the two-version passage
        clock.advance(1)
        b.saveAndWait(stale, for: url)
        XCTAssertEqual(a.load(for: url), DocumentHistory(passages: []))
        XCTAssertEqual(b.load(for: url), DocumentHistory(passages: []))

        // A local document: nothing to forward, nothing changes.
        let localURL = try file(outside.appendingPathComponent("l.md"))
        let saved = history(id: id)
        a.saveAndWait(saved, for: localURL)
        a.noteVersionDeleted(passage: id, at: 0, in: saved, for: localURL)
        a.saveAndWait(saved, for: localURL)
        XCTAssertEqual(a.load(for: localURL), saved)
    }

    // MARK: - I3: the device name

    final class MemoryDeviceIDs: HistoryDeviceIDStoring {
        var stored: String?
        var available = true
        var writes = 0
        func readDeviceID() -> HistoryDeviceIDRead {
            guard available else { return .unavailable }
            return stored.map { .found($0) } ?? .notFound
        }
        func writeDeviceID(_ id: String) -> Bool {
            writes += 1
            guard available else { return false }
            stored = id
            return true
        }
    }

    private func defaultsSuite() throws -> UserDefaults {
        let suite = "RoutingHistoryTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    /// Kept in the device-only store, never in user defaults (which a backup restore copies).
    func testDeviceIdentityIsStablePlatformPrefixedAndNotInDefaults() throws {
        let defaults = try defaultsSuite()
        let ids = MemoryDeviceIDs()
        let first = HistoryDeviceIdentity.current(platform: "mac", storage: ids, defaults: defaults)
        XCTAssertTrue(first.hasPrefix("mac-"))
        XCTAssertNotNil(UUID(uuidString: String(first.dropFirst(4))))
        XCTAssertEqual(HistoryDeviceIdentity.current(platform: "mac", storage: ids, defaults: defaults), first)
        XCTAssertEqual(ids.stored, first)
        XCTAssertNil(defaults.object(forKey: "LineformHistoryDeviceID.v1"))

        let phone = HistoryDeviceIdentity.current(platform: "iphone", storage: MemoryDeviceIDs(), defaults: try defaultsSuite())
        XCTAssertTrue(phone.hasPrefix("iphone-"))
        XCTAssertNotEqual(phone, first)
    }

    /// A name an earlier build kept in user defaults moves to the device-only store once, and is
    /// then removed from defaults: the same name, so this device keeps writing its own records.
    func testDefaultsDeviceNameMigratesOnceToTheKeychain() throws {
        let defaults = try defaultsSuite()
        defaults.set("iphone-OLD", forKey: "LineformHistoryDeviceID.v1")
        let ids = MemoryDeviceIDs()
        XCTAssertEqual(HistoryDeviceIdentity.current(platform: "iphone", storage: ids, defaults: defaults), "iphone-OLD")
        XCTAssertEqual(ids.stored, "iphone-OLD")
        XCTAssertNil(defaults.object(forKey: "LineformHistoryDeviceID.v1"))
        XCTAssertEqual(HistoryDeviceIdentity.current(platform: "iphone", storage: ids, defaults: defaults), "iphone-OLD")
        XCTAssertEqual(ids.writes, 1)
    }

    /// No Keychain: the name lives in defaults, and is the same at every launch.
    func testDeviceNameFallsBackToDefaultsWhenTheKeychainIsUnavailable() throws {
        let defaults = try defaultsSuite()
        let ids = MemoryDeviceIDs()
        ids.available = false
        let first = HistoryDeviceIdentity.current(platform: "mac", storage: ids, defaults: defaults)
        XCTAssertEqual(HistoryDeviceIdentity.current(platform: "mac", storage: ids, defaults: defaults), first)
        XCTAssertEqual(defaults.string(forKey: "LineformHistoryDeviceID.v1"), first)

        // An existing defaults name is kept when the Keychain refuses the migration.
        let legacy = try defaultsSuite()
        legacy.set("mac-OLD", forKey: "LineformHistoryDeviceID.v1")
        let refusing = MemoryDeviceIDs()
        refusing.available = false
        XCTAssertEqual(HistoryDeviceIdentity.current(platform: "mac", storage: refusing, defaults: legacy), "mac-OLD")
        XCTAssertEqual(legacy.string(forKey: "LineformHistoryDeviceID.v1"), "mac-OLD")
    }

    /// The live router reads the device name only when a shared document first uses History.
    func testLiveRouterReadsTheDeviceNameOnlyForSharedHistory() throws {
        let ids = MemoryDeviceIDs()
        let store = RoutingPassageHistoryStore.live(platform: "mac", home: home("live"), defaults: try defaultsSuite(),
                                                    deviceIDStorage: ids)
        let url = try file(outside.appendingPathComponent("l.md"))
        store.save(history(), for: url)
        _ = store.load(for: url)
        XCTAssertNil(ids.stored)
        XCTAssertEqual(ids.writes, 0)
    }

    /// Re-review I3 (Mac): the salt is part of the name, so a Keychain carried to another Mac
    /// still makes a different name there; the same Mac keeps its name.
    func testHardwareSaltMakesTheNamePerMac() throws {
        let ids = MemoryDeviceIDs()
        let defaults = try defaultsSuite()
        let here = HistoryDeviceIdentity.current(platform: "mac", storage: ids, defaults: defaults, salt: "0a1b2c3d")
        XCTAssertEqual(HistoryDeviceIdentity.current(platform: "mac", storage: ids, defaults: defaults, salt: "0a1b2c3d"), here)
        XCTAssertTrue(here.hasSuffix("-0a1b2c3d"))
        let migrated = HistoryDeviceIdentity.current(platform: "mac", storage: ids, defaults: defaults, salt: "ffee0011")
        XCTAssertNotEqual(migrated, here)
        XCTAssertEqual(HistoryDeviceIdentity.current(platform: "mac", storage: ids, defaults: defaults, salt: nil), ids.stored)
        XCTAssertEqual(HistoryDeviceIdentity.current(platform: "mac", storage: ids, defaults: defaults), ids.stored,
                       "no salt: the stored name, unchanged")
    }

    /// N1: the router's flush drains the shared store's queued save and the bookmark it queues.
    func testFlushPendingWritesPutsSharedHistoryOnDisk() throws {
        let url = try file(documents.appendingPathComponent("d.md"))
        let store = router()
        let saved = history()
        store.save(saved, for: url)
        store.flushPendingWrites()
        XCTAssertEqual(sharedFolders().count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bookmarksURL().path))
        XCTAssertEqual(router("iphone-B").load(for: url), saved)
    }

    // MARK: - Container lookups (Minor 2)

    func testNoContainerLookupOnLoadOrSave() throws {
        let provider = Flag()
        let store = router(provider: provider)
        let shared = try file(documents.appendingPathComponent("s.md"))
        let local = try file(outside.appendingPathComponent("l.md"))
        for url in [shared, local] {
            store.saveAndWait(history(), for: url)
            _ = store.load(for: url)
            store.saveAndWait(DocumentHistory(passages: []), for: url)
        }
        store.retarget(from: shared, to: documents.appendingPathComponent("t.md"))
        store.waitForBackgroundWork()
        XCTAssertEqual(provider.calls, 0)
        // A shared store was used this session: its prune needs no lookup.
        store.prune(now: clock.now)
        XCTAssertEqual(provider.calls, 0)
    }

    /// A Mac that never used the Lineform iCloud folder never sets the container up; one whose
    /// sidecar shows shared History looks it up once, at prune.
    func testPruneLooksTheContainerUpOnlyWhenThisDeviceHasSharedHistory() throws {
        let never = Flag()
        let local = try file(outside.appendingPathComponent("l.md"))
        let localOnly = router(provider: never)
        localOnly.saveAndWait(history(), for: local)
        localOnly.prune(now: clock.now)
        XCTAssertEqual(never.calls, 0)

        let shared = try file(documents.appendingPathComponent("s.md"))
        router().saveAndWait(history(), for: shared)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bookmarksURL().path))
        let once = Flag()
        router(provider: once).prune(now: clock.now)
        XCTAssertEqual(once.calls, 1)
    }

    // MARK: - Minor 3: Clear History reaches every store and survives a relaunch

    /// The container is not reachable at Clear History: the clear date is kept, and a relaunched
    /// router drops the cleared History and writes the marker at its first shared use.
    func testClearWithoutTheContainerSurvivesARelaunch() throws {
        let url = try file(documents.appendingPathComponent("d.md"))
        router("mac-A").saveAndWait(history(["Old 1", "Old 2"]), for: url)
        clock.advance(10)
        let offline = router("mac-A", reachable: false)
        offline.clearAll()
        offline.waitForBackgroundWork()
        XCTAssertFalse(FileManager.default.fileExists(atPath: container.appendingPathComponent("History/v1/Cleared/mac-A.json").path))

        let relaunched = router("mac-A")
        XCTAssertEqual(relaunched.load(for: url), DocumentHistory(passages: []))
        relaunched.waitForBackgroundWork()
        XCTAssertTrue(FileManager.default.fileExists(atPath: container.appendingPathComponent("History/v1/Cleared/mac-A.json").path))
        XCTAssertEqual(router("iphone-B").load(for: url), DocumentHistory(passages: []))
        // Written once: a later relaunch does not clear again (History made since stays).
        clock.advance(10)
        let fresh = history(["New 1", "New 2"])
        relaunched.saveAndWait(fresh, for: url)
        XCTAssertEqual(router("mac-A").load(for: url), fresh)
    }

    /// Every shared store used this session is cleared, even when the container lookup fails.
    func testClearReachesEveryStoreUsedThisSession() throws {
        let url = try file(documents.appendingPathComponent("d.md"))
        let store = router("mac-A", reachable: false)
        store.saveAndWait(history(), for: url)
        clock.advance(1)
        store.clearAll()
        store.waitForBackgroundWork()
        XCTAssertEqual(sharedFolders(), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: container.appendingPathComponent("History/v1/Cleared/mac-A.json").path))
    }

    // MARK: - Minor 4: one store per container

    func testOneStorePerContainerHoweverItIsSpelled() throws {
        let link = root.appendingPathComponent("Link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: container)
        let viaLink = link.appendingPathComponent("Documents/d.md")
        let store = RoutingPassageHistoryStore(
            local: FilePassageHistoryStore(directory: localDirectory("mac-A")),
            classify: { [container = container!, link] url in
                let path = url.path
                if path.hasPrefix(link.path + "/Documents/") {
                    return .shared(container: link, relativePath: String(path.dropFirst(link.path.count + "/Documents/".count)))
                }
                return HistoryLocation.classify(url)
            },
            containerProvider: { [container = container!] in container },
            bookmarkDirectory: localDirectory("mac-A").deletingLastPathComponent().appendingPathComponent("HistoryShared"),
            makeShared: { [clock] c in SharedPassageHistoryStore(containerURL: c, device: "mac-A", now: { clock.now }) },
            now: { [clock] in clock.now })
        _ = try file(documents.appendingPathComponent("d.md"))
        store.save(history(), for: viaLink)
        _ = store.load(for: documents.appendingPathComponent("d.md"))
        XCTAssertEqual(store.sharedStoreCount, 1)
    }

    // MARK: - D5 and Minor 7: nothing is deleted before its new copy is written

    /// The shared write fails: the local History stays, and migrates at a later load.
    func testLocalHistoryStaysWhenTheSharedWriteFails() throws {
        let url = try file(documents.appendingPathComponent("d.md"))
        let saved = history()
        FilePassageHistoryStore(directory: localDirectory("mac-A")).save(saved, for: url)
        let sharedRoot = container.appendingPathComponent("History/v1/Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: sharedRoot, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: sharedRoot.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sharedRoot.path) }

        let store = router()
        XCTAssertEqual(store.load(for: url), saved)
        store.waitForBackgroundWork()
        XCTAssertEqual(localIndexPaths(), [FileIdentity.key(for: url)], "kept: the shared copy was not written")
        XCTAssertEqual(sharedFolders(), [])

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sharedRoot.path)
        XCTAssertEqual(store.load(for: url), saved)
        store.waitForBackgroundWork()
        XCTAssertEqual(localIndexPaths(), [])
        XCTAssertEqual(router("iphone-B").load(for: url), saved)
    }

    /// Out of the container with a local write that fails: the shared folder stays.
    func testMoveOutOfICloudKeepsSharedHistoryWhenTheLocalSaveFails() throws {
        let old = try file(documents.appendingPathComponent("a.md"))
        let new = outside.appendingPathComponent("a.md")
        let store = router()
        store.saveAndWait(history(), for: old)
        let localRoot = localDirectory("mac-A")
        try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: localRoot.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: localRoot.path) }
        try FileManager.default.moveItem(at: old, to: new)
        store.retarget(from: old, to: new)
        store.waitForBackgroundWork()
        XCTAssertEqual(sharedFolders().count, 1)
    }

    // MARK: - Minor 6: the bookmark sidecar shrinks

    func testSidecarDropsEntriesWhoseHistoryIsGone() throws {
        let url = try file(documents.appendingPathComponent("d.md"))
        let store = router()
        store.saveAndWait(history(), for: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bookmarksURL().path))
        // Another device cleared it (or it was pruned there): nothing left to carry.
        try FileManager.default.removeItem(at: container.appendingPathComponent("History"))
        store.prune(now: clock.now)
        store.waitForBackgroundWork()
        XCTAssertFalse(FileManager.default.fileExists(atPath: bookmarksURL().path))
    }

    // MARK: - Moving out with records iCloud has not downloaded

    /// What a fake iCloud "downloads" for a waiting read: the bytes of a record by its logical
    /// file name, while `available`; nil (a timeout) otherwise.
    final class FakeICloud: @unchecked Sendable {
        private let lock = NSLock()
        private var records: [String: Data] = [:]
        private var isAvailable: Bool
        private var fetchedNames: [String] = []
        init(available: Bool) { isAvailable = available }
        var fetched: [String] { lock.lock(); defer { lock.unlock() }; return fetchedNames }
        func hold(_ data: Data, as name: String) { lock.lock(); records[name] = data; lock.unlock() }
        func setAvailable(_ value: Bool) { lock.lock(); isAvailable = value; lock.unlock() }
        func fetch(_ url: URL) -> Data? {
            lock.lock(); defer { lock.unlock() }
            fetchedNames.append(url.lastPathComponent)
            return isAvailable ? records[url.lastPathComponent] : nil
        }
    }

    private func iCloudRouter(_ device: String, fetch: @escaping @Sendable (URL) -> Data?) -> RoutingPassageHistoryStore {
        let clock = clock, container = container!
        return RoutingPassageHistoryStore(
            local: FilePassageHistoryStore(directory: localDirectory(device), isConfirmedMissing: { _ in false }),
            containerProvider: { container },
            bookmarkDirectory: localDirectory(device).deletingLastPathComponent().appendingPathComponent("HistoryShared"),
            makeShared: { c in SharedPassageHistoryStore(
                containerURL: c, device: device, now: { clock.now }, isConfirmedMissing: { _ in false },
                isDownloaded: { _ in true }, conflicts: .none, fetchWaiting: fetch) },
            now: { clock.now })
    }

    private func sharedFolder(_ relativePath: String) -> URL {
        container.appendingPathComponent("History/v1/Documents")
            .appendingPathComponent(SharedPassageHistoryStore.key(for: relativePath))
    }

    /// The Mac's record of `url`, evicted on this iPhone: only `.mac-A.json.icloud` is listed; its
    /// bytes are what `iCloud` "downloads".
    private func evictedMacRecord(for url: URL, _ saved: DocumentHistory, iCloud: FakeICloud) throws {
        router("mac-A").saveAndWait(saved, for: url)
        let folder = sharedFolder(url.lastPathComponent)
        let record = folder.appendingPathComponent("mac-A.json")
        iCloud.hold(try Data(contentsOf: record), as: "mac-A.json")
        try FileManager.default.removeItem(at: record)
        try Data("stub".utf8).write(to: folder.appendingPathComponent(".mac-A.json.icloud"))
    }

    private func passageIDs(_ history: DocumentHistory) -> Set<UUID> { Set(history.passages.map(\.id)) }

    func testMoveOutDownloadsAStubRecordBeforeDeletingTheSharedFolder() throws {
        let old = try file(documents.appendingPathComponent("a.md"))
        let new = outside.appendingPathComponent("a.md")
        let iCloud = FakeICloud(available: true)
        let mac = history(["Mac 1", "Mac 2"]), phone = history(["Phone 1", "Phone 2"])
        try evictedMacRecord(for: old, mac, iCloud: iCloud)
        let store = iCloudRouter("iphone-B") { url in iCloud.fetch(url) }
        store.saveAndWait(phone, for: old)
        // What this iPhone can see before the move: its own passage only (the Mac's is a stub).
        XCTAssertEqual(passageIDs(store.load(for: old)), passageIDs(phone))

        try FileManager.default.moveItem(at: old, to: new)
        store.retarget(from: old, to: new)
        store.waitForBackgroundWork()

        XCTAssertEqual(iCloud.fetched, ["mac-A.json"], "the stub is read by its logical name")
        XCTAssertEqual(passageIDs(store.load(for: new)), passageIDs(mac).union(passageIDs(phone)))
        XCTAssertEqual(sharedFolders(), [], "every record was read: the shared folder goes")
    }

    func testMoveOutKeepsTheSharedFolderWhileARecordCannotBeDownloaded() throws {
        let old = try file(documents.appendingPathComponent("a.md"))
        let new = outside.appendingPathComponent("a.md")
        let iCloud = FakeICloud(available: false)
        let mac = history(["Mac 1", "Mac 2"]), phone = history(["Phone 1", "Phone 2"])
        try evictedMacRecord(for: old, mac, iCloud: iCloud)
        let store = iCloudRouter("iphone-B") { url in iCloud.fetch(url) }
        store.saveAndWait(phone, for: old)

        try FileManager.default.moveItem(at: old, to: new)
        store.retarget(from: old, to: new)
        store.waitForBackgroundWork()

        // Offline: what could be read is local now, and nothing was deleted.
        XCTAssertEqual(passageIDs(store.load(for: new)), passageIDs(phone))
        XCTAssertEqual(sharedFolders().count, 1)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: sharedFolder("a.md").appendingPathComponent(".mac-A.json.icloud").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bookmarksURL("iphone-B").path), "kept for the retry")

        // Back online: the session's next prune follows the bookmark and finishes the move.
        iCloud.setAvailable(true)
        store.prune(now: clock.now)
        store.waitForBackgroundWork()
        XCTAssertEqual(passageIDs(store.load(for: new)), passageIDs(mac).union(passageIDs(phone)))
        XCTAssertEqual(sharedFolders(), [])
    }

    func testMoveOutNeverWaitsOnTheCallersThread() throws {
        let old = try file(documents.appendingPathComponent("a.md"))
        let new = outside.appendingPathComponent("a.md")
        let gate = DispatchSemaphore(value: 0)
        let iCloud = FakeICloud(available: true)
        try evictedMacRecord(for: old, history(["Mac 1", "Mac 2"]), iCloud: iCloud)
        let store = iCloudRouter("iphone-B") { _ in gate.wait(); return nil }
        try FileManager.default.moveItem(at: old, to: new)
        let start = Date()
        store.retarget(from: old, to: new)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1, "the download wait is on the move queue")
        gate.signal()
        store.waitForBackgroundWork()
        XCTAssertEqual(sharedFolders().count, 1, "a record that timed out is never deleted")
    }

    func testMoveOutPostsTheDownloadedHistoryForTheOpenDocument() throws {
        let old = try file(documents.appendingPathComponent("a.md"))
        let new = outside.appendingPathComponent("a.md")
        let iCloud = FakeICloud(available: true)
        let mac = history(["Mac 1", "Mac 2"])
        try evictedMacRecord(for: old, mac, iCloud: iCloud)
        let store = iCloudRouter("iphone-B") { url in iCloud.fetch(url) }
        let posted = expectation(forNotification: RoutingPassageHistoryStore.didMoveHistoryOutNotification, object: store) { note in
            let history = note.userInfo?[RoutingPassageHistoryStore.movedHistoryKey] as? DocumentHistory
            return note.userInfo?[RoutingPassageHistoryStore.movedHistoryURLKey] as? URL == new
                && history.map { Set($0.passages.map(\.id)) } == Set(mac.passages.map(\.id))
        }
        try FileManager.default.moveItem(at: old, to: new)
        store.retarget(from: old, to: new)
        wait(for: [posted], timeout: 5)
    }
}

private extension RoutingPassageHistoryStore {
    func saveAndWait(_ history: DocumentHistory, for url: URL) {
        save(history, for: url)
        waitForBackgroundWork()
    }
}
