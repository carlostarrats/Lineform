import LineformCore
import SwiftUI
import UniformTypeIdentifiers

// A stand-in for the file browser: roadmap step 6 replaces this sheet and its button. It is kept
// deliberately small.

/// The files in the save folder, newest first, kept current by a `DocumentFolderMonitor`.
@MainActor
@Observable
final class FileListModel {
    private(set) var files: [OutlineFileTreeItem] = []
    @ObservationIgnored private var folder: URL?
    @ObservationIgnored private var monitor: DocumentFolderMonitor?

    /// The extensions the list shows: Markdown and plain text.
    nonisolated static let fileExtensions: Set<String> = ["md", "markdown", "txt"]

    /// Lists `folder` and refreshes whenever its contents change, until `stop()`.
    func start(folder: URL) {
        stop()
        self.folder = folder
        let monitor = DocumentFolderMonitor(folderURL: folder) { [weak self] in
            self?.reload()
        }
        monitor.start()
        self.monitor = monitor
        reload()
    }

    func stop() {
        monitor?.stop()
        monitor = nil
        folder = nil
    }

    private func reload() {
        guard let folder else { return }
        Task {
            let entries = await Task.detached { Self.listEntries(in: folder) }.value
            guard self.folder == folder else { return }
            files = Self.sortedItems(entries, in: folder)
        }
    }

    /// One listed file: what the off-main listing hands back to the main actor.
    struct Entry: Sendable {
        var name: String
        var createdAt: Date?
        var modifiedAt: Date?
    }

    /// The Markdown and text files directly inside `folder`, newest first. A file iCloud has not
    /// downloaded yet (`.Name.md.icloud`) is listed under its real name; reading it downloads it.
    nonisolated static func listFiles(in folder: URL) -> [OutlineFileTreeItem] {
        sortedItems(listEntries(in: folder), in: folder)
    }

    nonisolated static func listEntries(in folder: URL) -> [Entry] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .creationDateKey, .isDirectoryKey]
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: []
        )) ?? []
        return contents.compactMap { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isDirectory != true,
                  let name = displayName(of: url.lastPathComponent),
                  fileExtensions.contains((name as NSString).pathExtension.lowercased())
            else { return nil }
            return Entry(name: name, createdAt: values?.creationDate, modifiedAt: values?.contentModificationDate)
        }
    }

    nonisolated static func sortedItems(_ entries: [Entry], in folder: URL) -> [OutlineFileTreeItem] {
        let items = entries.map { entry in
            OutlineFileTreeItem(
                url: folder.appendingPathComponent(entry.name),
                name: entry.name,
                isDirectory: false,
                children: [],
                createdAt: entry.createdAt,
                modifiedAt: entry.modifiedAt
            )
        }
        return OutlineFileSortOrder.sorted(items, by: .dateModified)
    }

    /// The name a directory entry stands for: an iCloud placeholder `.Name.md.icloud` stands for
    /// `Name.md`. Other hidden entries stand for nothing.
    nonisolated static func displayName(of entry: String) -> String? {
        if entry.hasPrefix("."), entry.hasSuffix(".icloud") {
            let name = String(entry.dropFirst().dropLast(".icloud".count))
            return name.isEmpty ? nil : name
        }
        return entry.hasPrefix(".") ? nil : entry
    }
}

/// The temporary file list: "New Document", "Open from Files…", and the save folder's documents.
struct FileListSheet: View {
    var document: OpenDocument
    @State private var model = FileListModel()
    @State private var isImporting = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        document.newDocument()
                        dismiss()
                    } label: {
                        Label(String(localized: "New Document"), systemImage: "square.and.pencil")
                    }
                    Button {
                        isImporting = true
                    } label: {
                        Label(String(localized: "Open from Files…"), systemImage: "folder")
                    }
                }
                Section {
                    if model.files.isEmpty {
                        Text(String(localized: "No Markdown files"))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.files) { file in
                        Button {
                            open(file.url)
                        } label: {
                            Label(file.name, systemImage: "doc.text")
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
            .navigationTitle(String(localized: "Files"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: Self.importableTypes) { result in
            if case .success(let url) = result { open(url) }
        }
        .task {
            await document.prepare()
            if let folder = document.saveFolder { model.start(folder: folder) }
        }
        .onDisappear { model.stop() }
    }

    private func open(_ url: URL) {
        document.openReportingFailure(url)
        dismiss()
    }

    static var importableTypes: [UTType] {
        [UTType("net.daringfireball.markdown"), .plainText].compactMap { $0 }
    }
}

/// The temporary Menu button: a circular floating control in the bottom-right corner, drawn with
/// the same floating-card chrome as the Mac's announcement card.
struct MenuButton: View {
    var profile: ReadingProfile
    var action: () -> Void

    static let diameter: CGFloat = 44

    var body: some View {
        let theme = Theme.theme(for: profile)
        let isDark = theme.usesDarkChrome
        Button(action: action) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color(uiColor: theme.textColor))
                .frame(width: Self.diameter, height: Self.diameter)
                .background(Circle().fill(Color(uiColor: theme.backgroundColor)))
                .overlay(
                    Circle().strokeBorder(
                        isDark
                            ? Color.white.opacity(LineformDesign.FloatingCard.hairlineOpacityDark)
                            : Color.black.opacity(LineformDesign.FloatingCard.hairlineOpacityLight),
                        lineWidth: LineformDesign.FloatingCard.hairlineWidth
                    )
                )
                .shadow(
                    color: .black.opacity(
                        isDark ? LineformDesign.FloatingCard.shadowOpacityDark
                            : LineformDesign.FloatingCard.shadowOpacityLight
                    ),
                    radius: LineformDesign.FloatingCard.shadowRadius,
                    x: LineformDesign.FloatingCard.shadowOffset.width,
                    y: LineformDesign.FloatingCard.shadowOffset.height
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Files"))
    }
}
