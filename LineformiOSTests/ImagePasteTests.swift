import LineformCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import LineformiOS

/// Pasting and dropping an image: a PNG in `images/` beside the document, named the Mac's way,
/// and a link on its own line. A string on the pasteboard always pastes as text. A document that
/// was never saved is saved first; if that fails, nothing is inserted. Every test saves into its
/// own temporary folder and pastes from its own pasteboard, never the user's.
@MainActor
final class ImagePasteTests: XCTestCase {
    private var folder: URL!
    private var pasteboard: UIPasteboard!
    private var coordinator: MarkdownEditor.Coordinator?

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("image-paste-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        pasteboard = UIPasteboard.withUniqueName()
    }

    override func tearDownWithError() throws {
        UIPasteboard.remove(withName: pasteboard.name)
        coordinator = nil
        try? FileManager.default.removeItem(at: folder)
    }

    func testPastedImageWritesPNGIntoImagesFolder() async throws {
        let document = await preparedDocument()
        let textView = makeEditor(for: document)
        type("Notes\n", into: textView)
        await document.flush()
        XCTAssertEqual(document.url, folder.appendingPathComponent("Notes.md"))

        pasteboard.setItems([[UTType.png.identifier: Self.pngData()]])
        XCTAssertTrue(textView.canPerformAction(#selector(UIResponderStandardEditActions.paste(_:)), withSender: nil),
                      "Paste is offered for an image-only pasteboard")
        textView.paste(nil)
        await textView.imagePasteTask?.value

        let image = folder.appendingPathComponent("images/image.png")
        let data = try Data(contentsOf: image)
        XCTAssertEqual(Array(data.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], "a PNG file")
        XCTAssertEqual(UIImage(data: data)?.size, CGSize(width: 4, height: 4))
        XCTAssertEqual(textView.text, "Notes\n![](images/image.png)\n")
        XCTAssertEqual(document.text, textView.text, "the binding has the link")
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(document.url), encoding: .utf8), textView.text, "and it is saved")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(), ["Notes.md", "images"])

        // paste(itemProviders:) takes the same path.
        textView.paste(itemProviders: [NSItemProvider(item: Self.pngData() as NSData, typeIdentifier: UTType.png.identifier)])
        await textView.imagePasteTask?.value
        XCTAssertEqual(textView.text, "Notes\n![](images/image.png)\n![](images/image-2.png)\n")
    }

    func testLinkInsertedOnOwnLine() async throws {
        let document = await preparedDocument()
        let textView = makeEditor(for: document)
        type("First line\nSecond line", into: textView)
        await document.flush()
        let undoManager = try XCTUnwrap(textView.undoManager)
        undoManager.removeAllActions()

        // Caret in the middle of "Second": the link goes in at the start of that line.
        let caret = await textView.insertImage(png: Self.pngData(), preferredName: "image", at: 14)

        let snippet = "![](images/image.png)\n"
        XCTAssertEqual(textView.text, "First line\n" + snippet + "Second line")
        XCTAssertEqual(caret, 11 + (snippet as NSString).length)
        XCTAssertEqual(textView.selectedRange, NSRange(location: 11 + (snippet as NSString).length, length: 0))

        // CRLF documents keep CRLF.
        textView.setDocumentText("A\r\nB")
        _ = await textView.insertImage(png: Self.pngData(), preferredName: "image", at: 3)
        XCTAssertEqual(textView.text, "A\r\n![](images/image-2.png)\r\nB")

        // One undo step takes the link out again.
        textView.setDocumentText("First line\nSecond line")
        undoManager.removeAllActions()
        _ = await textView.insertImage(png: Self.pngData(), preferredName: "image", at: 14)
        XCTAssertTrue(undoManager.canUndo)
        undoManager.undo()
        XCTAssertEqual(textView.text, "First line\nSecond line")
        XCTAssertFalse(undoManager.canUndo, "exactly one undo step")
    }

    func testStringPasteWinsOverImage() async throws {
        let document = await preparedDocument()
        let textView = makeEditor(for: document)
        type("Notes", into: textView)

        pasteboard.setItems([[UTType.utf8PlainText.identifier: "plain words", UTType.png.identifier: Self.pngData()]])
        XCTAssertFalse(LineformTextView.pastesImage(from: pasteboard), "a string and an image: the string wins")
        XCTAssertNil(textView.canPerformImagePaste(#selector(UIResponderStandardEditActions.paste(_:))),
                     "the text view decides Paste as usual")
        textView.paste(itemProviders: pasteboard.itemProviders)
        XCTAssertNil(textView.imagePasteTask, "the image path never starts")

        // Item providers that carry text paste as text too, whatever the pasteboard has.
        pasteboard.setItems([[UTType.png.identifier: Self.pngData()]])
        XCTAssertTrue(LineformTextView.pastesImage(from: pasteboard))
        let mixed = NSItemProvider(item: "words" as NSString, typeIdentifier: UTType.utf8PlainText.identifier)
        mixed.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            completion(Self.pngData(), nil)
            return nil
        }
        textView.paste(itemProviders: [mixed])
        XCTAssertNil(textView.imagePasteTask)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("images").path))
        XCTAssertEqual(document.url, nil, "nothing was saved for an image")
    }

    func testPasteIntoUnsavedDocumentCreatesItFirst() async throws {
        // Typed but never saved: the paste saves it first, named from its first line.
        let document = await preparedDocument()
        let textView = makeEditor(for: document)
        type("Trip notes\n", into: textView)
        XCTAssertNil(document.url)

        pasteboard.setItems([[UTType.png.identifier: Self.pngData()]])
        textView.paste(nil)
        await textView.imagePasteTask?.value

        let documentURL = folder.appendingPathComponent("Trip notes.md")
        XCTAssertEqual(document.url, documentURL)
        XCTAssertEqual(textView.text, "Trip notes\n![](images/image.png)\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("images/image.png").path))
        XCTAssertEqual(try String(contentsOf: documentURL, encoding: .utf8), textView.text)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(), ["Trip notes.md", "images"],
                       "nothing is written outside the save folder")

        // Blank: there is nothing to name a file from until the link goes in; the file is created
        // from it at once, in the save folder, beside images/.
        let blankFolder = folder.appendingPathComponent("blank", isDirectory: true)
        try FileManager.default.createDirectory(at: blankFolder, withIntermediateDirectories: true)
        let blank = OpenDocument(folderProvider: { blankFolder }, ubiquitousItems: NoUbiquitousItems())
        await blank.prepare()
        let blankView = makeEditor(for: blank)
        _ = await blankView.insertImage(png: Self.pngData(), preferredName: "image", at: nil)
        XCTAssertEqual(blankView.text, "![](images/image.png)\n")
        let blankURL = try XCTUnwrap(blank.url, "the document was created")
        XCTAssertEqual(blankURL.deletingLastPathComponent().standardizedFileURL, blankFolder.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: blankFolder.appendingPathComponent("images/image.png").path))

        // The first save fails: nothing is inserted, nothing written, and the notice shows.
        let failingFolder = folder.appendingPathComponent("failing", isDirectory: true)
        try FileManager.default.createDirectory(at: failingFolder, withIntermediateDirectories: true)
        let failing = OpenDocument(folderProvider: { failingFolder }, writer: FailingWriter(), ubiquitousItems: NoUbiquitousItems())
        await failing.prepare()
        let failingView = makeEditor(for: failing)
        type("Unsaved", into: failingView)
        let caret = await failingView.insertImage(png: Self.pngData(), preferredName: "image", at: nil)
        XCTAssertNil(caret)
        XCTAssertEqual(failingView.text, "Unsaved")
        XCTAssertTrue(failing.saveFailed, "the save-failed notice shows")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: failingFolder.path), [])
    }

    func testUniqueNameOnCollision() async throws {
        let document = await preparedDocument()
        let textView = makeEditor(for: document)
        type("Notes", into: textView)
        await document.flush()
        let images = folder.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let theirs = Data("not mine".utf8)
        try theirs.write(to: images.appendingPathComponent("image.png"))

        pasteboard.setItems([[UTType.png.identifier: Self.pngData()]])
        textView.paste(nil)
        await textView.imagePasteTask?.value

        XCTAssertEqual(try Data(contentsOf: images.appendingPathComponent("image.png")), theirs, "never overwritten")
        XCTAssertTrue(FileManager.default.fileExists(atPath: images.appendingPathComponent("image-2.png").path))
        XCTAssertEqual(textView.text, "![](images/image-2.png)\nNotes")

        // A name is sanitized the Mac's way, and a link stays parseable.
        _ = await textView.insertImage(png: Self.pngData(), preferredName: "Screen Shot (1)", at: nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: images.appendingPathComponent("Screen-Shot-1.png").path))
        XCTAssertTrue(textView.text.contains("![](images/Screen-Shot-1.png)"))
    }

    /// A document whose folder cannot be written (a file opened from another provider, where
    /// only the file is in scope): nothing goes in, nothing is written, and a short notice says why.
    func testUnwritableFolderInsertsNothingAndShowsNotice() async throws {
        let readOnly = folder.appendingPathComponent("read-only", isDirectory: true)
        try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
        let file = readOnly.appendingPathComponent("Theirs.md")
        try "Theirs\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnly.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnly.path) }

        let document = await preparedDocument()
        try await document.open(file)
        let textView = makeEditor(for: document)
        XCTAssertFalse(document.imageSaveFailed)

        pasteboard.setItems([[UTType.png.identifier: Self.pngData()]])
        textView.paste(nil)
        await textView.imagePasteTask?.value

        XCTAssertEqual(textView.text, "Theirs\n", "no link to an image that is not there")
        XCTAssertEqual(document.text, "Theirs\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: readOnly.appendingPathComponent("images").path))
        XCTAssertTrue(document.imageSaveFailed, "the image notice shows")
        XCTAssertFalse(document.saveFailed, "the document itself still saves")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(), ["read-only"],
                       "no fallback copy anywhere else")
    }

    /// A drop has no pasteboard: an image drop goes in even while the general pasteboard holds
    /// a string. Only `paste(_:)` lets a pasteboard string win.
    func testImageDropWithStringOnPasteboardInsertsImage() async throws {
        let document = await preparedDocument()
        let textView = makeEditor(for: document)
        type("Notes\n", into: textView)
        await document.flush()
        pasteboard.setItems([[UTType.utf8PlainText.identifier: "plain words"]])

        textView.paste(itemProviders: [NSItemProvider(item: Self.pngData() as NSData, typeIdentifier: UTType.png.identifier)])
        await textView.imagePasteTask?.value

        XCTAssertEqual(textView.text, "Notes\n![](images/image.png)\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("images/image.png").path))
    }

    /// A drop session's providers are only good during `performDrop`: every load starts at once,
    /// and only the inserts wait for each other.
    func testEveryDropLoadStartsAtOnce() async throws {
        let document = await preparedDocument()
        let textView = makeEditor(for: document)
        type("Notes\n", into: textView)
        await document.flush()
        let providers = [RecordingImageProvider(png: Self.pngData()), RecordingImageProvider(png: Self.pngData())]

        textView.insertImages(from: providers, at: nil)
        XCTAssertEqual(providers.map(\.loadStarted), [true, true], "both loads started before the first insert")

        await textView.imagePasteTask?.value
        XCTAssertEqual(textView.text, "Notes\n![](images/image.png)\n![](images/image-2.png)\n")
    }

    /// The document was replaced while the image was on its way: it lands in neither document,
    /// and the PNG it wrote is removed.
    func testImageForReplacedDocumentIsDiscarded() async throws {
        let document = await preparedDocument()
        let textView = makeEditor(for: document)
        type("Notes\n", into: textView)
        await document.flush()
        let notes = try XCTUnwrap(document.url)
        let identity = document.imageInsertionDocumentIdentity

        let replaced = await document.newDocument()
        XCTAssertTrue(replaced)
        textView.setDocumentText(document.text)
        let caret = await textView.insertImage(png: Self.pngData(), preferredName: "image", at: nil, documentIdentity: identity)

        XCTAssertNil(caret)
        XCTAssertEqual(textView.text, "")
        XCTAssertEqual(document.text, "")
        XCTAssertNil(document.url, "the new document was not created for it")
        XCTAssertEqual(try String(contentsOf: notes, encoding: .utf8), "Notes\n")
        let images = folder.appendingPathComponent("images").path
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: images)) ?? [], [], "the PNG was removed")
    }

    // MARK: - Helpers

    private func preparedDocument() async -> OpenDocument {
        let folder = self.folder!
        let document = OpenDocument(folderProvider: { folder }, ubiquitousItems: NoUbiquitousItems())
        await document.prepare()
        return document
    }

    /// The editor as `MarkdownEditor` sets it up: the coordinator is its delegate and writes
    /// every change to the document; the document is the image host.
    private func makeEditor(for document: OpenDocument) -> LineformTextView {
        let editor = MarkdownEditor(
            text: Binding(get: { document.text }, set: { document.edit($0) }),
            profile: .original,
            imageHost: document
        )
        let coordinator = editor.makeCoordinator()
        self.coordinator = coordinator
        let textView = LineformTextView.make(profile: .original)
        textView.setDocumentText(document.text)
        textView.delegate = coordinator
        textView.imageInsertionHost = document
        textView.pasteboardForTesting = pasteboard
        objc_setAssociatedObject(textView, &Self.coordinatorKey, coordinator, .OBJC_ASSOCIATION_RETAIN)
        return textView
    }

    private static var coordinatorKey: UInt8 = 0

    private func type(_ text: String, into textView: LineformTextView) {
        textView.selectedRange = NSRange(location: (textView.text as NSString).length, length: 0)
        textView.insertText(text)
    }

    /// A 4 × 4 red PNG.
    private static func pngData() -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4), format: format).pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }
}

/// Every file is local and current; real iCloud is never asked.
private struct NoUbiquitousItems: UbiquitousItemAccessing {
    func downloadState(_ url: URL) -> UbiquitousDownloadState { .current }
    func startDownloading(_ url: URL) throws {}
}

/// An image provider that records when its data starts loading.
private final class RecordingImageProvider: NSItemProvider, @unchecked Sendable {
    private(set) var loadStarted = false

    init(png: Data) {
        super.init()
        registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            completion(png, nil)
            return nil
        }
    }

    override func loadDataRepresentation(
        forTypeIdentifier typeIdentifier: String,
        completionHandler: @escaping @Sendable (Data?, (any Error)?) -> Void
    ) -> Progress {
        loadStarted = true
        return super.loadDataRepresentation(forTypeIdentifier: typeIdentifier, completionHandler: completionHandler)
    }
}
