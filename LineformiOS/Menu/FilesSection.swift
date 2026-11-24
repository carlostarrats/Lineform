import LineformCore
import SwiftUI
import UniformTypeIdentifiers

/// What a Files item offers besides opening. Files can be renamed and moved to the Trash; folders
/// can only be renamed (no folder delete, as on the Mac). An iCloud placeholder (a file not
/// downloaded yet) offers neither until it has downloaded: on disk it is only its stub.
enum FilesRowAction: Equatable {
    case rename
    case delete

    /// The quick actions (a card's ⋯): downloaded files only.
    static func swipeActions(for item: OutlineFileTreeItem) -> [FilesRowAction] {
        item.isDirectory || item.isICloudPlaceholder ? [] : [.rename, .delete]
    }

    /// The long-press menu: Rename for a folder, Rename and Move to Trash for a file, nothing for
    /// a placeholder.
    static func menuActions(for item: OutlineFileTreeItem) -> [FilesRowAction] {
        if item.isICloudPlaceholder { return [] }
        return FilesStore.canTrash(item) ? [.rename, .delete] : [.rename]
    }

    var title: String {
        switch self {
        case .rename: String(localized: "Rename…")
        case .delete: String(localized: "Move to Trash")
        }
    }

    var systemImage: String {
        switch self {
        case .rename: "pencil"
        case .delete: "trash"
        }
    }
}

/// The rename and Trash confirmations Files and its folders share. The menu owns the alerts
/// (`filesItemAlerts`), so a card's ⋯ on any page asks the same way.
@MainActor
@Observable
final class FilesItemActions {
    var renaming: OutlineFileTreeItem?
    var newName = ""
    var deleting: OutlineFileTreeItem?
    /// New Folder asked for a name to create inside this folder.
    var creatingFolderIn: URL?
    var newFolderName = ""

    func newFolder(in parent: URL) {
        newFolderName = ""
        creatingFolderIn = parent
    }

    func perform(_ action: FilesRowAction, on item: OutlineFileTreeItem) {
        switch action {
        case .rename:
            newName = FileRenaming.displayName(for: item.url, isDirectory: item.isDirectory)
            renaming = item
        case .delete:
            deleting = item
        }
    }
}

extension View {
    /// The rename field, the Trash confirmation (Cancel the default) and the store's notice.
    func filesItemAlerts(_ actions: FilesItemActions, store: FilesStore) -> some View {
        modifier(FilesItemAlerts(actions: actions, store: store))
    }
}

private struct FilesItemAlerts: ViewModifier {
    @Bindable var actions: FilesItemActions
    var store: FilesStore

    func body(content: Content) -> some View {
        content
            .alert(
                FilesSection.renameTitle(isDirectory: actions.renaming?.isDirectory ?? false),
                isPresented: Binding(get: { actions.renaming != nil }, set: { if !$0 { actions.renaming = nil } }),
                presenting: actions.renaming
            ) { item in
                TextField(String(localized: "Name"), text: $actions.newName)
                Button(String(localized: "Cancel"), role: .cancel) {}
                Button(String(localized: "Rename")) {
                    let name = actions.newName
                    Task { try? await store.rename(item, to: name) }
                }
                .disabled(FileRenaming.validatedDestination(
                    for: item.url, isDirectory: item.isDirectory, newDisplayName: actions.newName
                ) == nil)
            } message: { item in
                Text(FilesSection.renameMessage(isDirectory: item.isDirectory))
            }
            .alert(
                FilesSection.deleteTitle(for: actions.deleting?.name ?? ""),
                isPresented: Binding(get: { actions.deleting != nil }, set: { if !$0 { actions.deleting = nil } }),
                presenting: actions.deleting
            ) { item in
                // Cancel is the default; the destructive button never is.
                Button(String(localized: "Cancel"), role: .cancel) {}
                Button(FilesRowAction.delete.title, role: .destructive) {
                    Task { try? await store.trash(item) }
                }
            } message: { _ in
                Text(FilesSection.deleteMessage)
            }
            .alert(
                FilesSection.newFolderTitle,
                isPresented: Binding(get: { actions.creatingFolderIn != nil }, set: { if !$0 { actions.creatingFolderIn = nil } }),
                presenting: actions.creatingFolderIn
            ) { parent in
                TextField(String(localized: "Name"), text: $actions.newFolderName)
                Button(String(localized: "Cancel"), role: .cancel) {}
                Button(String(localized: "Create")) {
                    let name = actions.newFolderName
                    Task { try? await store.createFolder(named: name, in: parent) }
                }
                .disabled(FilesStore.newFolderDestination(named: actions.newFolderName, in: parent) == nil)
            } message: { _ in
                Text(FilesSection.newFolderMessage)
            }
            .alert(
                store.notice ?? "",
                isPresented: Binding(get: { store.notice != nil }, set: { if !$0 { store.dismissNotice() } })
            ) {
                Button(String(localized: "OK"), role: .cancel) {}
            }
    }
}

