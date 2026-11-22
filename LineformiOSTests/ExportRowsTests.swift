import LineformCore
import UIKit
import XCTest
@testable import LineformiOS

/// The Menu sheet's export rows: their strings in every language, Share's availability, the
/// read-aloud titles for each state, the share sheet's items, the failure notice, and the
/// document-swap hook that stops read aloud.
@MainActor
final class ExportRowsTests: XCTestCase {
    private var root: URL!
    private var folder: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-rows-\(UUID().uuidString)", isDirectory: true)
        folder = root.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func preparedDocument() async -> OpenDocument {
        let folder = self.folder!
        let document = OpenDocument(folderProvider: { folder })
        await document.prepare(restoringStoredPath: "")
        return document
    }

    private func commands(
        _ document: OpenDocument,
        synthesizer: PhoneFakeSpeechSynthesizer = PhoneFakeSpeechSynthesizer(),
        writer: PhoneExportWriter? = nil
    ) -> ExportCommands {
        ExportCommands(
            document: document,
            profile: { .original },
            writer: writer ?? PhoneExportWriter(folder: root.appendingPathComponent("Exports", isDirectory: true)),
            speech: SpeechController(synthesizer: synthesizer),
            regionCode: "US",
            audioSession: PhoneFakeSpeechAudioSession()
        )
    }

    // MARK: - Strings

    /// Every English key the rows show (the paper names come from the package's catalog).
    private static let catalogKeys = [
        "Export As", "Paper Size", "Print\u{2026}", "Share\u{2026}",
        "HTML", "PDF", "Styled PDF", "Rich Text (.rtf)",
        "Start Speaking", "Pause Speaking", "Resume Speaking", "Stop Speaking",
    ]

    func testRowTitlesComeFromCatalogInAllLanguages() throws {
        let missing = "\u{1}missing\u{1}"
        for language in ["es", "fr", "de", "ja", "zh-Hans"] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"), "\(language).lproj")
            let bundle = try XCTUnwrap(Bundle(path: path))
            for key in Self.catalogKeys {
                let value = bundle.localizedString(forKey: key, value: missing, table: nil)
                XCTAssertNotEqual(value, missing, "\(key) has no \(language) translation")
                XCTAssertFalse(value.isEmpty, "\(key) is empty in \(language)")
            }
        }
        for format in PhoneExportFormat.allCases {
            XCTAssertTrue(Self.catalogKeys.contains(format.title), "\(format) title is a catalog key")
        }
        for title in ExportRows.speechTitles(for: .idle) + ExportRows.speechTitles(for: .speaking)
            + ExportRows.speechTitles(for: .paused) {
            XCTAssertTrue(Self.catalogKeys.contains(title), "\(title) is a catalog key")
        }
    }

    // MARK: - Share

    func testShareRowDisabledWithoutFile() async {
        let document = await preparedDocument()
        let commands = commands(document)
        XCTAssertTrue(ExportRows.isShareDisabled(commands), "an empty Untitled document has no file")

        document.edit("Something to share.")
        XCTAssertFalse(ExportRows.isShareDisabled(commands), "typed text gets a file on the next save")
    }

    func testShareSheetItemIsFileURL() throws {
        let file = root.appendingPathComponent("Notes.pdf")
        try Data("x".utf8).write(to: file)
        let sheet = ActivityShareSheet(fileURL: file, onComplete: {})

        let items = sheet.activityItems
        XCTAssertEqual(items.count, 1)
        let url = try XCTUnwrap(items.first as? URL)
        XCTAssertTrue(url.isFileURL)
        XCTAssertEqual(url, file)
    }

    /// A share sheet UIKit would refuse (the top controller already presents, or is going away)
    /// is not presented: its completion would never run, and the copy would linger.
    func testShareSheetIsNotPresentedOnABusyController() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let root = UIViewController()
        window.rootViewController = root
        window.isHidden = false
        defer { window.isHidden = true }
        XCTAssertTrue(ActivityShareSheet.canPresent(on: root))

        root.present(UIViewController(), animated: false)
        XCTAssertNotNil(root.presentedViewController)
        XCTAssertFalse(ActivityShareSheet.canPresent(on: root), "a controller that already presents refuses another")
        root.dismiss(animated: false)
    }

    func testFinishedShareRemovesTheExports() async throws {
        let document = await preparedDocument()
        let exports = root.appendingPathComponent("Exports", isDirectory: true)
        let commands = commands(document, writer: PhoneExportWriter(folder: exports))
        document.edit("Exported words.")

        let exported = await commands.exportForSharing(.html)
        let url = try XCTUnwrap(exported)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        commands.removeExports()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "the share sheet's copy is cleaned up")
    }

    func testExportFailureShowsTheCalmNotice() async throws {
        let document = await preparedDocument()
        // A file where the export folder should be: nothing can be written under it.
        let blocked = root.appendingPathComponent("Blocked")
        try Data("not a folder".utf8).write(to: blocked)
        let commands = commands(document, writer: PhoneExportWriter(folder: blocked))
        document.edit("Words that will not export.")

        let url = await commands.exportForSharing(.html)

        XCTAssertNil(url)
        let name = commands.documentBaseName
        XCTAssertEqual(commands.failureNotice, ExportCommands.ExportFailure.writeFailed.message(documentName: name))
    }

    // MARK: - Read aloud

    func testSpeechRowTitleFollowsState() {
        XCTAssertEqual(ExportRows.speechTitles(for: .idle), ["Start Speaking"])
        XCTAssertEqual(ExportRows.speechTitles(for: .speaking), ["Pause Speaking", "Stop Speaking"])
        XCTAssertEqual(ExportRows.speechTitles(for: .paused), ["Resume Speaking", "Stop Speaking"])
    }

    func testDocumentSwapStopsReadAloud() async {
        let document = await preparedDocument()
        let synthesizer = PhoneFakeSpeechSynthesizer()
        let commands = commands(document, synthesizer: synthesizer)
        var swaps = 0
        document.onDocumentSwap = {
            swaps += 1
            commands.documentWillChange()
        }
        document.edit("Read this aloud, please.")
        commands.startReadingAloud(selection: nil, mode: .write)
        XCTAssertEqual(commands.speechState, .speaking)

        await document.newDocument()

        XCTAssertEqual(swaps, 1, "New Document swaps the document")
        XCTAssertEqual(commands.speechState, .idle, "the previous document is no longer read")
    }
}
