import LineformCore
import XCTest
@testable import LineformiOS

/// Opening files and live reload. Every test works in its own temporary folder; none touches the
/// app's Documents folder or an iCloud container.
@MainActor
final class OpenDocumentTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-document-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testOpeningAFileShowsItsText() async throws {
        let url = try write("# Notes\r\nSecond line", named: "Notes.md")
        let document = makeDocument()

        try await document.open(url)

        XCTAssertEqual(document.url, url)
        XCTAssertEqual(document.text, "# Notes\r\nSecond line", "CRLF is kept as it is")
        XCTAssertEqual(document.lastSyncedText, document.text)
    }

    func testOpeningKeepsALeadingByteOrderMark() async throws {
        let url = folder.appendingPathComponent("BOM.md")
        try (Data([0xEF, 0xBB, 0xBF]) + Data("Hi".utf8)).write(to: url)
        let document = makeDocument()

        try await document.open(url)

        XCTAssertEqual(document.text, "\u{FEFF}Hi")
    }

    func testExternalWriteReloadsWhenClean() async throws {
        let url = try write("Before", named: "Shared.md")
        let document = makeDocument()
        try await document.open(url)

        try coordinatedWrite("After, from another device", to: url)
        let outcome = await document.applyExternalChange()

        XCTAssertEqual(outcome, .reload)
        XCTAssertEqual(document.text, "After, from another device")
        XCTAssertEqual(document.lastSyncedText, "After, from another device")
    }

    func testExternalWriteKeepsLocalEdits() async throws {
        let url = try write("Before", named: "Shared.md")
        let document = makeDocument()
        try await document.open(url)
        document.edit("Before, and my local edit")

        try coordinatedWrite("Their edit", to: url)
        let outcome = await document.applyExternalChange()

        XCTAssertEqual(outcome, .ignoreDirty)
        XCTAssertEqual(document.text, "Before, and my local edit")
    }

    /// The file presenter alone (no explicit call) brings an external write in.
    func testExternalWriteReloadsLiveThroughTheWatcher() async throws {
        let url = try write("Before", named: "Live.md")
        let document = makeDocument()
        try await document.open(url)

        try coordinatedWrite("After", to: url)

        let deadline = Date().addingTimeInterval(3)
        while document.text != "After", Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(document.text, "After")
    }

    func testOpenedFileIsNeverAutoRenamed() async throws {
        let url = try write("# Old title", named: "Kept Name.md")
        let document = makeDocument()
        XCTAssertTrue(document.isNamedFromFirstLine, "a new document is named from its first line")

        try await document.open(url)

        XCTAssertFalse(document.isNamedFromFirstLine)
    }

    func testInvalidUTF8FileIsRefused() async throws {
        let good = try write("Good text", named: "Good.md")
        let bad = folder.appendingPathComponent("Bad.md")
        try Data([0x48, 0xFF, 0xFE, 0x49]).write(to: bad)
        let document = makeDocument()
        try await document.open(good)

        do {
            try await document.open(bad)
            XCTFail("an invalid UTF-8 file is refused")
        } catch {
            XCTAssertEqual(error as? OpenDocument.OpenError, .unreadable(bad))
        }

        XCTAssertEqual(document.url, good, "the current document stays")
        XCTAssertEqual(document.text, "Good text")
        XCTAssertEqual(try Data(contentsOf: bad), Data([0x48, 0xFF, 0xFE, 0x49]), "the bad file is untouched")
    }

    /// A reload replaces the editor's text without throwing the caret to the end.
    func testReloadedTextKeepsTheEditorSelection() {
        let textView = LineformTextView.make(profile: .original)
        textView.setDocumentText("Hello world")
        textView.selectedRange = NSRange(location: 5, length: 0)

        textView.setDocumentText("Hello there, world")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 5, length: 0))

        textView.setDocumentText("Hi")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 2, length: 0), "clamped to the new text")
    }

    // MARK: - File names

    func testAnICloudPlaceholderStandsForItsFile() {
        XCTAssertEqual(OutlineFileScanner.realName(ofEntry: ".Notes.md.icloud"), "Notes.md")
        XCTAssertNil(OutlineFileScanner.realName(ofEntry: ".DS_Store"))
        XCTAssertEqual(OutlineFileScanner.realName(ofEntry: "Notes.md"), "Notes.md")
        XCTAssertEqual(OpenDocument.realURL(for: folder.appendingPathComponent(".Notes.md.icloud")).lastPathComponent, "Notes.md")
    }

    // MARK: - Reading off the main thread, and iCloud downloads

    func testOpeningReadsOffTheMainThread() async throws {
        let url = try write("Read elsewhere", named: "Off main.md")
        let reader = GatedReader()
        let document = OpenDocument(folderProvider: { [folder] in folder! }, reader: reader)

        try await document.open(url)

        XCTAssertEqual(document.text, "Read elsewhere")
        XCTAssertGreaterThan(reader.readCount, 0, "opening goes through the injected reader")
        XCTAssertEqual(reader.readsOnTheMainThread, 0)
    }

    /// A file iCloud has not downloaded yet: the download starts on the real file, the screen
    /// shows the downloading state, and the text opens once the file is current.
    func testOpeningAPlaceholderDownloadsTheFileFirst() async throws {
        try write("", named: ".Cloud.md.icloud")
        let real = folder.appendingPathComponent("Cloud.md")
        let cloud = FakeUbiquitousItems(pending: [real], arrivingText: "From iCloud")
        let document = makeDocument(ubiquitousItems: cloud)
        document.edit("Typed before")

        let opening = Task { try await document.open(folder.appendingPathComponent(".Cloud.md.icloud")) }
        try await waitUntil { document.downloadingName == "Cloud.md" }
        XCTAssertEqual(document.text, "", "the downloading state stands in place of the text")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("Typed before.md"), encoding: .utf8),
                       "Typed before", "the document put away was saved first")
        try await opening.value

        XCTAssertEqual(cloud.startedURLs, [real], "the download is started on the real file")
        XCTAssertNil(document.downloadingName)
        XCTAssertEqual(document.url, real)
        XCTAssertEqual(document.text, "From iCloud")
    }

    /// Offline, a file with a full but outdated local copy opens that copy at once; the download
    /// keeps running, and live reload brings the current version in when it arrives.
    func testOutdatedLocalCopyOpensAtOnceAndReloadsWhenCurrentArrives() async throws {
        let url = try write("Local copy", named: "Outdated.md")
        let cloud = FakeUbiquitousItems(outdated: [url], arrivingText: "Current version")
        let document = makeDocument(ubiquitousItems: cloud)
        var sawDownloading = false
        let observer = Task { @MainActor in
            while !Task.isCancelled {
                if document.downloadingName != nil { sawDownloading = true }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }

        try await document.open(url)

        XCTAssertEqual(document.text, "Local copy", "the local copy opens without waiting")
        XCTAssertEqual(document.url, url)
        try await waitUntil { cloud.startedURLs == [url] }
        try await waitUntil { document.text == "Current version" }
        observer.cancel()
        XCTAssertFalse(sawDownloading, "no downloading state for a file with a local copy")
        XCTAssertEqual(document.lastSyncedText, "Current version")
    }

    /// A file with a local copy opens without waiting for iCloud's status: that lookup (about
    /// 0.3 s on a session's first open) ran before every switch. Here it is held, and the open
    /// still finishes; released, it finds the copy outdated and the current version comes in.
    func testLocalCopyOpensWithoutWaitingForTheICloudStatus() async throws {
        let url = try write("Local copy", named: "Fast.md")
        let cloud = FakeUbiquitousItems(outdated: [url], arrivingText: "Current version", hold: .firstStateCheck)
        let document = makeDocument(ubiquitousItems: cloud)

        try await document.open(url)

        XCTAssertEqual(document.text, "Local copy", "the open did not wait for the iCloud status")
        try await waitUntil { cloud.isHolding }
        XCTAssertEqual(cloud.startedURLs, [], "nothing is downloaded before the status is known")
        cloud.release()
        try await waitUntil { cloud.startedURLs == [url] }
        try await waitUntil { document.text == "Current version" }
    }

    func testNewDocumentWhileDownloadingCancelsTheOpen() async throws {
        let real = folder.appendingPathComponent("Never.md")
        let cloud = FakeUbiquitousItems(pending: [real], arrivingText: nil)
        let document = makeDocument(ubiquitousItems: cloud)

        let opening = Task { try await document.open(real) }
        try await waitUntil { document.downloadingName != nil }
        await document.newDocument()

        do {
            try await opening.value
            XCTFail("the open was superseded")
        } catch {
            XCTAssertEqual(error as? OpenDocument.OpenError, .superseded)
        }
        XCTAssertNil(document.downloadingName)
        XCTAssertNil(document.url)
    }

    /// The current version lands while the open is still reading the outdated local copy. The
    /// open watches the file before it asks for the download, so that version is never missed.
    func testCurrentVersionArrivingWhileOpeningIsNotMissed() async throws {
        let url = try write("Local copy", named: "Racing.md")
        let cloud = FakeUbiquitousItems(outdated: [url], arrivingText: "Current version", deliversImmediately: true)
        let reader = GatedReader()
        let document = OpenDocument(folderProvider: { [folder] in folder! }, reader: reader, ubiquitousItems: cloud)
        reader.holdNextRead()

        let opening = Task { try await document.open(url) }
        try await waitUntil { reader.isHolding }
        // If the download were already running, the new version would land here, unwatched.
        try await Task.sleep(for: .milliseconds(200))
        reader.release()
        try await opening.value

        try await waitUntil { document.text == "Current version" }
        XCTAssertEqual(document.lastSyncedText, "Current version")
        XCTAssertEqual(cloud.startedURLs, [url])
    }

    /// A download request that fails after a newer action took over is reported as superseded,
    /// not as the file being unreadable.
    func testDownloadFailureAfterSupersedingIsSuperseded() async throws {
        let real = folder.appendingPathComponent("Fails.md")
        let cloud = FakeUbiquitousItems(pending: [real], arrivingText: nil, failsToStart: true, hold: .startDownloading)
        let document = makeDocument(ubiquitousItems: cloud)

        let opening = Task { try await document.open(real) }
        try await waitUntil { cloud.isHolding }
        await document.newDocument()
        cloud.release()

        do {
            try await opening.value
            XCTFail("the open was superseded")
        } catch {
            XCTAssertEqual(error as? OpenDocument.OpenError, .superseded)
        }
        XCTAssertNil(document.downloadingName)
    }

    // MARK: - Moved elsewhere

    /// Files or iCloud renames the open file: the document follows it, stays attached, and the
    /// next save goes to the new path without leaving a copy at the old one.
    func testExternalCoordinatedMoveIsFollowed() async throws {
        let url = try write("Moving text", named: "Before.md")
        let document = makeDocument()
        try await document.open(url)
        let destination = folder.appendingPathComponent("After.md")

        try coordinatedMove(url, to: destination)
        try await waitUntil { document.url == destination }
        try await Task.sleep(for: .milliseconds(600))

        XCTAssertEqual(document.url, destination, "still attached after the move settles")
        XCTAssertEqual(document.text, "Moving text")
        document.edit("Moving text, edited")
        await document.flush()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(), ["After.md"])
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "Moving text, edited")
    }

    // MARK: - Helpers

    private func makeDocument(ubiquitousItems: any UbiquitousItemAccessing = LiveUbiquitousItems()) -> OpenDocument {
        let folder = self.folder!
        return OpenDocument(folderProvider: { folder }, ubiquitousItems: ubiquitousItems)
    }

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 3) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), "timed out")
    }

    /// Moves as Files or iCloud would: through file coordination, announced to presenters.
    private func coordinatedMove(_ source: URL, to destination: URL) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var moveError: Error?
        coordinator.coordinate(
            writingItemAt: source, options: .forMoving,
            writingItemAt: destination, options: .forReplacing,
            error: &coordinationError
        ) { from, to in
            coordinator.item(at: from, willMoveTo: to)
            do {
                try FileManager.default.moveItem(at: from, to: to)
                coordinator.item(at: from, didMoveTo: to)
            } catch { moveError = error }
        }
        if let error = coordinationError ?? moveError { throw error }
    }

    @discardableResult
    private func write(_ text: String, named name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// Writes as another app or iCloud would: through file coordination, with no presenter.
    private func coordinatedWrite(_ text: String, to url: URL) throws {
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: nil)
            .coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { writeURL in
                do { try Data(text.utf8).write(to: writeURL) } catch { writeError = error }
            }
        if let error = coordinationError ?? writeError { throw error }
    }
}

