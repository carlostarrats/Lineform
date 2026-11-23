import LineformCore
import SwiftUI
import UniformTypeIdentifiers

/// What a Files row offers besides opening. Files can be renamed and moved to the Trash; folders
/// can only be renamed (no folder delete, as on the Mac). An iCloud placeholder (a file not
/// downloaded yet) offers neither until it has downloaded: on disk it is only its stub.
enum FilesRowAction: Equatable {
    case rename
    case delete

    /// The swipe actions: downloaded files only.
    static func swipeActions(for item: OutlineFileTreeItem) -> [FilesRowAction] {
        item.isDirectory || item.isICloudPlaceholder ? [] : [.rename, .delete]
    }

    /// The long-press menu: Rename for a folder, Rename and Delete for a file, nothing for a
    /// placeholder.
    static func menuActions(for item: OutlineFileTreeItem) -> [FilesRowAction] {
        if item.isICloudPlaceholder { return [] }
        return FilesStore.canTrash(item) ? [.rename, .delete] : [.rename]
    }
}

/// The Menu sheet's Files section: New Document and Open from Files…, the sort and Show Hidden
/// Folders, then each root (iCloud, or On My iPhone when iCloud does not resolve, and the
/// Workspace) with its top level. A folder opens as its own list with the system's sideways slide
/// (`NavigationStack`); a file opens, and the sheet closes.
///
/// Files is visible while this view is on screen, pushed folders included: only then does the
/// store look up iCloud, scan and watch.
struct FilesSection: View {
    var store: FilesStore
    var document: OpenDocument
    var onDismiss: () -> Void

