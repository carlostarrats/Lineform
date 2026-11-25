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
    /// The documents the chooser lists.
    var files: FilesStore
    /// The screen's export commands; nil until the screen has made them (no export rows then).
    var exportCommands: ExportCommands?
    var onDismiss: () -> Void
    @State private var isChoosing = false

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
            // What everything below acts on: the open document, by name. A tap lists every
            // document to pick another (owner review 5), which then opens, and this page stays.
            WordMenuRow(
                title: WordMenu.documentTitle(for: document.url),
                accessory: .text(Self.changeTitle)
            ) { isChoosing = true }
            .accessibilityLabel(Text(Self.documentLabel(WordMenu.documentTitle(for: document.url))))
            .accessibilityIdentifier("export.document")
            Color.clear.frame(height: Self.groupGap)
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
        .sheet(isPresented: $isChoosing) {
            ExportDocumentChooser(files: files, current: document.url) { url in
                isChoosing = false
                guard url != document.url else { return }
                Task { await document.openReportingFailure(url) }
            }
        }
    }

    static var changeTitle: String { String(localized: "Change") }
    static func documentLabel(_ name: String) -> String { String(localized: "Document: \(name)") }
}

/// Export & Print's chooser: every document, under iCloud and On My iPhone, newest first in each,
/// in one scrolling list (no menu). The open one carries a tick.
private struct ExportDocumentChooser: View {
    var files: FilesStore
    var current: URL?
    var onChoose: (URL) -> Void
    @Environment(\.wordMenuPalette) private var palette

    var body: some View {
        NavigationStack {
            List {
                ForEach(FilesSection.phoneRoots(files.roots)) { root in
                    let documents = FilesSection.recentDocuments(in: root.items.flatMap { item in
                        item.isDirectory ? FilesSection.documentsBelow(item) : [item]
                    })
                    Section(FilesSection.heading(for: root).title) {
                        if !root.hasScanned {
                            ProgressView()
                        }
                        ForEach(documents) { item in
                            Button {
                                onChoose(item.url)
                            } label: {
                                HStack {
                                    Text(verbatim: item.url.deletingPathExtension().lastPathComponent)
                                        .foregroundStyle(.primary)
                                    Spacer(minLength: 8)
                                    if item.url.standardizedFileURL == current?.standardizedFileURL {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(palette.color(palette.blueMark))
                                            .accessibilityLabel(Text(String(localized: "Open now")))
                                    } else if let when = FilesDocumentRows.when(item) {
                                        Text(verbatim: when)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "Choose a Document"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear { files.setVisible(true, for: .chooser) }
        .onDisappear { files.setVisible(false, for: .chooser) }
        .task { await files.scanIfVisible() }
    }
}
