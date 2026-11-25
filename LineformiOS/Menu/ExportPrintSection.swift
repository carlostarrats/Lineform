import LineformCore
import SwiftUI
import UIKit

/// The word menu's Export & Print, exactly the approved mockup (`word-menu.html`, `export`): plain
/// rows, no icons, in three runs.
///
/// - Export PDF…, Export HTML…, Export Markdown… (`ExportCommands`): each opens the share sheet
///   for its copy. PDF uses the session's paper (the region's everyday sheet); Markdown is the
///   document's text as it is.
/// - Share… and Print….
/// - Convert to Plain Text, or Convert to Markdown once converted: the title follows the
///   document's format (`OpenDocument.textFormat`). A `.txt` opened from disk has no conversion to
///   restore, so the row is off. Convert keeps the page open, so the title's change is seen.
struct ExportPrintSection: View {
    var document: OpenDocument
    /// The screen's export commands; nil until the screen has made them (no export rows then).
    var exportCommands: ExportCommands?
    var onDismiss: () -> Void

    // MARK: - Copy (the Mac's strings where the English matches)

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

    /// Every row's title, in order, for `textFormat`.
    static func rowTitles(for textFormat: LineformTextFormat) -> [String] {
        ExportRows.rowTitles + [conversionTitle(for: textFormat)]
    }

    /// The space between the mockup's runs of rows.
    static let groupGap: CGFloat = 10

    // MARK: - Body

    var body: some View {
        WordMenuPageScaffold(title: WordMenuItem.exportPrint.title) {
            if let exportCommands {
                ForEach(PhoneExportFormat.allCases, id: \.self) { format in
                    WordMenuRow(title: format.title, accessory: .none) {
                        ExportRows.export(format, commands: exportCommands, onFailure: onDismiss)
                    }
                }
                Color.clear.frame(height: Self.groupGap)
                WordMenuRow(title: ExportRows.shareTitle, accessory: .none) {
                    ExportRows.share(commands: exportCommands, onFailure: onDismiss)
                }
                .disabled(ExportRows.isShareDisabled(exportCommands))
                WordMenuRow(title: ExportRows.printTitle, accessory: .none) {
                    ExportRows.print(commands: exportCommands)
                }
                Color.clear.frame(height: Self.groupGap)
            }
            WordMenuRow(title: Self.conversionTitle(for: document.textFormat), accessory: .none) {
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
}
