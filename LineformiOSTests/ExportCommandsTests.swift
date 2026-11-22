import LineformCore
import XCTest
@testable import LineformiOS

/// What the Menu sheet calls: exports (after the pending save), the document file for Share,
/// the print renderer, and read aloud. Every test works in its own temporary folders; speech runs
/// against a fake synthesizer, never real audio.
@MainActor
final class ExportCommandsTests: XCTestCase {
    private var folder: URL!
    private var exportFolder: URL!

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-commands-\(UUID().uuidString)", isDirectory: true)
        folder = root.appendingPathComponent("Documents", isDirectory: true)
        exportFolder = root.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
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
        audio: PhoneFakeSpeechAudioSession = PhoneFakeSpeechAudioSession(),
        regionCode: String? = "US"
    ) -> ExportCommands {
        ExportCommands(
            document: document,
            profile: { .original },
            writer: PhoneExportWriter(folder: exportFolder),
            speech: SpeechController(synthesizer: synthesizer),
            regionCode: regionCode,
            audioSession: audio
        )
    }

    // MARK: - Export

    func testExportFlushesFirst() async throws {
        let document = await preparedDocument()
        let commands = commands(document)
        document.edit("Typed just now\n\nand not saved yet.")
        XCTAssertNil(document.url, "the autosave has not run yet")

        let result = await commands.export(.html)

        let url = try result.get()
        let html = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(html.contains("not saved yet."), html)
        let saved = try XCTUnwrap(document.url, "the export saved the document first")
        XCTAssertEqual(try String(contentsOf: saved, encoding: .utf8), document.text)
        XCTAssertEqual(url.deletingPathExtension().lastPathComponent, saved.deletingPathExtension().lastPathComponent,
                       "the export is named from the document's file")
        XCTAssertTrue(url.path.hasPrefix(exportFolder.path), "the export lands in the export folder")
    }

    func testExportNamesUntitled() async throws {
        let document = await preparedDocument()
        let commands = commands(document)

        for format in PhoneExportFormat.allCases {
            let url = try await commands.export(format).get()
            XCTAssertEqual(url.lastPathComponent, "Untitled.\(format.fileExtension)")
        }
        XCTAssertNil(document.url, "an empty Untitled document still has no file")
    }

    func testExportUsesTheChosenPaper() async throws {
        let document = await preparedDocument()
        let commands = commands(document)
        document.edit("Words on a page.")
        commands.paper = .a5

        let url = try await commands.export(.pdf).get()
        let data = try Data(contentsOf: url)
        let pdf = try XCTUnwrap(CGPDFDocument(CGDataProvider(data: data as CFData)!))
        let box = try XCTUnwrap(pdf.page(at: 1)).getBoxRect(.mediaBox)
        XCTAssertEqual(box.size, ExportPaperSize.a5.sizeInPoints)
    }

    func testExportFailureMessageNamesTheDocument() {
        XCTAssertEqual(ExportCommands.ExportFailure.writeFailed.message(documentName: "Notes"),
                       "Lineform couldn\u{2019}t export \u{201C}Notes\u{201D}.")
        XCTAssertEqual(ExportCommands.ExportFailure.emptyRender.message(documentName: "Notes"),
                       "Lineform couldn\u{2019}t export \u{201C}Notes\u{201D}.")
    }

    // MARK: - Share

    func testShareUnavailableForEmptyUntitled() async {
        let document = await preparedDocument()
        let commands = commands(document)

        XCTAssertFalse(commands.canShareDocument)
        let shared = await commands.documentFileForSharing()
        XCTAssertNil(shared)

        // Only Returns and spaces: the autosave makes no file, so there is still nothing to share.
        document.edit("\n\n  ")
        XCTAssertFalse(commands.canShareDocument, "whitespace alone gets no file")
        let blank = await commands.documentFileForSharing()
        XCTAssertNil(blank)
        XCTAssertNil(document.url)
    }

    func testShareReturnsSavedFile() async throws {
        let document = await preparedDocument()
        let commands = commands(document)
        document.edit("Share me\n\nplease.")

        XCTAssertTrue(commands.canShareDocument, "typed text gets a file, so it can be shared")
        let shared = await commands.documentFileForSharing()
        let url = try XCTUnwrap(shared)
        XCTAssertEqual(url, document.url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "Share me\n\nplease.")
    }

    // MARK: - Paper and print

    func testPaperDefaultsByRegion() async {
        let document = await preparedDocument()
        XCTAssertEqual(commands(document, regionCode: "US").paper, .usLetter)
        XCTAssertEqual(commands(document, regionCode: "DE").paper, .a4)
        XCTAssertEqual(commands(document, regionCode: nil).paper, .a4)
    }

    func testPrintRendererAndJobName() async throws {
        let document = await preparedDocument()
        let commands = commands(document)
        XCTAssertEqual(commands.printJobName, "Untitled")

        document.edit("Printed words")
        _ = await document.flush()
        let saved = try XCTUnwrap(document.url)
        XCTAssertEqual(commands.printJobName, saved.deletingPathExtension().lastPathComponent)

        let renderer = commands.makePrintRenderer()
        let paper = CGRect(origin: .zero, size: ExportPaperSize.usLetter.sizeInPoints)
        renderer.setValue(NSValue(cgRect: paper), forKey: "paperRect")
        renderer.setValue(NSValue(cgRect: paper), forKey: "printableRect")
        XCTAssertEqual(renderer.numberOfPages, 1)
    }

    // MARK: - Read aloud

    func testReadAloudSelectionCaretAndWhole() async {
        let document = await preparedDocument()
        let synthesizer = PhoneFakeSpeechSynthesizer()
        let commands = commands(document, synthesizer: synthesizer)
        document.edit("# Hi\n\nSecond **paragraph**.")

        // A selection reads the selection.
        commands.startReadingAloud(selection: NSRange(location: 0, length: 4), mode: .write)
        XCTAssertEqual(synthesizer.spokenTexts.last, "Hi")

        // A caret reads from the caret to the end.
        commands.startReadingAloud(selection: NSRange(location: 6, length: 0), mode: .split)
        XCTAssertEqual(synthesizer.spokenTexts.last, "Second paragraph.")

        // No selection reads the whole document.
        commands.startReadingAloud(selection: nil, mode: .write)
        XCTAssertEqual(synthesizer.spokenTexts.last, SpeechTextExtractor.spokenText(from: document.text))
        XCTAssertEqual(synthesizer.spokenTexts.count, 3)
    }

    func testReadModeIgnoresSelection() async {
        let document = await preparedDocument()
        let synthesizer = PhoneFakeSpeechSynthesizer()
        let commands = commands(document, synthesizer: synthesizer)
        document.edit("# Hi\n\nSecond paragraph.")

        commands.startReadingAloud(selection: NSRange(location: 0, length: 4), mode: .read)

        XCTAssertEqual(synthesizer.spokenTexts, [SpeechTextExtractor.spokenText(from: document.text)])
    }

    func testOutOfRangeSelectionReadsTheWholeDocument() async {
        let document = await preparedDocument()
        let synthesizer = PhoneFakeSpeechSynthesizer()
        let commands = commands(document, synthesizer: synthesizer)
        document.edit("Short")

        commands.startReadingAloud(selection: NSRange(location: 40, length: 2), mode: .write)

        XCTAssertEqual(synthesizer.spokenTexts, ["Short"])
    }

    func testNothingToReadStartsNothing() async {
        let document = await preparedDocument()
        let audio = PhoneFakeSpeechAudioSession()
        let synthesizer = PhoneFakeSpeechSynthesizer()
        let commands = commands(document, synthesizer: synthesizer, audio: audio)

        commands.startReadingAloud(selection: nil, mode: .write)

        XCTAssertEqual(commands.speechState, .idle)
        XCTAssertTrue(synthesizer.spokenTexts.isEmpty)
        XCTAssertEqual(audio.activations, 0, "no audio session for silence")
    }

    func testDocumentSwapStopsSpeech() async {
        let document = await preparedDocument()
        let synthesizer = PhoneFakeSpeechSynthesizer()
        let audio = PhoneFakeSpeechAudioSession()
        let commands = commands(document, synthesizer: synthesizer, audio: audio)
        document.edit("Read this aloud.")
        commands.startReadingAloud(selection: nil, mode: .read)
        XCTAssertEqual(commands.speechState, .speaking)

        commands.documentWillChange()

        XCTAssertEqual(commands.speechState, .idle)
        XCTAssertEqual(synthesizer.stopCount, 1)
        XCTAssertFalse(synthesizer.isSpeaking)
        XCTAssertEqual(audio.deactivations, 1)

        // Nothing is reading: a second swap does nothing.
        commands.documentWillChange()
        XCTAssertEqual(synthesizer.stopCount, 1)
    }

    func testPauseResumeStop() async {
        let document = await preparedDocument()
        let synthesizer = PhoneFakeSpeechSynthesizer()
        let audio = PhoneFakeSpeechAudioSession()
        let commands = commands(document, synthesizer: synthesizer, audio: audio)
        document.edit("A long passage to read aloud.")

        commands.startReadingAloud(selection: nil, mode: .write)
        XCTAssertEqual(commands.speechState, .speaking)
        XCTAssertEqual(audio.activations, 1)

        commands.pauseOrResumeReading()
        XCTAssertEqual(commands.speechState, .paused)
        synthesizer.deliverPendingPause()
        XCTAssertTrue(synthesizer.isPaused)
        XCTAssertEqual(commands.speechState, .paused)

        commands.pauseOrResumeReading()
        XCTAssertEqual(commands.speechState, .speaking)
        XCTAssertFalse(synthesizer.isPaused)

        commands.stopReading()
        XCTAssertEqual(commands.speechState, .idle)
        XCTAssertEqual(audio.deactivations, 1)

        // Reading again, to the end: the finish returns to idle and lets the session go.
        commands.startReadingAloud(selection: nil, mode: .write)
        XCTAssertEqual(audio.activations, 2)
        synthesizer.finish()
        XCTAssertEqual(commands.speechState, .idle)
        XCTAssertEqual(audio.deactivations, 2)
    }

    /// A pause that lands at a word boundary after the user already resumed is undone, so audio
    /// does not go silent while the state says speaking (the shipping synthesizer's timing).
    func testLatePauseAfterResumeKeepsSpeaking() async {
        let document = await preparedDocument()
        let synthesizer = PhoneFakeSpeechSynthesizer()
        let commands = commands(document, synthesizer: synthesizer)
        document.edit("A long passage to read aloud.")
        commands.startReadingAloud(selection: nil, mode: .write)

        commands.pauseOrResumeReading()
        commands.pauseOrResumeReading()
        synthesizer.pause()                 // the request still on its way to a word boundary
        synthesizer.deliverPendingPause()

        XCTAssertEqual(commands.speechState, .speaking)
        XCTAssertFalse(synthesizer.isPaused)
    }

    func testCommandsDoNotKeepTheDocumentAlive() async {
        var document: OpenDocument? = await preparedDocument()
        weak var weakDocument = document
        var commands: ExportCommands? = commands(document!)
        commands?.documentWillChange()
        document = nil
        XCTAssertNil(weakDocument, "ExportCommands holds the document weakly")
        commands = nil
        _ = commands
    }
}