/// The word menu's Files: the search field at the top (results are document cards with the
/// matching line), then each root — "iCloud" (or On My iPhone when iCloud does not resolve, and
/// the Workspace) — with its folders as plain rows (icon, name, count, chevron) and its own
/// documents as cards under "Recent", newest first. A folder opens its page of cards; a card
/// opens its document and the menu closes. Open from Files… and New Document close the page.
///
/// The menu keeps the store visible (scanning and watching) while Files or a folder is on screen.
struct FilesSection: View {
    var store: FilesStore
    var document: OpenDocument
    var editor: (any EditorCommands)?
    var actions: FilesItemActions
    var onOpenFolder: (FilesFolderRoute) -> Void
    var onDismiss: () -> Void

    @State private var isImportingDocument = false
    @State private var isChoosingWorkspace = false
    @State private var search: SearchController?
    @State private var query = ""
    @FocusState private var isSearchFocused: Bool
    @Environment(\.wordMenuPalette) private var palette

    init(
        store: FilesStore,
        document: OpenDocument,
        editor: (any EditorCommands)? = nil,
        actions: FilesItemActions = FilesItemActions(),
        onOpenFolder: @escaping (FilesFolderRoute) -> Void = { _ in },
        onDismiss: @escaping () -> Void
    ) {
        self.store = store
        self.document = document
        self.editor = editor
        self.actions = actions
        self.onOpenFolder = onOpenFolder
        self.onDismiss = onDismiss
    }

    // MARK: - Copy (the Mac's strings where the English matches)

    static let sortOptions = OutlineFileSortOrder.allCases
    static var sortMenuTitle: String { String(localized: "Sort folders by") }
    static func sortMenuLabel(_ order: OutlineFileSortOrder) -> String {
        String(localized: "Sort folders by: \(order.title)")
    }
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
    static var newDocumentTitle: String { String(localized: "New Document") }
    static var newFolderTitle: String { String(localized: "New Folder") }
    static var newFolderMessage: String { String(localized: "Name the new folder.") }
    static func addMenuLabel(for place: String) -> String { String(localized: "Add to \(place)") }
    static var openTitle: String { String(localized: "Open from Files…") }
    static var recentTitle: String { String(localized: "Recent") }
    static var searchPrompt: String { String(localized: "Search all documents") }
    /// The iCloud root's heading: the place, not the folder's name.
    static var iCloudHeading: String { String(localized: "iCloud") }

    /// The documents Open from Files… offers: Markdown and plain text.
    static var importableTypes: [UTType] {
        [UTType("net.daringfireball.markdown"), .plainText].compactMap { $0 }
    }

    /// A root's heading and its icon: iCloud with a cloud, On My iPhone, the Workspace.
    static func heading(for root: FilesRoot) -> (title: String, systemImage: String) {
        switch root.id {
        case .icloud: (iCloudHeading, "icloud")
        case .device: (root.title, "iphone")
        case .workspace: (root.title, root.state == .unavailable ? "folder.badge.questionmark" : root.systemImage)
        }
    }

