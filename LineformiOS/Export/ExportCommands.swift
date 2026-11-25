import AVFoundation
import Combine
import Foundation
import LineformCore
import Observation

/// Sets up and lets go of the audio session read aloud plays through.
@MainActor
protocol SpeechAudioSessionControlling: AnyObject {
    /// Spoken audio that plays with the ringer off, like a podcast.
    func activateForSpeech()
    /// Hands the audio back, so music another app paused can resume.
    func deactivateAfterSpeech()
}

/// The shared `AVAudioSession`. A failure (the simulator, another app holding the session) is
/// ignored: speech still plays through whatever session is current.
@MainActor
final class LiveSpeechAudioSession: SpeechAudioSessionControlling {
    init() {}

    func activateForSpeech() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio)
        try? session.setActive(true)
    }

    func deactivateAfterSpeech() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// What the Read Aloud pill shows (`ExportCommands.readAloudPill`).
enum ReadAloudPillState: Equatable {
    /// No pill: nothing has been read, the writer closed it, or the document swapped.
    case hidden
    case reading
    case paused
    /// The reading reached its end; the pill stays and offers to read it again from the start.
    case finished
}

/// What the Menu sheet calls: export a copy (HTML, PDF, Styled PDF, Rich Text), hand on the
/// document's own file for Share, print, and read aloud.
///
/// Every export and Share saves the pending text first (`OpenDocument.flush`), so what leaves the
/// app is what the writer sees. The paper the writer picks for PDF stays for the session, and
/// starts at the region's everyday sheet. Read aloud follows the Mac's rule: in Write and Preview
/// a selection reads the selection and a caret reads from the caret to the end; Read mode (whose
/// selection is in rendered coordinates) and no selection read the whole document.
///
/// The document is held weakly: the screen owns it, and this object never keeps it alive.
@MainActor
@Observable
final class ExportCommands {
    enum ExportFailure: Error, Equatable {
        /// The export produced nothing.
        case emptyRender
        /// The file could not be written.
        case writeFailed

        /// The notice for a failed export of `documentName`.
        func message(documentName: String) -> String {
            String(localized: "Lineform couldn\u{2019}t export \u{201C}\(documentName)\u{201D}.")
        }
    }

    /// The sheet PDF exports use. Kept for the session.
    var paper: ExportPaperSize
    /// The region's everyday sheet, the one the print panel starts on: Print renders for it first.
    let printPaper: ExportPaperSize
    /// Read aloud's transport: idle, speaking or paused.
    private(set) var speechState: SpeechState
    /// What the Read Aloud pill shows: hidden until reading starts, then reading, paused or
    /// finished. Reaching the end leaves it `finished` (the pill stays, offering to read again);
    /// only ✕ (`stopReading`) or a document swap (`documentWillChange`) hides it.
    private(set) var readAloudPill: ReadAloudPillState
    /// The calm notice after an export failed, shown as long as the image notice
    /// (`OpenDocument.noticeDuration()`: longer while VoiceOver runs); nil otherwise.
    private(set) var failureNotice: String?

    @ObservationIgnored private weak var document: OpenDocument?
    /// Another document Export & Print's wheel chose, with its text as read from disk: exports,
    /// Share and Print act on it while the open document stays open (owner review 6). Nil acts on
    /// the open document; Export & Print sets it back to nil whenever it closes.
    private(set) var chosenFile: (url: URL, text: String)?
    @ObservationIgnored private let profile: () -> ReadingProfile
    @ObservationIgnored private let writer: PhoneExportWriter
    @ObservationIgnored private let speech: SpeechController
    @ObservationIgnored private let audioSession: any SpeechAudioSessionControlling
    @ObservationIgnored private var isAudioSessionActive: Bool
    @ObservationIgnored private var speechObservation: AnyCancellable?
    /// The text the last reading spoke, so the finished pill can read it again from the start.
    @ObservationIgnored private var lastSpokenText: String?
    @ObservationIgnored private var failureNoticeTask: Task<Void, Never>?
    /// The audio session's interruptions (a call, an alarm, Siri). Began pauses reading and the
    /// pill shows it paused; ended leaves it paused, even with `.shouldResume`: the writer resumes.
    @ObservationIgnored private var interruptionObservation: (any NSObjectProtocol)?
    /// An interruption took the audio session away since it was activated: resuming activates it again.
    @ObservationIgnored private var wasInterrupted: Bool

