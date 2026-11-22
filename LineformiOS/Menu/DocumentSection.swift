import LineformCore
import SwiftUI

/// The Menu sheet's Document section: the document's own commands, then the help pages.
///
/// - New Document and Open from Files… (as in Files).
/// - Insert Table and Reformat Table, for Markdown only (the Mac shows its formatting commands
///   for Markdown only too).
/// - Convert to Plain Text, or Convert to Markdown once converted: the title follows the
///   document's format (`OpenDocument.textFormat`). A `.txt` opened from disk has no conversion to
///   restore, so the row is off.
/// - Check Document Now: one spelling pass over the whole document (`SpellCheckPass`).
/// - Export As, Print…, Share… and read aloud (`ExportRows`, roadmap step 10), as their own
///   section.
/// - Show Hidden Folders: the Files setting (`FilesStore.setShowsHidden`, the Mac's key).
/// - Lineform Guide, Privacy Policy and Terms of Use open in Safari (`openURL`) at the
///   package's `LineformLinks`.
///
/// Every command applies to the whole document: a Write selection is not on screen under the
/// sheet. Commands that change the page (a table, a misspelling) close the sheet so the writer
/// sees the result; Convert keeps it open, so the title's change is seen and can be undone.
struct DocumentSection: View {
    var document: OpenDocument
    var editor: any EditorCommands
    var files: FilesStore
    var onDismiss: () -> Void
    /// The screen's export commands; nil until the screen has made them (no export rows then).
    var exportCommands: ExportCommands? = nil
    /// The editor's selection, for read aloud.
    var selection: () -> NSRange? = { nil }
    var mode: EditorDisplayMode = .write

    @Environment(\.openURL) private var openURL
    @State private var isImportingDocument = false

    // MARK: - Copy (the Mac's strings where the English matches)

    static var newDocumentTitle: String { String(localized: "New Document") }
    static var openTitle: String { String(localized: "Open from Files…") }
    static var insertTableTitle: String { String(localized: "Insert Table") }
    static var reformatTableTitle: String { String(localized: "Reformat Table") }
    static var checkDocumentTitle: String { String(localized: "Check Document Now") }
    static var guideTitle: String { String(localized: "Lineform Guide") }
    static var privacyPolicyTitle: String { String(localized: "Privacy Policy") }
    static var termsOfUseTitle: String { String(localized: "Terms of Use") }

    /// The Mac's `AppMenuConfiguration.conversionCommandTitle`: what the command turns the
    /// document into.
    static func conversionTitle(for textFormat: LineformTextFormat) -> String {
        switch textFormat {
        case .markdown: String(localized: "Convert to Plain Text")
        case .plainText: String(localized: "Convert to Markdown")
        }
    }

    /// Insert Table and Reformat Table are Markdown commands.
    static func showsTableCommands(for textFormat: LineformTextFormat) -> Bool {
        textFormat == .markdown
    }

    static let guideURL = URL(string: LineformLinks.guideURL)!
    static let privacyPolicyURL = URL(string: LineformLinks.privacyPolicyURL)!
    static let termsOfUseURL = URL(string: LineformLinks.termsOfUseURL)!

    /// Every row's title, in order, for `textFormat`.
    static func rowTitles(for textFormat: LineformTextFormat) -> [String] {
        var titles = [newDocumentTitle, openTitle]
        if showsTableCommands(for: textFormat) { titles += [insertTableTitle, reformatTableTitle] }
        titles += [conversionTitle(for: textFormat), checkDocumentTitle]
        titles += ExportRows.idleRowTitles
        titles += [FilesSection.hiddenFoldersTitle, guideTitle, privacyPolicyTitle, termsOfUseTitle]
        return titles
    }

    // MARK: - Body

    var body: some View {
        List {
            Section {
                Button {
                    Task { await document.newDocument() }
                    onDismiss()
                } label: {
                    Label(Self.newDocumentTitle, systemImage: "square.and.pencil")
                }
                Button {
                    isImportingDocument = true
                } label: {
                    Label(Self.openTitle, systemImage: "doc.badge.ellipsis")
                }
            }
            .listRowBackground(Color.clear)

            Section {
                if Self.showsTableCommands(for: document.textFormat) {
                    Button {
                        editor.insertTable()
                        onDismiss()
                    } label: {
                        Label(Self.insertTableTitle, systemImage: "tablecells")
                    }
                    Button {
                        editor.reformatTable()
                        onDismiss()
                    } label: {
                        Label(Self.reformatTableTitle, systemImage: "tablecells.badge.ellipsis")
                    }
                }
                Button {
                    switch document.textFormat {
                    case .markdown: document.convertToPlainText()
                    case .plainText: document.restoreMarkdown()
                    }
                } label: {
                    Label(Self.conversionTitle(for: document.textFormat), systemImage: "textformat")
                }
                .disabled(!document.canConvertTextFormat)
                Button {
                    onDismiss()
                    editor.checkDocumentNow()
                } label: {
                    Label(Self.checkDocumentTitle, systemImage: "textformat.abc.dottedunderline")
                }
            }
            .listRowBackground(Color.clear)

            if let exportCommands {
                ExportRows(commands: exportCommands, selection: selection, mode: mode)
                    .listRowBackground(Color.clear)
            }

            Section {
                Toggle(isOn: Binding(
                    get: { files.showsHidden },
                    set: { shows in Task { await files.setShowsHidden(shows) } }
                )) {
                    Label(FilesSection.hiddenFoldersTitle, systemImage: "eye")
                }
            }
            .listRowBackground(Color.clear)

            Section {
                link(Self.guideTitle, systemImage: "book", url: Self.guideURL)
                link(Self.privacyPolicyTitle, systemImage: "hand.raised", url: Self.privacyPolicyURL)
                link(Self.termsOfUseTitle, systemImage: "doc.plaintext", url: Self.termsOfUseURL)
            }
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .fileImporter(isPresented: $isImportingDocument, allowedContentTypes: FilesSection.importableTypes) { result in
            guard case .success(let url) = result else { return }
            Task { await document.openReportingFailure(url) }
            onDismiss()
        }
    }

    private func link(_ title: String, systemImage: String, url: URL) -> some View {
        Button {
            openURL(url)
        } label: {
            Label(title, systemImage: systemImage)
        }
        .accessibilityAddTraits(.isLink)
    }
}
