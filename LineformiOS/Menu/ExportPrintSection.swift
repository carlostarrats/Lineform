import LineformCore
import SwiftUI
import UIKit

/// The word menu's Export & Print: the Mac's File menu plus Share.
///
/// - Export As: HTML, PDF, Styled PDF and Rich Text (`ExportCommands`), with the paper size the
///   two PDFs use. Each opens the share sheet for its copy.
/// - Share… and Print….
/// - Save As…: the system export picker, after which the document is the new file
///   (`SaveAsPicker`, `OpenDocument.adoptSaveAs`).
/// - Convert to Plain Text, or Convert to Markdown once converted: the title follows the
///   document's format (`OpenDocument.textFormat`). A `.txt` opened from disk has no conversion to
///   restore, so the row is off. Convert keeps the page open, so the title's change is seen.
struct ExportPrintSection: View {
    var document: OpenDocument
    /// The screen's export commands; nil until the screen has made them (no export rows then).
    var exportCommands: ExportCommands?
    var onDismiss: () -> Void

    // MARK: - Copy (the Mac's strings where the English matches)

    /// The Mac's "Save As..." with the iPhone's ellipsis, as Print… and Share… are.
    static var saveAsTitle: String { String(localized: "Save As\u{2026}") }

    /// The Mac's `AppMenuConfiguration.conversionCommandTitle`: what the command turns the
    /// document into.
    static func conversionTitle(for textFormat: LineformTextFormat) -> String {
        switch textFormat {
        case .markdown: String(localized: "Convert to Plain Text")
        case .plainText: String(localized: "Convert to Markdown")
        }
    }

    /// What VoiceOver hears after Convert: the page stays open and only the row's title changes,
    /// which VoiceOver would not say on its own.
    static func conversionAnnouncement(for newFormat: LineformTextFormat) -> String {
        switch newFormat {
        case .plainText: String(localized: "Converted to plain text")
        case .markdown: String(localized: "Converted to Markdown")
        }
    }

    /// The document has something to send or read: not empty, and not only white space.
    static func hasText(_ text: String) -> Bool {
        text.contains { !$0.isWhitespace }
    }

    /// Every row's title, in order, for `textFormat` (the paper size aside).
    static func rowTitles(for textFormat: LineformTextFormat) -> [String] {
        ExportRows.rowTitles + [saveAsTitle, conversionTitle(for: textFormat)]
    }

    // MARK: - Body

    var body: some View {
        WordMenuPageScaffold(title: WordMenuItem.exportPrint.title) {
            if let exportCommands {
                ExportFormatRows(commands: exportCommands, onDismiss: onDismiss)
                Color.clear.frame(height: 10)
                WordMenuRow(title: ExportRows.shareTitle, systemImage: "square.and.arrow.up", accessory: .none) {
                    ExportRows.share(commands: exportCommands, onFailure: onDismiss)
                }
                .disabled(ExportRows.isShareDisabled(exportCommands))
                WordMenuRow(title: ExportRows.printTitle, systemImage: "printer", accessory: .none) {
                    ExportRows.print(commands: exportCommands)
                }
                Color.clear.frame(height: 10)
            }
            WordMenuRow(title: Self.saveAsTitle, systemImage: "square.and.arrow.down", accessory: .none) {
                saveAs()
            }
            .disabled(!document.canSaveAs)
            WordMenuRow(
                title: Self.conversionTitle(for: document.textFormat),
                systemImage: "textformat",
                accessory: .none
            ) {
                let before = document.textFormat
                switch before {
                case .markdown: document.convertToPlainText()
                case .plainText: document.restoreMarkdown()
                }
                if document.textFormat != before {
                    ChromeAnnouncer.announce(Self.conversionAnnouncement(for: document.textFormat))
                }
            }
            .disabled(!document.canConvertTextFormat)
        }
    }

    /// Save As: stage a copy (saving first), let the writer place it, then move the document
    /// there. A failed save closes the menu so the screen's save notice shows; a cancel keeps the
    /// menu open.
    private func saveAs() {
        let document = document
        let onDismiss = onDismiss
        Task {
            guard let copy = await document.prepareSaveAs() else {
                onDismiss()
                return
            }
            SaveAsPicker(copyURL: copy.url) { destination in
                SaveAsStaging.removeAll()
                guard let destination else { return }
                document.adoptSaveAs(copy, at: destination)
                onDismiss()
            }.present()
        }
    }
}

/// Export As: one row per format, and the paper size above the PDFs.
private struct ExportFormatRows: View {
    @Bindable var commands: ExportCommands
    var onDismiss: () -> Void

    var body: some View {
        WordMenuGroupLabel(title: ExportRows.exportGroupTitle)
        ForEach(PhoneExportFormat.allCases, id: \.self) { format in
            if format == .pdf {
                Menu {
                    Picker(ExportRows.paperSizeTitle, selection: $commands.paper) {
                        ForEach(ExportPaperSize.allCases, id: \.self) { paper in
                            Text(paper.displayName).tag(paper)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    WordMenuRowLabel(
                        title: ExportRows.paperSizeTitle,
                        systemImage: "doc",
                        accessory: .text(commands.paper.displayName)
                    )
                }
                .buttonStyle(WordMenuPressStyle())
                .accessibilityLabel(ExportRows.paperSizeTitle)
                .accessibilityValue(commands.paper.displayName)
            }
            WordMenuRow(title: format.title, systemImage: Self.systemImage(for: format), accessory: .none) {
                ExportRows.export(format, commands: commands, onFailure: onDismiss)
            }
        }
    }

    static func systemImage(for format: PhoneExportFormat) -> String {
        switch format {
        case .html: "chevron.left.forwardslash.chevron.right"
        case .pdf, .styledPDF: "doc.richtext"
        case .rtf: "doc.text"
        }
    }
}