    /// A root's or folder's documents for its cards: files only, newest first (a file with no date
    /// last), then by name.
    static func recentDocuments(in items: [OutlineFileTreeItem]) -> [OutlineFileTreeItem] {
        items.filter { !$0.isDirectory }.sorted { lhs, rhs in
            switch (lhs.modifiedAt, rhs.modifiedAt) {
            case let (l?, r?) where l != r: return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
    }

    /// How many documents a folder row counts: the files directly inside it.
    static func documentCount(in folder: OutlineFileTreeItem, store: FilesStore) -> Int {
        (store.children(of: folder.url) ?? folder.children).filter { !$0.isDirectory }.count
    }

    // MARK: - Body

    var body: some View {
        WordMenuPageScaffold(title: WordMenuItem.files.title) {
            searchField
            if hasQuery, let search {
                FilesSearchResults(controller: search, document: document, store: store, onDismiss: onDismiss)
            } else {
                roots
                WordMenuRow(title: Self.openTitle, systemImage: "doc.badge.ellipsis", accessory: .none) {
                    isImportingDocument = true
                }
                .padding(.top, 14)
                WordMenuPrimaryButton(title: Self.newDocumentTitle, systemImage: "plus") {
                    newDocument()
                }
            }
        }
        .fileImporter(isPresented: $isImportingDocument, allowedContentTypes: Self.importableTypes) { result in
            if case .success(let url) = result { open(url) }
        }
        .background {
            // The folder picker sits on another view: two importers on one view shadow each other.
            Color.clear
                .fileImporter(isPresented: $isChoosingWorkspace, allowedContentTypes: [.folder]) { result in
                    if case .success(let url) = result { store.chooseWorkspace(url) }
                }
        }
        .onChange(of: document.text) { search?.textChanged() }
        .onChange(of: store.roots) { search?.rootsChanged() }
        .onDisappear { search?.stop() }
    }

    private var hasQuery: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(palette.color(palette.secondary))
                .accessibilityHidden(true)
            TextField(
                text: Binding(get: { query }, set: { setQuery($0) }),
                prompt: Text(Self.searchPrompt).foregroundStyle(palette.color(palette.tertiary))
            ) {
                Text(Self.searchPrompt)
            }
            .focused($isSearchFocused)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.search)
            .foregroundStyle(palette.color(palette.ink))
            if hasQuery {
                Button {
                    setQuery("")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(palette.color(palette.icon))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Clear search"))
            }
        }
        .wordMenuField()
        .padding(.bottom, 4)
    }

    /// The search is made on the first query (never in `init`), and reaches every file and this
    /// document (`SearchFilter.all`).
    private func setQuery(_ newQuery: String) {
        query = newQuery
        if search == nil, !newQuery.isEmpty {
            search = SearchController(
                editor: editor ?? NoEditorCommands(document: document),
                files: store,
                currentURL: { [weak document] in document?.url },
                open: SearchController.opener(for: document)
            )
        }
        search?.setQuery(newQuery)
    }

    @ViewBuilder
    private var roots: some View {
        ForEach(store.roots) { root in
            rootSection(root)
        }
    }