    @State private var path: [FilesFolderRoute] = []
    @State private var isImportingDocument = false
    @State private var isChoosingWorkspace = false
    @State private var renaming: OutlineFileTreeItem?
    @State private var newName = ""
    @State private var deleting: OutlineFileTreeItem?
    @Environment(\.menuTheme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    // MARK: - Copy (the Mac's strings where the English matches)

    static let sortOptions = OutlineFileSortOrder.allCases
    static var sortMenuTitle: String { String(localized: "Sort folders by") }
    static func sortMenuLabel(_ order: OutlineFileSortOrder) -> String {
        String(localized: "Sort folders by: \(order.title)")
    }
    /// Above and below Choose/Change in a root's header, inside its target.
    static let headerButtonTargetPadding: CGFloat = 14
    static var hiddenFoldersTitle: String { String(localized: "Show Hidden Folders") }
    static var unavailableText: String { String(localized: "Workspace folder unavailable") }
    static var chooseTitle: String { String(localized: "Choose") }
    static var changeTitle: String { String(localized: "Change") }
    static var deleteMessage: String { String(localized: "It will be moved to the Trash.") }
    static func scannedFolderText(_ path: String) -> String { String(localized: "Scanned folder: \(path)") }
    static func deleteTitle(for name: String) -> String { String(localized: "Delete “\(name)”?") }
    static func renameTitle(isDirectory: Bool) -> String {
        isDirectory ? String(localized: "Rename Folder") : String(localized: "Rename File")
    }
    static func renameMessage(isDirectory: Bool) -> String {
        isDirectory
            ? String(localized: "Renames the folder. Its files are kept.")
            : String(localized: "Renames the file. Its contents are kept.")
    }

    /// The documents Open from Files… offers: Markdown and plain text.
    static var importableTypes: [UTType] {
        [UTType("net.daringfireball.markdown"), .plainText].compactMap { $0 }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack(path: $path) {
            list
                .navigationDestination(for: FilesFolderRoute.self) { route in
                    FolderView(store: store, route: route, actions: rowActions)
                }
                .fileImporter(isPresented: $isImportingDocument, allowedContentTypes: Self.importableTypes) { result in
                    if case .success(let url) = result { open(url) }
                }
        }
        // The folder picker sits on another view: two importers on one view shadow each other.
        .fileImporter(isPresented: $isChoosingWorkspace, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { store.chooseWorkspace(url) }
        }
        .alert(
            Self.renameTitle(isDirectory: renaming?.isDirectory ?? false),
            isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
            presenting: renaming
        ) { item in
            TextField(String(localized: "Name"), text: $newName)
            Button(String(localized: "Cancel"), role: .cancel) {}
            Button(String(localized: "Rename")) {
                let name = newName
                Task { try? await store.rename(item, to: name) }
            }
            .disabled(FileRenaming.validatedDestination(for: item.url, isDirectory: item.isDirectory, newDisplayName: newName) == nil)
        } message: { item in
            Text(Self.renameMessage(isDirectory: item.isDirectory))
        }
        .alert(
            Self.deleteTitle(for: deleting?.name ?? ""),
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { item in
            // Cancel is the default; the destructive Delete never is.
            Button(String(localized: "Cancel"), role: .cancel) {}
            Button(String(localized: "Delete"), role: .destructive) {
                Task { try? await store.trash(item) }
            }
        } message: { _ in
            Text(Self.deleteMessage)
        }
        .alert(
            store.notice ?? "",
            isPresented: Binding(get: { store.notice != nil }, set: { if !$0 { store.dismissNotice() } })
        ) {
            Button(String(localized: "OK"), role: .cancel) {}
        }
        .onAppear {
            store.openDocument = document
            store.setVisible(true, for: .files)
        }
        .task { await store.scanIfVisible() }
        .onDisappear { store.setVisible(false, for: .files) }
    }

    private var list: some View {
        List {
            Section {
                Button {
                    Task { await document.newDocument() }
                    onDismiss()
                } label: {
                    Label(String(localized: "New Document"), systemImage: "square.and.pencil")
                }
                Button {
                    isImportingDocument = true
                } label: {
                    Label(String(localized: "Open from Files…"), systemImage: "doc.badge.ellipsis")
                }
                sortMenu
                Toggle(isOn: Binding(
                    get: { store.showsHidden },
                    set: { shows in Task { await store.setShowsHidden(shows) } }
                )) {
                    Label(Self.hiddenFoldersTitle, systemImage: "eye")
                }
            }
            .listRowBackground(Color.clear)

            ForEach(store.roots) { root in
                Section {
                    rootContent(root)
                } header: {
                    rootHeader(root)
                }
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .containerBackground(.clear, for: .navigation)
        .toolbar(.hidden, for: .navigationBar)
    }

    private var sortMenu: some View {
        Menu {
            // An inline Picker, so the checkmark sits in the system's selection gutter.
            Picker(Self.sortMenuTitle, selection: Binding(
                get: { store.sortOrder },
                set: { order in Task { await store.setSort(order) } }
            )) {
                ForEach(Self.sortOptions) { order in
                    Text(order.title).tag(order)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(Self.sortMenuLabel(store.sortOrder), systemImage: "arrow.up.arrow.down")
        }
        .accessibilityLabel(Self.sortMenuTitle)
        .accessibilityValue(store.sortOrder.title)
    }

    private func rootHeader(_ root: FilesRoot) -> some View {
        let title = Label(root.title, systemImage: root.state == .unavailable ? "folder.badge.questionmark" : root.systemImage)
            .font(.subheadline.weight(.semibold))
            .accessibilityAddTraits(.isHeader)
        return Group {
            // At accessibility sizes the root's name and Choose/Change take a line each.
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    title
                    workspaceButton(root)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack {
                    title
                    Spacer(minLength: 8)
                    workspaceButton(root)
                }
            }
        }
        .textCase(nil)
    }

    @ViewBuilder
    private func workspaceButton(_ root: FilesRoot) -> some View {
        if root.id == .workspace {
            // The target reaches 44 pt inside the button; the negative padding gives the room
            // back, so the header keeps its height.
            Button {
                isChoosingWorkspace = true
            } label: {
                Text(root.state == .unassigned ? Self.chooseTitle : Self.changeTitle)
                    .padding(.vertical, Self.headerButtonTargetPadding)
                    .contentShape(Rectangle())
            }
            .font(.subheadline)
            .padding(.vertical, -Self.headerButtonTargetPadding)
        }
    }

    @ViewBuilder
    private func rootContent(_ root: FilesRoot) -> some View {
        switch root.state {
        case .unassigned:
            EmptyView()
        case .unavailable:
            // The header offers Change; the body says why and offers Choose. Both open the picker.
            VStack(alignment: .leading, spacing: 8) {
                Text(Self.unavailableText)
                    .foregroundStyle(PhoneInk.menu(theme).secondary)
                Button(Self.chooseTitle) { isChoosingWorkspace = true }
                    .buttonStyle(.bordered)
            }
        case .available, .disconnected:
            if !root.hasScanned {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if root.items.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "No Markdown files"))
                    // Naming the scanned folder is what tells "this folder is empty" apart from
                    // "this is not the folder you think it is" (files-sidebar.md).
                    if root.id == .workspace, let path = root.folderURL?.path {
                        Text(Self.scannedFolderText(path))
                            .font(.footnote)
                            .lineLimit(2)
                            .truncationMode(.head)
                            .textSelection(.enabled)
                    }
                }
                .foregroundStyle(PhoneInk.menu(theme).secondary)
            } else {
                ForEach(root.items) { item in
                    FilesItemRow(item: item, sortOrder: store.sortOrder, actions: rowActions)
                }
            }
        }
    }

    // MARK: - Actions

    private var rowActions: FilesRowHandlers {
        FilesRowHandlers(
            open: { item in open(item.url) },
            rename: { item in
                newName = FileRenaming.displayName(for: item.url, isDirectory: item.isDirectory)
                renaming = item
            },
            delete: { item in deleting = item }
        )
    }

    /// Opens a file and closes the sheet. A file iCloud has not downloaded is downloaded first;
    /// the document shows its downloading state meanwhile.
    private func open(_ url: URL) {
        Task { await document.openReportingFailure(url) }
        onDismiss()
    }
}

/// A folder pushed onto the Files stack.
struct FilesFolderRoute: Hashable {
    var url: URL
    var title: String
}