/// Stands in for iCloud. `pending` files have no local copy until a download is started; then,
/// a moment later, the file "arrives" with `arrivingText` (or never, when it is nil). `outdated`
/// files have a full local copy that is not current; when the download is started, the current
/// version arrives as a coordinated write, as iCloud would deliver it: a moment later, or at once
/// with `deliversImmediately`.
///
/// For ordering tests it can hold the first `downloadState` check or the `startDownloading` call
/// until `release()`, and make `startDownloading` throw.
final class FakeUbiquitousItems: UbiquitousItemAccessing, @unchecked Sendable {
    enum Hold { case none, firstStateCheck, startDownloading }

    private let lock = NSLock()
    private var pending: Set<URL>
    private var outdated: Set<URL>
    private var started: [URL] = []
    private let arrivingText: String?
    private let deliversImmediately: Bool
    private let failsToStart: Bool
    private var hold: Hold
    private var holding = false
    private let gate = DispatchSemaphore(value: 0)

    init(
        pending: Set<URL> = [], outdated: Set<URL> = [], arrivingText: String?,
        deliversImmediately: Bool = false, failsToStart: Bool = false, hold: Hold = .none
    ) {
        self.pending = Set(pending.map(\.standardizedFileURL))
        self.outdated = Set(outdated.map(\.standardizedFileURL))
        self.arrivingText = arrivingText
        self.deliversImmediately = deliversImmediately
        self.failsToStart = failsToStart
        self.hold = hold
    }