    init(
        document: OpenDocument,
        profile: @escaping () -> ReadingProfile,
        writer: PhoneExportWriter = .init(),
        // The best-sounding installed voice for the document's language (premium, then enhanced).
        speech: SpeechController = SpeechController(synthesizer: SystemSpeechSynthesizer(prefersBestQualityVoice: true)),
        regionCode: String? = Locale.current.region?.identifier,
        audioSession: any SpeechAudioSessionControlling = LiveSpeechAudioSession(),
        interruptions: NotificationCenter = .default
    ) {
        self.document = document
        self.profile = profile
        self.writer = writer
        self.speech = speech
        self.audioSession = audioSession
        let regional = ExportPaperSize.regionalDefault(regionCode: regionCode)
        paper = regional
        printPaper = regional
        speechState = speech.state
        readAloudPill = .hidden
        lastSpokenText = nil
        isAudioSessionActive = false
        speechObservation = nil
        failureNotice = nil
        failureNoticeTask = nil
        interruptionObservation = nil
        wasInterrupted = false
        // `@Published` emits before it stores, with the new value, so the mirror is current by the
        // time any call into `speech` returns, including a finish from the synthesizer.
        speechObservation = speech.$state.sink { [weak self] state in
            MainActor.assumeIsolated { self?.speechStateChanged(to: state) }
        }
        interruptionObservation = interruptions.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            MainActor.assumeIsolated {
                guard let raw, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                self?.audioInterrupted(type)
            }
        }
    }

    /// An audio interruption: when it begins, reading pauses (the pill shows Paused). When it
    /// ends, reading stays paused, `.shouldResume` or not; the pill's play resumes it.
    func audioInterrupted(_ type: AVAudioSession.InterruptionType) {
        switch type {
        case .began:
            guard isAudioSessionActive else { return }
            wasInterrupted = true
            if speechState == .speaking { speech.pauseOrResume() }
        case .ended:
            break
        @unknown default:
            break
        }
    }

    // MARK: - Export

    /// The document's name for exports, the print job and notices: its file name without the
    /// extension, or "Untitled".
    var documentBaseName: String {
        PhoneExportWriter.sanitizedBaseName(sourceURL?.deletingPathExtension().lastPathComponent ?? "")
    }

    /// The file exports act on: the wheel's choice, or the open document's.
    private var sourceURL: URL? { chosenFile?.url ?? document?.url }
    /// The text exports act on.
    private var sourceText: String { chosenFile?.text ?? document?.text ?? "" }
    private var sourceDirectory: URL? { chosenFile?.url.deletingLastPathComponent() ?? document?.documentDirectory }

    /// Export & Print's wheel: act on `url` instead of the open document, or on the open document
    /// again (nil, or the open document's own file). Reads the file off the main thread.
    func choose(_ url: URL?) async {
        guard let url, url.standardizedFileURL != document?.url?.standardizedFileURL else {
            chosenFile = nil
            return
        }
        let text = await Task.detached { FileSystemDiskReader().readText(at: url) }.value
        chosenFile = text.map { (url, $0) }
    }

    /// Writes `format` to a fresh file for the share sheet, after saving the pending text.
    func export(_ format: PhoneExportFormat) async -> Result<URL, ExportFailure> {
        guard let document else { return .failure(.writeFailed) }
        // A failed save still exports what is on screen; the save notice says the rest.
        if chosenFile == nil { _ = await document.flush() }
        do {
            let url = try writer.write(
                format,
                text: sourceText,
                baseName: documentBaseName,
                profile: profile(),
                paper: paper,
                documentDirectory: sourceDirectory
            )
            return .success(url)
        } catch PhoneExportWriter.WriteError.empty {
            return .failure(.emptyRender)
        } catch {
            return .failure(.writeFailed)
        }
    }

    /// `export`, for the rows: the file for the share sheet, or nil after showing the failure
    /// notice.
    func exportForSharing(_ format: PhoneExportFormat) async -> URL? {
        switch await export(format) {
        case .success(let url):
            return url
        case .failure(let failure):
            showFailureNotice(failure.message(documentName: documentBaseName))
            return nil
        }
    }

    /// Deletes every export copy: when the share sheet for one closes, and at launch for any copy
    /// a share sheet still held when iOS ended the app.
    func removeExports() {
        writer.removeAll()
    }

    private func showFailureNotice(_ message: String) {
        failureNoticeTask?.cancel()
        failureNotice = message
        failureNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: OpenDocument.noticeDuration())
            guard !Task.isCancelled else { return }
            self?.failureNotice = nil
        }
    }

    // MARK: - Share

    /// Whether Share has a file to hand on: the document has one, or has text that the next save
    /// gives one. An Untitled document with nothing typed, or only spaces and Returns, has none:
    /// `AutosavePlanner` makes no file until a line names it (`DocumentNaming.baseName`).
    var canShareDocument: Bool {
        if chosenFile != nil { return true }
        guard let document else { return false }
        return document.url != nil || DocumentNaming.baseName(fromText: document.text) != nil
    }

    /// The document's own file, saved first; nil when there is none or the save failed.
    func documentFileForSharing() async -> URL? {
        if let chosenFile { return chosenFile.url }
        guard let document, canShareDocument else { return nil }
        guard await document.flush() else { return nil }
        return document.url
    }

    // MARK: - Print

    /// The print job's name.
    var printJobName: String { documentBaseName }

    /// A renderer for the text as it is now, in the Styled layout.
    func makePrintRenderer() -> PhonePrintRenderer {
        PhonePrintRenderer(
            text: sourceText,
            profile: profile(),
            paper: printPaper,
            documentDirectory: sourceDirectory
        )
    }

    // MARK: - Read aloud

    /// Reads `selection` (source coordinates) or the document aloud, by the Mac's rule. A caret
    /// with nothing to read after it (at the end, or only spaces and blank lines after it) reads
    /// the whole document from the start, rather than doing nothing.
    func startReadingAloud(selection: NSRange?, mode: EditorDisplayMode) {
        guard let document else { return }
        var spoken = SpeechTextExtractor.spokenText(from: Self.speechSource(text: document.text, selection: selection, mode: mode))
        if selection?.length == 0, Self.isBlank(spoken) {
            spoken = SpeechTextExtractor.spokenText(from: document.text)
        }
        speak(spoken)
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The pill's pause/play: pauses or resumes; once reading has finished, reads the same text
    /// again from its beginning.
    func pauseOrResumeReading() {
        if readAloudPill == .finished {
            replayReading()
        } else {
            // After an interruption the system took the session: it is set up again to resume.
            if speechState == .paused, wasInterrupted {
                wasInterrupted = false
                audioSession.activateForSpeech()
            }
            speech.pauseOrResume()
        }
    }

    /// Reads what was last read again, from its beginning. Only after a reading has finished.
    func replayReading() {
        guard readAloudPill == .finished, let lastSpokenText else { return }
        speak(lastSpokenText)
    }

    /// Ends reading and closes the pill (its ✕).
    func stopReading() {
        readAloudPill = .hidden
        lastSpokenText = nil
        speech.stop()
    }

    private func speak(_ spoken: String) {
        guard !Self.isBlank(spoken) else { return }
        if !isAudioSessionActive || wasInterrupted {
            audioSession.activateForSpeech()
            isAudioSessionActive = true
            wasInterrupted = false
        }
        lastSpokenText = spoken
        speech.startSpeaking(spoken)
    }

    /// The screen calls this whenever the document swaps file (New, open, a reload into another
    /// file): reading the previous document on must not go on.
    func documentWillChange() {
        stopReading()
        chosenFile = nil
    }

    /// The Mac's `speechSource(for:)`: a Read-mode selection is in rendered coordinates and is
    /// never used to cut the source.
    static func speechSource(text: String, selection: NSRange?, mode: EditorDisplayMode) -> String {
        let source = text as NSString
        if mode != .read, let range = selection, range.length > 0, NSMaxRange(range) <= source.length {
            return source.substring(with: range)
        }
        if mode != .read, let range = selection, range.location <= source.length {
            return source.substring(from: range.location)
        }
        return text
    }

    private func speechStateChanged(to state: SpeechState) {
        speechState = state
        switch state {
        case .speaking: readAloudPill = .reading
        case .paused: readAloudPill = .paused
        // The end of the text: the pill stays, offering to read again. A stop hid it first.
        case .idle: if readAloudPill != .hidden { readAloudPill = .finished }
        }
        if state == .idle, isAudioSessionActive {
            isAudioSessionActive = false
            wasInterrupted = false
            audioSession.deactivateAfterSpeech()
        }
    }
}
