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
            // What everything below acts on: "File name", then the open document's name as a
            // button. A tap opens a wheel of the documents in place (iCloud or On My iPhone first,
            // when both exist), so a long list scrolls fast; turning it opens that document and the
            // page stays (owner review 5).
            ExportDocumentPicker(document: document, files: files)
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
    }

}

/// Export & Print's document: a small "File name" label over the open document's name, which is a
/// button. It brings up iOS's wheel from the bottom of the screen, with a location choice first
/// when iCloud and On My iPhone both show; the wheel's choice opens at once.
private struct ExportDocumentPicker: View {
    var document: OpenDocument
    var files: FilesStore
    @State private var isOpen = false
    @State private var rootID: FilesRootID?
    @Environment(\.wordMenuPalette) private var palette

    private var roots: [FilesRoot] { FilesSection.phoneRoots(files.roots).filter(\.hasScanned) }

    private var currentRootID: FilesRootID? {
        rootID ?? document.url.flatMap { files.rootID(containing: $0) } ?? roots.first?.id
    }

    private func documents(in id: FilesRootID?) -> [OutlineFileTreeItem] {
        guard let root = roots.first(where: { $0.id == id }) else { return [] }
        return FilesSection.recentDocuments(in: root.items.flatMap { item in
            item.isDirectory ? FilesSection.documentsBelow(item) : [item]
        })
    }

    var body: some View {
        let name = WordMenu.documentTitle(for: document.url)
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "File name"))
                .font(.caption.weight(.medium))
                .foregroundStyle(palette.color(palette.tertiary))
                .padding(.horizontal, 4)
            Button {
                isOpen.toggle()
            } label: {
                HStack(spacing: 6) {
                    Text(verbatim: name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                        .accessibilityHidden(true)
                }
                .font(.body.weight(.medium))
                .foregroundStyle(palette.color(palette.ink))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Capsule().fill(palette.color(palette.soft)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(String(localized: "File name")))
            .accessibilityValue(Text(verbatim: name))
            .accessibilityIdentifier("export.document")
        }
        // The native wheel, rising from the bottom of the screen as iOS's own pickers do, never
        // drawn in the page (owner review 5). A location choice first, only when both exist.
        .sheet(isPresented: $isOpen) {
            VStack(spacing: 8) {
                HStack {
                    Spacer()
                    Button(String(localized: "Done")) { isOpen = false }
                        .fontWeight(.semibold)
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                if roots.count > 1 {
                    Picker(String(localized: "File name"), selection: Binding(get: { currentRootID }, set: { rootID = $0 })) {
                        ForEach(roots) { root in
                            Text(FilesSection.heading(for: root).title).tag(Optional(root.id))
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 20)
                }
                let items = documents(in: currentRootID)
                Picker(String(localized: "File name"), selection: Binding(
                    get: { document.url?.standardizedFileURL },
                    set: { url in
                        guard let url, url != document.url?.standardizedFileURL else { return }
                        Task { await document.openReportingFailure(url) }
                    }
                )) {
                    if document.url.map({ url in !items.contains { $0.url.standardizedFileURL == url.standardizedFileURL } }) ?? true {
                        Text(verbatim: name).tag(document.url?.standardizedFileURL)
                    }
                    ForEach(items) { item in
                        Text(verbatim: item.url.deletingPathExtension().lastPathComponent)
                            .tag(Optional(item.url.standardizedFileURL))
                    }
                }
                .pickerStyle(.wheel)
                Spacer(minLength: 0)
            }
            .presentationDetents([.height(roots.count > 1 ? 330 : 290)])
            .presentationDragIndicator(.hidden)
        }
        .onChange(of: isOpen) { _, open in
            files.setVisible(open, for: .chooser)
            if open { Task { await files.scanIfVisible() } }
        }
        .onDisappear { files.setVisible(false, for: .chooser) }
        .transaction { $0.animation = nil }
    }
}