/// Models the SHIPPING `AVSpeechSynthesizer`, as the package's `SpeechControllerTests` fake does:
/// `stop()` reports the stopped utterance as finished (and `SystemSpeechSynthesizer` filters it
/// by identity, so it is not forwarded), and `pause()` takes effect only at the next word
/// boundary (`deliverPendingPause`).
final class PhoneFakeSpeechSynthesizer: SpeechSynthesizing {
    var onFinish: (() -> Void)?
    var onPause: (() -> Void)?
    var onContinue: (() -> Void)?
    private(set) var isSpeaking = false
    private(set) var isPaused = false
    private(set) var spokenTexts: [String] = []
    private(set) var stopCount = 0
    private(set) var hasPendingPause = false
    /// Mirrors `SystemSpeechSynthesizer.currentUtterance`.
    private var utteranceIsCurrent = false

    func speak(_ text: String, languageCode: String?) {
        spokenTexts.append(text)
        isSpeaking = true
        isPaused = false
        utteranceIsCurrent = true
    }

    func pause() { hasPendingPause = true }

    func continueSpeaking() {
        hasPendingPause = false
        isPaused = false
        onContinue?()
    }

    func stop() {
        stopCount += 1
        isSpeaking = false
        isPaused = false
        hasPendingPause = false
        // The real synthesizer delivers didFinish for the stopped utterance; the adapter drops it
        // because it is no longer current.
        utteranceIsCurrent = false
    }

    /// The pending pause reaches a word boundary.
    func deliverPendingPause() {
        guard hasPendingPause else { return }
        hasPendingPause = false
        isPaused = true
        onPause?()
    }

    /// The utterance reaches its end.
    func finish() {
        isSpeaking = false
        guard utteranceIsCurrent else { return }
        utteranceIsCurrent = false
        onFinish?()
    }
}

/// Counts audio-session activations instead of touching the simulator's audio.
@MainActor
final class PhoneFakeSpeechAudioSession: SpeechAudioSessionControlling {
    private(set) var activations = 0
    private(set) var deactivations = 0

    func activateForSpeech() { activations += 1 }
    func deactivateAfterSpeech() { deactivations += 1 }
}
