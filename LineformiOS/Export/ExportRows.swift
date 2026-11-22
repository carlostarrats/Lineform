import LineformCore
import SwiftUI
import UIKit

/// The Menu sheet's document rows, in the Mac's order: Export As (HTML, PDF, Styled PDF, Rich
/// Text, with the paper size above the two PDFs), Print…, Share…, and read aloud.
///
/// An export opens the share sheet for the new copy; its "Save to Files" is where an export is
/// saved, and the copy is deleted when that sheet closes. A failed export closes the menu and
/// shows the screen's calm notice. Print opens the system print panel with the Styled layout, as
/// the Mac's ⌘P does. Share hands on the document's own file, saved first, and is unavailable
/// while an Untitled document has nothing typed.
///
/// Read aloud reads `selection()` (the editor's selection, in source coordinates) in Write and
/// Preview and the whole document in Read, by the Mac's rule (`ExportCommands.speechSource`).
struct ExportRows: View {
    @Bindable var commands: ExportCommands
    var selection: () -> NSRange?
    var mode: EditorDisplayMode

    @Environment(\.dismiss) private var dismiss

    init(commands: ExportCommands, selection: @escaping () -> NSRange?, mode: EditorDisplayMode) {
        self.commands = commands
        self.selection = selection
        self.mode = mode
    }

    var body: some View {
        Section {
            exportMenu
            Button(action: { printDocument() }) {
                Label(String(localized: "Print\u{2026}"), systemImage: "printer")
            }
            Button(action: { shareDocument() }) {
                Label(String(localized: "Share\u{2026}"), systemImage: "square.and.arrow.up")
            }
            .disabled(Self.isShareDisabled(commands))
            ForEach(Self.speechActions(for: commands.speechState), id: \.self) { action in
                Button {
                    perform(action)
                } label: {
                    Label(action.title, systemImage: action.systemImage)
                }
            }
        }
    }

    private var exportMenu: some View {
        Menu {
            exportButton(.html)
            Section {
                Picker(String(localized: "Paper Size"), selection: $commands.paper) {
                    ForEach(ExportPaperSize.allCases, id: \.self) { paper in
                        Text(paper.displayName).tag(paper)
                    }
                }
                .pickerStyle(.menu)
                exportButton(.pdf)
                exportButton(.styledPDF)
            }
            exportButton(.rtf)
        } label: {
            Label(String(localized: "Export As"), systemImage: "square.and.arrow.up")
        }
    }

    private func exportButton(_ format: PhoneExportFormat) -> some View {
        Button(format.title) { export(format) }
    }

    // MARK: - Actions

    private func export(_ format: PhoneExportFormat) {
        Task {
            if let url = await commands.exportForSharing(format) {
                // Closing the share sheet deletes the copy: it was shared, saved, or not wanted.
                let commands = commands
                ActivityShareSheet(fileURL: url) { commands.removeExports() }.present()
            } else {
                // The notice is the screen's; the menu would cover it.
                dismiss()
            }
        }
    }

    private func shareDocument() {
        Task {
            if let url = await commands.documentFileForSharing() {
                ActivityShareSheet(fileURL: url) {}.present()
            } else {
                // A failed save shows the screen's save notice; the menu would cover it.
                dismiss()
            }
        }
    }

    private func printDocument() {
        let controller = UIPrintInteractionController.shared
        controller.printInfo = PhonePrintRenderer.printInfo(jobName: commands.printJobName)
        let renderer = commands.makePrintRenderer()
        controller.printPageRenderer = renderer
        controller.present(animated: true)
        // The other sheets' renders, on main while the panel is up: the print system's threads
        // only lay out and draw finished renders (`PhonePrintRenderer`, Threading).
        Task { await renderer.renderRemainingSheets() }
    }

    private func perform(_ action: SpeechAction) {
        switch action {
        case .start: commands.startReadingAloud(selection: mode == .read ? nil : selection(), mode: mode)
        case .pause, .resume: commands.pauseOrResumeReading()
        case .stop: commands.stopReading()
        }
    }

    // MARK: - State

    /// Share has no file while an Untitled document has nothing typed.
    /// The rows' titles while nothing is being read, in order (the Document section's row list).
    static var idleRowTitles: [String] {
        [String(localized: "Export As"), String(localized: "Print\u{2026}"), String(localized: "Share\u{2026}")]
            + speechTitles(for: .idle)
    }

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
            case .start, .pause, .resume: return "speaker.wave.2"
            case .stop: return "stop"
            }
        }
    }

    /// The read-aloud rows for a state: Start when idle; Pause or Resume, then Stop, while
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
