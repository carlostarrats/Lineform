import LineformCore
import SwiftUI
import UniformTypeIdentifiers

// The Files section until roadmap step 6's Task 3 replaces it with the Files tree: the earlier
// temporary file list ("New Document", "Open from Files…" and the save folder's documents), moved
// here from the old FileListSheet so nothing regresses meanwhile. Kept deliberately small.

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

/// The Files section's interim contents: "New Document", "Open from Files…", and the save
/// folder's documents. Opening or creating a document closes the sheet.
struct MenuFilesPlaceholder: View {
    var document: OpenDocument
    var onDismiss: () -> Void
    @State private var model = FileListModel()
    @State private var isImporting = false

    var body: some View {
        List {
            Section {
                Button {
                    Task { await document.newDocument() }
                    onDismiss()
                } label: {
                    Label(String(localized: "New Document"), systemImage: "square.and.pencil")
                }
                Button {
                    isImporting = true
                } label: {
                    Label(String(localized: "Open from Files…"), systemImage: "folder")
                }
            .listRowBackground(Color.clear)
            }
            .listRowBackground(Color.clear)
            Section {
                if model.files.isEmpty {
                    Text(String(localized: "No Markdown files"))
                        .opacity(0.6)
                }
                ForEach(model.files) { file in
                    Button {
                        open(file.url)
                    } label: {
                        Label(file.name, systemImage: "doc.text")
                    }
                }
            }
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .fileImporter(isPresented: $isImporting, allowedContentTypes: Self.importableTypes) { result in
            if case .success(let url) = result { open(url) }
        }
        .task {
            // Shares the screen's folder resolution, so a sheet opened at launch waits for the
            // folder instead of listing nothing.
            model.start(folder: await document.resolveSaveFolder())
        }
        .onDisappear { model.stop() }
    }

    private func open(_ url: URL) {
        Task { await document.openReportingFailure(url) }
        onDismiss()
    }

    static var importableTypes: [UTType] {
        [UTType("net.daringfireball.markdown"), .plainText].compactMap { $0 }
    }
}
