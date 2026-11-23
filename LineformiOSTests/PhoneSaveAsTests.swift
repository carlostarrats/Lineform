import Foundation
import LineformCore
import XCTest
@testable import LineformiOS

/// Save As in the Menu sheet's Document section: `OpenDocument.prepareSaveAs` stages a copy of the
/// text's exact bytes, the export picker places it, and `adoptSaveAs` moves the document to the
/// new file. The picker's copy is simulated with a file copy; every folder is temporary.
@MainActor
final class PhoneSaveAsTests: XCTestCase {
    private var root: URL!
    private var saveFolder: URL!
    private var destinationFolder: URL!
    private var stagingFolder: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("save-as-\(UUID().uuidString)", isDirectory: true)
        saveFolder = root.appendingPathComponent("Lineform", isDirectory: true)
        destinationFolder = root.appendingPathComponent("Elsewhere", isDirectory: true)
        stagingFolder = root.appendingPathComponent("Staging", isDirectory: true)
        for folder in [saveFolder!, destinationFolder!] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Retargeting

    func testSaveAsMovesTheDocumentAndLeavesTheOldFileAsItWas() async throws {
        let original = saveFolder.appendingPathComponent("Draft.md")
        try Data("# Draft\n\nFirst version.\n".utf8).write(to: original)
        let document = await preparedDocument()
        try await document.open(original)
        document.edit("# Draft\n\nSecond version.\n")

        let copy = try await stagedCopy(of: document)
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "# Draft\n\nSecond version.\n",
                       "the pending text is saved first, as every Save As does")
        XCTAssertEqual(copy.url.lastPathComponent, "Draft.md", "the copy carries the file's name")

        let destination = try place(copy)
        XCTAssertTrue(document.adoptSaveAs(copy, at: destination))
        XCTAssertEqual(document.url, destination)
        XCTAssertEqual(document.lastSyncedText, document.text, "the new file holds the text")
        XCTAssertFalse(document.isNamedFromFirstLine, "the writer chose the name")

