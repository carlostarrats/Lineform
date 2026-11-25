import LineformCore
import SwiftUI
import UIKit

/// The export, print, share and read-aloud commands, in the Mac's order, for the word menu's
/// Export & Print page and the Read Aloud pill.
///
/// An export opens the share sheet for the new copy; its "Save to Files" is where an export is
/// saved, and the copy is deleted when that sheet closes. A failed export closes the menu and
/// shows the screen's calm notice. Print opens the system print panel with the Styled layout, as
/// the Mac's ⌘P does. Share hands on the document's own file, saved first, and is unavailable
/// while an Untitled document has nothing typed.
///
/// Read aloud reads the editor's selection (in source coordinates) in Write and Preview and the
/// whole document in Read, by the Mac's rule (`ExportCommands.speechSource`).
@MainActor
enum ExportRows {
    static var printTitle: String { String(localized: "Print\u{2026}") }
    static var shareTitle: String { String(localized: "Share\u{2026}") }

    /// Exports `format` and shares the copy. `onFailure` runs when the export failed (the
    /// screen's notice says why; the menu should close so it shows).
    static func export(_ format: PhoneExportFormat, commands: ExportCommands, onFailure: @escaping () -> Void) {
        Task {
            if let url = await commands.exportForSharing(format) {
                // Closing the share sheet deletes the copy: it was shared, saved, or not wanted.
                ActivityShareSheet(fileURL: url) { commands.removeExports() }.present()
            } else {
                onFailure()
            }
        }
    }

    /// Shares the document's own file, saved first. `onFailure` runs when that save failed.
    static func share(commands: ExportCommands, onFailure: @escaping () -> Void) {
        Task {
            if let url = await commands.documentFileForSharing() {
                ActivityShareSheet(fileURL: url) {}.present()
            } else {
                onFailure()
            }
        }
    }

    /// The system print panel with the Styled layout.
    static func print(commands: ExportCommands) {
        let controller = UIPrintInteractionController.shared
        controller.printInfo = PhonePrintRenderer.printInfo(jobName: commands.printJobName)
        let renderer = commands.makePrintRenderer()
        controller.printPageRenderer = renderer
        controller.present(animated: true)
        // The other sheets' renders, on main while the panel is up: the print system's threads
        // only lay out and draw finished renders (`PhonePrintRenderer`, Threading).
        Task { await renderer.renderRemainingSheets() }
    }

    static func perform(_ action: SpeechAction, commands: ExportCommands, selection: NSRange?, mode: EditorDisplayMode) {
        switch action {
        case .start: commands.startReadingAloud(selection: mode == .read ? nil : selection, mode: mode)
        case .pause, .resume: commands.pauseOrResumeReading()
        case .stop: commands.stopReading()
        }
    }

    // MARK: - State

    /// The page's command titles, in order: Export PDF…, HTML… and Markdown…, then Share and Print.
    static var rowTitles: [String] {
        PhoneExportFormat.allCases.map(\.title) + [shareTitle, printTitle]
    }

    /// Share has no file while an Untitled document has nothing typed.
    static func isShareDisabled(_ commands: ExportCommands) -> Bool {
        !commands.canShareDocument
    }

    enum SpeechAction: Hashable {
        case start, pause, resume, stop

        var title: String {
            switch self {
            case .start: return String(localized: "Start Speaking")
            case .pause: return String(localized: "Pause Speaking")
            case .resume: return String(localized: "Resume Speaking")
            case .stop: return String(localized: "Stop Speaking")
            }
        }

        var systemImage: String {
            switch self {
            case .start: return "speaker.wave.2"
            case .pause: return "pause"
            case .resume: return "play"
            case .stop: return "xmark"
            }
        }
    }

    /// The read-aloud actions for a state: Start when idle; Pause or Resume, then Stop, while
    /// reading.
    static func speechActions(for state: SpeechState) -> [SpeechAction] {
        switch state {
        case .idle: return [.start]
        case .speaking: return [.pause, .stop]
        case .paused: return [.resume, .stop]
        }
    }

    static func speechTitles(for state: SpeechState) -> [String] {
        speechActions(for: state).map(\.title)
    }
}