    var startedURLs: [URL] { lock.withLock { started } }
    var isHolding: Bool { lock.withLock { holding } }
    func release() { gate.signal() }

    /// Waits at the gate once, if `point` is the hold this fake was set up with.
    private func holdIfNeeded(at point: Hold) {
        let shouldHold = lock.withLock { () -> Bool in
            guard hold == point, point != .none else { return false }
            hold = .none
            holding = true
            return true
        }
        guard shouldHold else { return }
        gate.wait()
        lock.withLock { holding = false }
    }

    func downloadState(_ url: URL) -> UbiquitousDownloadState {
        holdIfNeeded(at: .firstStateCheck)
        return lock.withLock {
            let key = url.standardizedFileURL
            if pending.contains(key) { return .notDownloaded }
            if outdated.contains(key) { return .localCopyNotCurrent }
            return .current
        }
    }

    func startDownloading(_ url: URL) throws {
        let wasOutdated = lock.withLock { () -> Bool in
            started.append(url)
            return outdated.contains(url.standardizedFileURL)
        }
        holdIfNeeded(at: .startDownloading)
        if failsToStart { throw CocoaError(.ubiquitousFileUnavailable) }
        guard let arrivingText else { return }
        let deliver = { [self] in
            if wasOutdated {
                var error: NSError?
                NSFileCoordinator(filePresenter: nil)
                    .coordinate(writingItemAt: url, options: .forReplacing, error: &error) { writeURL in
                        try? Data(arrivingText.utf8).write(to: writeURL)
                    }
                _ = lock.withLock { outdated.remove(url.standardizedFileURL) }
                return
            }
            try? Data(arrivingText.utf8).write(to: url)
            let placeholder = url.deletingLastPathComponent()
                .appendingPathComponent("." + url.lastPathComponent + ".icloud")
            try? FileManager.default.removeItem(at: placeholder)
            _ = lock.withLock { pending.remove(url.standardizedFileURL) }
        }
        if deliversImmediately {
            deliver()
        } else {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { deliver() }
        }
    }
}