        // Autosave continues at the new file; the old one keeps what it had.
        document.edit("# Renamed heading\n\nThird version.\n")
        let ok = await document.flush()
        XCTAssertTrue(ok)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "# Renamed heading\n\nThird version.\n")
        XCTAssertEqual(document.url, destination, "editing the first line never renames a Save As file")
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "# Draft\n\nSecond version.\n")
        XCTAssertEqual(document.documentDirectory, destination.deletingLastPathComponent(), "images resolve beside the new file")
    }

    func testSaveAsKeepsABOMAndCRLFByteForByte() async throws {
        let bytes = Data("\u{FEFF}# Notes\r\n\r\nLine one.\r\nLine two.\r\n".utf8)
        let original = saveFolder.appendingPathComponent("Notes.md")
        try bytes.write(to: original)
        let document = await preparedDocument()
        try await document.open(original)

        let copy = try await stagedCopy(of: document)
        XCTAssertEqual(try Data(contentsOf: copy.url), bytes, "the staged copy is the file's exact bytes")

        let destination = try place(copy)
        document.adoptSaveAs(copy, at: destination)
        XCTAssertEqual(try Data(contentsOf: destination), bytes)

        document.edit(document.text + "Line three.\r\n")
        let ok = await document.flush()
        XCTAssertTrue(ok)
        XCTAssertEqual(try Data(contentsOf: destination), Data("\u{FEFF}# Notes\r\n\r\nLine one.\r\nLine two.\r\nLine three.\r\n".utf8),
                       "the BOM and CRLF survive the next autosave at the new file")
        XCTAssertEqual(try Data(contentsOf: original), bytes)
    }

    func testTextThatChangedWhileThePickerWasUpSavesToTheNewFile() async throws {
        let document = await preparedDocument()
        document.edit("Morning pages\n\nOne.\n")
        let copy = try await stagedCopy(of: document)
        let destination = try place(copy)

        // A change lands while the picker is up (the screen under it cannot be typed into, but a
        // reload can still arrive).
        document.edit("Morning pages\n\nOne. Two.\n")
        XCTAssertTrue(document.adoptSaveAs(copy, at: destination))
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "Morning pages\n\nOne. Two.\n")
        XCTAssertEqual(document.lastSyncedText, document.text)
    }

    func testSavingOverItsOwnFileKeepsTheDocument() async throws {
        let original = saveFolder.appendingPathComponent("Same.md")
        try Data("Same\n".utf8).write(to: original)
        let document = await preparedDocument()
        try await document.open(original)
        let copy = try await stagedCopy(of: document)

        // The writer picked the file's own folder and chose Replace.
        try FileManager.default.removeItem(at: original)
        try FileManager.default.copyItem(at: copy.url, to: original)
        XCTAssertTrue(document.adoptSaveAs(copy, at: original))
        XCTAssertEqual(document.url, original)
        document.edit("Same, edited\n")
        let ok = await document.flush()
        XCTAssertTrue(ok)
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "Same, edited\n")
    }

    // MARK: - Untitled

    func testAnUntitledDocumentSavesFirst() async throws {
        let document = await preparedDocument()
        XCTAssertFalse(document.canSaveAs, "nothing typed: no file to come, the row is off")
        let blank = await document.prepareSaveAs(stagingFolder: stagingFolder)
        XCTAssertNil(blank)
        document.edit("  \n\n")
        XCTAssertFalse(document.canSaveAs, "spaces and Returns name nothing")

        document.edit("Grocery list\n\n- eggs\n")
        XCTAssertTrue(document.canSaveAs)
        XCTAssertNil(document.url)
        let copy = try await stagedCopy(of: document)
        let saved = try XCTUnwrap(document.url, "the Untitled document got its file first")
        XCTAssertEqual(saved.lastPathComponent, "Grocery list.md")
        XCTAssertEqual(copy.url.lastPathComponent, "Grocery list.md")
        XCTAssertEqual(try String(contentsOf: copy.url, encoding: .utf8), "Grocery list\n\n- eggs\n")

        let destination = try place(copy)
        document.adoptSaveAs(copy, at: destination)
        XCTAssertEqual(document.url, destination)
        XCTAssertFalse(document.isNamedFromFirstLine)
    }

    // MARK: - Cancel and supersession

    func testACancelledPickerChangesNothing() async throws {
        let original = saveFolder.appendingPathComponent("Kept.md")
        try Data("Kept\n".utf8).write(to: original)
        let document = await preparedDocument()
        try await document.open(original)
        let copy = try await stagedCopy(of: document)

        var results: [URL?] = []
        let picker = SaveAsPicker(copyURL: copy.url) { results.append($0) }
        let controller = picker.makeController()
        picker.documentPickerWasCancelled(controller)
        picker.documentPickerWasCancelled(controller)
        XCTAssertEqual(results, [nil], "a cancel is delivered once")

        // The section's cancel path: the staging goes, the document stays.
        SaveAsStaging.removeAll(in: stagingFolder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingFolder.path))
        XCTAssertEqual(document.url, original)
        XCTAssertFalse(document.isNamedFromFirstLine)
        document.edit("Kept, edited\n")
        let ok = await document.flush()
        XCTAssertTrue(ok)
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "Kept, edited\n")
    }

    func testThePickerDeliversThePickedFile() throws {
        let staged = root.appendingPathComponent("x.md")
        try Data("x\n".utf8).write(to: staged)
        var results: [URL?] = []
        let picker = SaveAsPicker(copyURL: staged) { results.append($0) }
        let controller = picker.makeController()
        XCTAssertTrue(controller.delegate === picker)
        let picked = destinationFolder.appendingPathComponent("x.md")
        picker.documentPicker(controller, didPickDocumentsAt: [picked])
        picker.documentPickerWasCancelled(controller)
        XCTAssertEqual(results, [picked])
    }

    func testSaveAsAfterAnotherDocumentTookOverDoesNothing() async throws {
        let document = await preparedDocument()
        document.edit("First note\n")
        let copy = try await stagedCopy(of: document)
        let destination = try place(copy)
        let firstURL = document.url
        XCTAssertNotNil(firstURL)

        let ok = await document.newDocument()
        XCTAssertTrue(ok)
        XCTAssertFalse(document.adoptSaveAs(copy, at: destination))
        XCTAssertNil(document.url, "the new document is not retargeted")
        XCTAssertEqual(document.text, "")
    }

    func testRowTitleIsTheMacString() throws {
        try skipUnlessEnglishInterface()
        // pinned-en: the Mac's "Save As..." with the iPhone's ellipsis.
        XCTAssertEqual(DocumentSection.saveAsTitle, "Save As\u{2026}")
    }

    // MARK: - Helpers

    private func preparedDocument() async -> OpenDocument {
        let folder = saveFolder!
        let document = OpenDocument(folderProvider: { folder }, ubiquitousItems: SaveAsTestUbiquitousItems())
        await document.prepare()
        return document
    }

    private func stagedCopy(of document: OpenDocument) async throws -> OpenDocument.SaveAsCopy {
        let copy = await document.prepareSaveAs(stagingFolder: stagingFolder)
        return try XCTUnwrap(copy)
    }

    /// What the export picker does with `asCopy: true`: copies the staged file into the folder
    /// the writer chose.
    private func place(_ copy: OpenDocument.SaveAsCopy) throws -> URL {
        let destination = destinationFolder.appendingPathComponent(copy.url.lastPathComponent)
        try FileManager.default.copyItem(at: copy.url, to: destination)
        return destination
    }
}

/// Every file is local: nothing downloads, and real iCloud is never asked.
private struct SaveAsTestUbiquitousItems: UbiquitousItemAccessing {
    func downloadState(_ url: URL) -> UbiquitousDownloadState { .current }
    func startDownloading(_ url: URL) throws {}
}
