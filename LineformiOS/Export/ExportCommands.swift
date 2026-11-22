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
    /// The calm notice after an export failed, shown for `failureNoticeDuration`; nil otherwise.
    private(set) var failureNotice: String?
    /// How long the failure notice stays, the same as the image notice's.
    static let failureNoticeDuration: Duration = OpenDocument.imageNoticeDuration

    @ObservationIgnored private weak var document: OpenDocument?
    @ObservationIgnored private let profile: () -> ReadingProfile
    @ObservationIgnored private let writer: PhoneExportWriter
    @ObservationIgnored private let speech: SpeechController
    @ObservationIgnored private let audioSession: any SpeechAudioSessionControlling
    @ObservationIgnored private var isAudioSessionActive: Bool
    @ObservationIgnored private var speechObservation: AnyCancellable?
    @ObservationIgnored private var failureNoticeTask: Task<Void, Never>?

    init(
        document: OpenDocument,
        profile: @escaping () -> ReadingProfile,
        writer: PhoneExportWriter = .init(),
        speech: SpeechController = SpeechController(),
        regionCode: String? = Locale.current.region?.identifier,
        audioSession: any SpeechAudioSessionControlling = LiveSpeechAudioSession()
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
        isAudioSessionActive = false
        speechObservation = nil
        failureNotice = nil
        failureNoticeTask = nil
        // `@Published` emits before it stores, with the new value, so the mirror is current by the
        // time any call into `speech` returns, including a finish from the synthesizer.
        speechObservation = speech.$state.sink { [weak self] state in
            MainActor.assumeIsolated { self?.speechStateChanged(to: state) }
        }
    }

    // MARK: - Export

    /// The document's name for exports, the print job and notices: its file name without the
    /// extension, or "Untitled".
    var documentBaseName: String {
        PhoneExportWriter.sanitizedBaseName(document?.url?.deletingPathExtension().lastPathComponent ?? "")
    }

    /// Writes `format` to a fresh file for the share sheet, after saving the pending text.
    func export(_ format: PhoneExportFormat) async -> Result<URL, ExportFailure> {
        guard let document else { return .failure(.writeFailed) }
        // A failed save still exports what is on screen; the save notice says the rest.
        _ = await document.flush()
        do {
            let url = try writer.write(
                format,
                text: document.text,
                baseName: documentBaseName,
                profile: profile(),
                paper: paper,
                documentDirectory: document.documentDirectory
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
            try? await Task.sleep(for: Self.failureNoticeDuration)
            guard !Task.isCancelled else { return }
            self?.failureNotice = nil
        }
    }

    // MARK: - Share

    /// Whether Share has a file to hand on: the document has one, or has text that the next save
    /// gives one. An Untitled document with nothing typed, or only spaces and Returns, has none:
    /// `AutosavePlanner` makes no file until a line names it (`DocumentNaming.baseName`).
    var canShareDocument: Bool {
        guard let document else { return false }
        return document.url != nil || DocumentNaming.baseName(fromText: document.text) != nil
    }

    /// The document's own file, saved first; nil when there is none or the save failed.
    func documentFileForSharing() async -> URL? {
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
            text: document?.text ?? "",
            profile: profile(),
            paper: printPaper,
            documentDirectory: document?.documentDirectory
        )
    }

    // MARK: - Read aloud

    /// Reads `selection` (source coordinates) or the document aloud, by the Mac's rule.
    func startReadingAloud(selection: NSRange?, mode: EditorDisplayMode) {
        guard let document else { return }
        let spoken = SpeechTextExtractor.spokenText(from: Self.speechSource(text: document.text, selection: selection, mode: mode))
        guard !spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if !isAudioSessionActive {
            audioSession.activateForSpeech()
            isAudioSessionActive = true
        }
        speech.startSpeaking(spoken)
    }

    func pauseOrResumeReading() {
        speech.pauseOrResume()
    }

    func stopReading() {
        speech.stop()
    }

    /// The screen calls this whenever the document swaps file (New, open, a reload into another
    /// file): reading the previous document on must not go on.
    func documentWillChange() {
        stopReading()
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
        if state == .idle, isAudioSessionActive {
            isAudioSessionActive = false
            audioSession.deactivateAfterSpeech()
        }
    }
}