    @ViewBuilder
    private func rootSection(_ root: FilesRoot) -> some View {
        let heading = Self.heading(for: root)
        HStack(alignment: .center) {
            WordMenuGroupLabel(title: heading.title, systemImage: heading.systemImage)
            Spacer(minLength: 8)
            if root.id == .workspace {
                Button {
                    isChoosingWorkspace = true
                } label: {
                    Text(root.state == .unassigned ? Self.chooseTitle : Self.changeTitle)
                        .font(.subheadline)
                        .foregroundStyle(palette.color(palette.blueText))
                        .frame(minWidth: WordMenuMetrics.minimumTarget, minHeight: WordMenuMetrics.minimumTarget, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
            } else if let folder = root.folderURL, root.state == .available {
                // New Document and New Folder at the top of iCloud or On My iPhone: a document
                // made here saves here.
                Menu {
                    Button {
                        newDocument(in: folder)
                    } label: {
                        Label(Self.newDocumentTitle, systemImage: "square.and.pencil")
                    }
                    Button {
                        actions.newFolder(in: folder)
                    } label: {
                        Label(Self.newFolderTitle, systemImage: "folder.badge.plus")
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(palette.color(palette.blueMark))
                        .frame(width: WordMenuMetrics.minimumTarget, height: WordMenuMetrics.minimumTarget)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(Self.addMenuLabel(for: heading.title))
                .accessibilityIdentifier("files.add.\(root.id.rawValue)")
                .padding(.top, 6)
            }
        }
        switch root.state {
        case .unassigned:
            EmptyView()
        case .unavailable:
            WordMenuNote(text: Self.unavailableText)
        case .available, .disconnected:
            if !root.hasScanned {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
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
                .font(.subheadline)
                .foregroundStyle(palette.color(palette.secondary))
                .padding(.horizontal, 4)
            } else {
                FilesFolderRows(items: root.items, store: store, actions: actions, onOpenFolder: onOpenFolder)
                let documents = Self.recentDocuments(in: root.items)
                if !documents.isEmpty {
                    WordMenuGroupLabel(title: Self.recentTitle)
                    WordMenuCardGrid(items: documents) { item in
                        DocumentCard(item: item, document: document, store: store, actions: actions) { open(item.url) }
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func newDocument(in folder: URL? = nil) {
        Task { await document.newDocument(in: folder) }
        onDismiss()
    }

    /// Opens a file and closes the menu. A file iCloud has not downloaded is downloaded first;
    /// the document shows its downloading state meanwhile.
    private func open(_ url: URL) {
        Task { await document.openReportingFailure(url) }
        onDismiss()
    }
}

/// A folder pushed onto the menu's stack.
struct FilesFolderRoute: Hashable {
    var url: URL
    var title: String
}

/// A level's folders as plain rows: the folder icon close to the name, the count of its documents
/// on the right, a chevron. A long press offers Rename.
struct FilesFolderRows: View {
    var items: [OutlineFileTreeItem]
    var store: FilesStore
    var actions: FilesItemActions
    var onOpenFolder: (FilesFolderRoute) -> Void

    var body: some View {
        let folders = items.filter(\.isDirectory)
        if !folders.isEmpty {
            VStack(spacing: 6) {
                ForEach(folders) { folder in
                    Button {
                        onOpenFolder(FilesFolderRoute(url: folder.url, title: folder.name))
                    } label: {
                        WordMenuRowLabel(
                            title: folder.name,
                            systemImage: "folder",
                            accessory: .chevron,
                            count: FilesSection.documentCount(in: folder, store: store)
                        )
                        .opacity(folder.isHidden ? 0.7 : 1)
                    }
                    .buttonStyle(WordMenuPressStyle())
                    .accessibilityValue(FilesRow.accessibilityValue(for: folder).map { Text($0) } ?? Text(verbatim: ""))
                    .filesSwipeAccessibilityActions(FilesSwipeAction.actions(for: folder, store: store))
                    .filesSwipeActions(FilesSwipeAction.actions(for: folder, store: store))
                    .contextMenu {
                        ForEach(FilesRowAction.menuActions(for: folder), id: \.self) { action in
                            Button {
                                actions.perform(action, on: folder)
                            } label: {
                                Label(action.title, systemImage: action.systemImage)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// One swipe action on a card or folder row: Move to Trash (red), or a move between iCloud and On
/// My iPhone.
struct FilesSwipeAction: Identifiable {
    enum Kind: Hashable {
        case trash
        case move(FilesRootID)
    }

    var kind: Kind
    var perform: () -> Void
    var id: Kind { kind }

    var title: String {
        switch kind {
        case .trash: FilesRowAction.delete.title
        case .move(.icloud): String(localized: "Move to iCloud")
        case .move: String(localized: "Move to On My iPhone")
        }
    }

    var systemImage: String {
        switch kind {
        case .trash: "trash"
        case .move(.icloud): "icloud.and.arrow.up"
        case .move: "iphone"
        }
    }

    var isDestructive: Bool { kind == .trash }

    /// The swipe actions for `item`, like Mail's: Move to Trash for a downloaded file (never a
    /// folder), then the move to the other root where it can go. Trash and the move act at once
    /// (both reversible: the Trash, or moving back); a failure shows the store's notice.
    @MainActor
    static func actions(for item: OutlineFileTreeItem, store: FilesStore) -> [FilesSwipeAction] {
        var actions: [FilesSwipeAction] = []
        if FilesRowAction.swipeActions(for: item).contains(.delete) {
            actions.append(FilesSwipeAction(kind: .trash) { Task { try? await store.trash(item) } })
        }
        for target in store.moveTargets(for: item) {
            actions.append(FilesSwipeAction(kind: .move(target)) { Task { try? await store.move(item, to: target) } })
        }
        return actions
    }
}

extension View {
    /// Swipe left to reveal `actions` at the trailing edge. The item's own accessibility element
    /// carries them as custom actions (`filesSwipeAccessibilityActions`).
    func filesSwipeActions(_ actions: [FilesSwipeAction]) -> some View {
        modifier(FilesSwipeActions(actions: actions))
    }

    /// The swipe actions as VoiceOver custom actions, on the element VoiceOver visits.
    func filesSwipeAccessibilityActions(_ actions: [FilesSwipeAction]) -> some View {
        accessibilityActions {
            ForEach(actions) { action in
                Button(action.title) { action.perform() }
            }
        }
    }
}

private struct FilesSwipeActions: ViewModifier {
    var actions: [FilesSwipeAction]
    @State private var offset: CGFloat = 0
    @State private var dragStart: CGFloat?
    @Environment(\.wordMenuPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let buttonWidth: CGFloat = 76
    static let spacing: CGFloat = 6

    private var revealWidth: CGFloat {
        CGFloat(actions.count) * Self.buttonWidth + CGFloat(actions.count) * Self.spacing
    }

    func body(content: Content) -> some View {
        if actions.isEmpty {
            content
        } else {
            ZStack(alignment: .trailing) {
                HStack(spacing: Self.spacing) {
                    ForEach(actions) { action in
                        Button {
                            close()
                            action.perform()
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: action.systemImage)
                                    .font(.body.weight(.medium))
                                Text(action.title)
                                    .font(.caption2.weight(.semibold))
                                    .multilineTextAlignment(.center)
                                    .minimumScaleFactor(0.8)
                            }
                            .foregroundStyle(.white)
                            .padding(4)
                            .frame(width: Self.buttonWidth)
                            .frame(maxHeight: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: WordMenuMetrics.rowRadius, style: .continuous)
                                    .fill(action.isDestructive ? Color(red: 0.79, green: 0.23, blue: 0.23) : palette.color(palette.blueFill))
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityHidden(true)
                    }
                }
                .opacity(offset < 0 ? 1 : 0)
                content
                    .offset(x: offset)
                    .overlay {
                        if offset < 0 {
                            // While open, a tap on the item closes the actions instead of opening it.
                            Color.clear
                                .contentShape(Rectangle())
                                .offset(x: offset)
                                .onTapGesture { close() }
                        }
                    }
            }
            .clipped()
            // A UIKit pan that begins only for a sideways movement, so the page still scrolls
            // when a vertical drag starts on a card.
            .gesture(
                HorizontalPanGesture(
                    onChange: { translation in
                        let start = dragStart ?? offset
                        dragStart = start
                        offset = min(0, max(-revealWidth - 24, start + translation))
                    },
                    onEnd: { _, velocity in
                        dragStart = nil
                        let opens = offset < -revealWidth / 2 || velocity < -600
                        withAnimation(EditorMotionPolicy.animation(.easeOut(duration: 0.18), reduceMotion: reduceMotion)) {
                            offset = opens ? -revealWidth : 0
                        }
                    }
                )
            )
        }
    }

    private func close() {
        withAnimation(EditorMotionPolicy.animation(.easeOut(duration: 0.18), reduceMotion: reduceMotion)) {
            offset = 0
        }
    }
}

/// A pan that begins only when the finger moves sideways (more across than down), so it never
/// takes a scroll from the page around it.
private struct HorizontalPanGesture: UIGestureRecognizerRepresentable {
    var onChange: (CGFloat) -> Void
    var onEnd: (_ translation: CGFloat, _ velocity: CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let translation = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .changed:
            onChange(translation)
        case .ended, .cancelled, .failed:
            onEnd(translation, recognizer.velocity(in: recognizer.view).x)
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y) * 1.5
        }
    }
}

/// What a file or folder says without words, and the date a list sorted by date shows.
enum FilesRow {
    /// What VoiceOver adds after an item's name: "Hidden", "Not downloaded", both, or nothing.
    static func accessibilityValue(for item: OutlineFileTreeItem) -> String? {
        switch (item.isHidden, item.isICloudPlaceholder) {
        case (true, true): String(localized: "Hidden, not downloaded")
        case (true, false): String(localized: "Hidden")
        case (false, true): String(localized: "Not downloaded")
        case (false, false): nil
        }
    }

    /// A name shows on one line, cut in the middle; at accessibility sizes up to three.
    static func nameLineLimit(for dynamicTypeSize: DynamicTypeSize) -> Int {
        dynamicTypeSize.isAccessibilitySize ? 3 : 1
    }

    /// The date the sort is in order of, so none for a name sort or a folder.
    static func shownDate(for item: OutlineFileTreeItem, sortOrder: OutlineFileSortOrder) -> Date? {
        guard !item.isDirectory else { return nil }
        switch sortOrder {
        case .name: return nil
        case .dateCreated: return item.createdAt
        case .dateModified: return item.modifiedAt
        }
    }

    static func systemImage(for item: OutlineFileTreeItem) -> String {
        item.isDirectory ? "folder" : "doc.text"
    }
}

/// Search without a live editor (a hosted Files page): this document's text, and no edits.
@MainActor
private struct NoEditorCommands: EditorCommands {
    var document: OpenDocument
    var currentText: String { document.text }
    func scrollToCharacterRange(_ range: NSRange) {}
    func selectRange(_ range: NSRange) {}
    func insertTable() {}
    func reformatTable() {}
    func replace(range: NSRange, with replacement: String) -> Bool { false }
    func replaceAll(ranges: [NSRange], with replacement: String) -> Bool { false }
}
