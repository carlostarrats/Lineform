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
                store.notice ?? "",
                isPresented: Binding(get: { store.notice != nil }, set: { if !$0 { store.dismissNotice() } })
            ) {
                Button(String(localized: "OK"), role: .cancel) {}
            }
    }
}

/// The word menu's Files, as in the owner's mockup (2026-11-24): the search field at the top
/// (with its scope button; results are document cards with the matching line), then the "iCloud"
/// heading (cloud icon) with its folders as plain rows (icon, name, count, chevron) and its own
/// documents as cards, the "On My iPhone" heading (phone icon) with its folders and documents,
/// then "Recent": both roots' own documents as
/// cards, newest first. Each root's heading has a "+" on a grey round background that makes a new
/// document in that root. A folder opens its page of cards; a card opens its document and the
/// menu closes.
///
/// Nothing else: no Open from Files…, no New Document row, no New Folder (the Mac has none), and
/// no Workspace. The store still models a Workspace root (`FilesStore.roots`), dormant: the iPhone
/// shows only `phoneRoots` and searches nothing else.
///
/// The menu keeps the store visible (scanning and watching) while Files or a folder is on screen.
struct FilesSection: View {
    var store: FilesStore
    var document: OpenDocument
    var editor: (any EditorCommands)?
    var actions: FilesItemActions
    var onOpenFolder: (FilesFolderRoute) -> Void
    var onDismiss: () -> Void

    /// The search's text, scope, replace row and controller live in the menu's session, so the
    /// menu reopens on them (the ← after a card opened a document).
    var externalSession: WordMenuSession?
    @State private var ownSession = WordMenuSession()
    /// The roots the writer collapsed (their raw ids, comma-separated), kept on this device.
    @AppStorage("Lineform.files.collapsedRoots") private var collapsedRoots = ""

    private func isCollapsed(_ id: FilesRootID) -> Bool {
        collapsedRoots.split(separator: ",").contains { $0 == id.rawValue }
    }

    private func toggleCollapsed(_ id: FilesRootID) {
        var ids = Set(collapsedRoots.split(separator: ",").map(String.init))
        if ids.contains(id.rawValue) { ids.remove(id.rawValue) } else { ids.insert(id.rawValue) }
        collapsedRoots = ids.sorted().joined(separator: ",")
    }
    private var session: WordMenuSession { externalSession ?? ownSession }
    private var search: SearchController? {
        get { session.search }
        nonmutating set { session.search = newValue }
    }
    private var query: String {
        get { session.filesQuery }
        nonmutating set { session.filesQuery = newValue }
    }
    private var scope: FilesSearchScope {
        get { session.filesScope }
        nonmutating set { session.filesScope = newValue }
    }
    private var isReplaceShown: Bool {
        get { session.isReplaceShown }
        nonmutating set { session.isReplaceShown = newValue }
    }
    private var replacementBinding: Binding<String> {
        Binding(get: { session.replacement }, set: { session.replacement = $0 })
    }
    private var replacement: String { session.replacement }
    @FocusState private var isSearchFocused: Bool
    @FocusState private var isReplaceFocused: Bool
    @Environment(\.wordMenuPalette) private var palette

    init(
        store: FilesStore,
        document: OpenDocument,
        editor: (any EditorCommands)? = nil,
        actions: FilesItemActions = FilesItemActions(),
        session: WordMenuSession? = nil,
        onOpenFolder: @escaping (FilesFolderRoute) -> Void = { _ in },
        onDismiss: @escaping () -> Void
    ) {
        self.store = store
        self.document = document
        self.editor = editor
        self.actions = actions
        self.externalSession = session
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
    static var deleteMessage: String { String(localized: "It will be moved to the Trash.") }
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
    /// A root's "+" for VoiceOver: "New Document in iCloud".
    static func newDocumentLabel(in place: String) -> String { String(localized: "New Document in \(place)") }
    static var recentTitle: String { String(localized: "Recent") }
    static var searchPrompt: String { String(localized: "Search all documents") }
    /// The scope button's and its menu's name for VoiceOver.
    static var scopeLabel: String { String(localized: "Search in") }
    static var showReplaceTitle: String { String(localized: "Show Replace") }
    static var hideReplaceTitle: String { String(localized: "Hide Replace") }
    static var previousMatchTitle: String { String(localized: "Previous Match") }
    static var nextMatchTitle: String { String(localized: "Next Match") }
    static var replaceWithPrompt: String { String(localized: "Replace with") }
    static var replaceTitle: String { String(localized: "Replace") }
    /// The blue pill's short word; VoiceOver reads `replaceAllTitle`.
    static var replaceAllShortTitle: String { String(localized: "All") }
    static var replaceAllTitle: String { String(localized: "Replace All") }
    /// The iCloud root's heading: the place, not the folder's name.
    static var iCloudHeading: String { String(localized: "iCloud") }

    /// A root's heading and its icon: iCloud with a cloud, On My iPhone with a phone. (The dormant
    /// Workspace root never shows on iPhone: `phoneRoots`.)
    static func heading(for root: FilesRoot) -> (title: String, systemImage: String) {
        switch root.id {
        case .icloud: (iCloudHeading, "icloud")
        case .device: (root.title, "iphone")
        case .workspace: (root.title, root.systemImage)
        }
    }

    /// The roots the iPhone shows, in order: iCloud, then On My iPhone. Never the Workspace.
    static func phoneRoots(_ roots: [FilesRoot]) -> [FilesRoot] {
        roots.filter { $0.id != .workspace }
    }

    /// What a root lists under its folders: its own documents (not those in its folders), newest
    /// first, iCloud placeholders included. Before owner review 4 a root listed only its folders,
    /// so an iCloud folder holding documents and no folders showed nothing under its heading
    /// while Recent listed those documents.
    static func documents(in root: FilesRoot) -> [OutlineFileTreeItem] {
        root.hasScanned ? recentDocuments(in: root.items) : []
    }

    /// How many cards Recent shows (the mockup's four).
    static let recentLimit = 4

    /// Recent: the newest documents anywhere in the roots (their own and their folders'), as
    /// cards, at most `recentLimit`. Under its heading a root lists its documents as plain rows,
    /// like its folders (owner review 4: cards under the folders read as a second Recent).
    static func recentDocuments(acrossRoots roots: [FilesRoot]) -> [OutlineFileTreeItem] {
        let all = phoneRoots(roots).filter(\.hasScanned).flatMap { root in
            root.items.flatMap { item in item.isDirectory ? documentsBelow(item) : [item] }
        }
        return Array(recentDocuments(in: all).prefix(recentLimit))
    }

    /// Every document inside `folder`, at any depth, from the scanned tree.
    static func documentsBelow(_ folder: OutlineFileTreeItem) -> [OutlineFileTreeItem] {
        folder.children.flatMap { child in
            child.isDirectory ? documentsBelow(child) : [child]
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
            // Option C's page: the box, the scope pill and the results 10 pt apart.
            searchBox
                .padding(.bottom, 2)
            scopeButton
                .padding(.bottom, 2)
            if hasQuery, let search {
                FilesSearchResults(controller: search, scope: scope, document: document, store: store, onDismiss: onDismiss)
            } else if !searchesOpenDocument {
                // With the open document as the scope and nothing typed, nothing shows under the
                // box and the scope pill (option C).
                roots
                recent
            }
        }
        .onChange(of: document.text) { search?.textChanged() }
        .onChange(of: store.roots) { search?.rootsChanged() }
        .onAppear {
            // Reopened on this session (the ← after a card): the search catches up with the
            // document and the folders now on screen.
            search?.textChanged()
            search?.rootsChanged()
        }
        // The search keeps running while the menu may be reopened on it; the session ends it.
        .onDisappear { if !session.openedDocument { search?.stop() } }
    }

    private var hasQuery: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var searchesOpenDocument: Bool { scope == .openDocument }

    /// Option C's box (2026-11-24 mockup, `.cbox`): ONE card (the card colour, radius 16, padding
    /// 6, a soft shadow) holding the search field's row and, under it, the replace row. With the
    /// open document as the scope the row is the replace button on the left, the field (with the
    /// count) and the up/down arrows on the right. The field is a fixed 40 pt tall, so nothing in
    /// the row moves when typing starts.
    private var searchBox: some View {
        VStack(alignment: .leading, spacing: Self.boxSpacing) {
            HStack(spacing: Self.boxSpacing) {
                if searchesOpenDocument { replaceToggle }
                searchField
                if searchesOpenDocument { stepButtons }
            }
            if searchesOpenDocument, isReplaceShown { replaceRow }
        }
        .padding(Self.boxSpacing)
        .background(
            RoundedRectangle(cornerRadius: Self.boxRadius, style: .continuous)
                .fill(palette.color(palette.card))
                .shadow(color: .black.opacity(palette.cardHasShadow ? 0.06 : 0), radius: 1, x: 0, y: 1)
                .shadow(color: .black.opacity(palette.cardHasShadow ? 0.07 : 0), radius: 7, x: 0, y: 4)
        )
    }

    // The mockup's measurements for the box and what is inside it.
    static let boxRadius: CGFloat = 16
    static let boxSpacing: CGFloat = 6
    static let fieldHeight: CGFloat = 40
    static let fieldRadius: CGFloat = 10
    /// The replace button and the arrows: drawn 36 pt (radius 10), each with a 44 pt target.
    static let iconButtonSize: CGFloat = 36

    private var replaceToggle: some View {
        Button {
            isReplaceShown.toggle()
            if isReplaceShown { isReplaceFocused = true }
        } label: {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(palette.color(isReplaceShown ? palette.blueMark : palette.ink))
                .frame(width: Self.iconButtonSize, height: Self.iconButtonSize)
                .background(
                    RoundedRectangle(cornerRadius: Self.fieldRadius, style: .continuous)
                        .fill(palette.color(palette.blueFill).opacity(isReplaceShown ? 0.12 : 0))
                )
                .contentShape(Rectangle().inset(by: -4))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isReplaceShown ? Self.hideReplaceTitle : Self.showReplaceTitle)
        .accessibilityAddTraits(isReplaceShown ? .isSelected : [])
        .accessibilityIdentifier("files.search.replaceToggle")
    }

    private var stepButtons: some View {
        HStack(spacing: 0) {
            stepButton(systemImage: "chevron.up", label: Self.previousMatchTitle, identifier: "files.search.previous") {
                search?.selectPrevious()
            }
            stepButton(systemImage: "chevron.down", label: Self.nextMatchTitle, identifier: "files.search.next") {
                search?.selectNext()
            }
        }
        .disabled(!(search?.canStep ?? false) || !hasQuery)
    }

    private func stepButton(
        systemImage: String, label: String, identifier: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(palette.color(palette.ink))
                .frame(width: Self.iconButtonSize, height: Self.iconButtonSize)
                .contentShape(Rectangle().inset(by: -4))
        }
        .buttonStyle(WordMenuPressStyle())
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    /// Replace with, Replace (the current match) and All (every match, one undo step), inside the
    /// box. Side by side, or stacked when the text size leaves no room.
    private var replaceRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Self.boxSpacing) {
                replaceField
                replaceButtons
            }
            VStack(alignment: .leading, spacing: Self.boxSpacing) {
                replaceField
                HStack(spacing: Self.boxSpacing) { replaceButtons }
            }
        }
    }

    private var replaceField: some View {
        TextField(
            text: replacementBinding,
            prompt: Text(Self.replaceWithPrompt).foregroundStyle(palette.color(palette.tertiary))
        ) {
            Text(Self.replaceWithPrompt)
        }
        .focused($isReplaceFocused)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .font(.body)
        .foregroundStyle(palette.color(palette.ink))
        .boxField()
        .frame(minWidth: 120)
        .accessibilityIdentifier("files.search.replacement")
    }

    @ViewBuilder
    private var replaceButtons: some View {
        Button {
            guard let search else { return }
            search.replacement = replacement
            search.replace()
        } label: {
            Text(Self.replaceTitle)
                .font(.subheadline)
                .foregroundStyle(palette.color(palette.ink))
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(height: Self.iconButtonSize)
                .background(Capsule().fill(palette.color(palette.field)))
                .contentShape(Capsule().inset(by: -4))
        }
        .buttonStyle(WordMenuPressStyle())
        .disabled(!(search?.canReplace ?? false) || !hasQuery)
        .opacity((search?.canReplace ?? false) && hasQuery ? 1 : 0.5)
        .fixedSize()
        .accessibilityIdentifier("files.search.replace")
        Button {
            guard let search else { return }
            search.replacement = replacement
            search.replaceAll()
        } label: {
            Text(Self.replaceAllShortTitle)
                .font(.subheadline)
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(height: Self.iconButtonSize)
                .background(Capsule().fill(palette.color(palette.blueFill)))
                .contentShape(Capsule().inset(by: -4))
        }
        .buttonStyle(WordMenuPressStyle())
        .disabled(!(search?.canReplaceAll ?? false) || !hasQuery)
        .opacity((search?.canReplaceAll ?? false) && hasQuery ? 1 : 0.5)
        .fixedSize()
        .accessibilityLabel(Self.replaceAllTitle)
        .accessibilityIdentifier("files.search.replaceAll")
    }

    /// The scope: All documents, or the open document by its file name. A long name stays on one
    /// line, cut in the middle so its extension shows, and never widens the pill past the page.
    private var scopeButton: some View {
        let fileName = FilesSearchScope.fileName(for: document.url)
        let title = FilesSearchScope.title(for: scope, documentURL: document.url)
        return Menu {
            Picker(selection: Binding(get: { scope }, set: { setScope($0) })) {
                Text(FilesSearchScope.allDocumentsTitle)
                    .tag(FilesSearchScope.allDocuments)
                Text(verbatim: FilesSearchScope.middleElided(fileName))
                    .accessibilityLabel(Text(verbatim: fileName))
                    .tag(FilesSearchScope.openDocument)
            } label: {
                Text(Self.scopeLabel)
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 6) {
                Text(verbatim: title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .accessibilityHidden(true)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(palette.color(palette.ink))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(minHeight: 36)
            // Dark: the field grey sinks into the wash, so the pill takes the row grey to stay a
            // visible button (owner review 4).
            .background(Capsule().fill(palette.color(palette.isDark ? palette.soft : palette.field)))
            .contentShape(Capsule())
            .frame(minHeight: WordMenuMetrics.minimumTarget)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(Self.scopeLabel)
        .accessibilityValue(Text(verbatim: title))
        .accessibilityIdentifier("files.search.scope")
    }

    private func setScope(_ newScope: FilesSearchScope) {
        guard newScope != scope else { return }
        WordMenuTiming.begin(.scope)
        scope = newScope
        // Replace only ever touches the open document: leaving its scope closes the replace row.
        if newScope == .allDocuments { isReplaceShown = false }
        search?.setFilter(newScope.filter)
    }

    /// The field inside the box: the glass (only while empty; typed text starts where it was), the
    /// text and, with the open document as the scope, the count ("1/5"). A fixed 40 pt tall: no
    /// clear button or anything else that could change its height (the mockup has none).
    private var searchField: some View {
        HStack(spacing: Self.boxSpacing) {
            if !hasQuery {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15))
                    .foregroundStyle(palette.color(palette.secondary))
                    .accessibilityHidden(true)
            }
            TextField(
                text: Binding(get: { query }, set: { setQuery($0) }),
                prompt: Text(scope.prompt).foregroundStyle(palette.color(palette.tertiary))
            ) {
                Text(scope.prompt)
            }
            .focused($isSearchFocused)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.search)
            .onSubmit {
                if searchesOpenDocument { search?.selectNext() }
            }
            .font(.body)
            .foregroundStyle(palette.color(palette.ink))
            .accessibilityIdentifier("files.search.field")
            if searchesOpenDocument, let position = search?.positionText {
                Text(verbatim: position)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(palette.color(palette.secondary))
                    .lineLimit(1)
                    .fixedSize()
                    .accessibilityLabel(Text(verbatim: search?.positionAccessibilityText ?? position))
                    .accessibilityIdentifier("files.search.count")
            }
        }
        .boxField()
    }

    /// The search is made on the first query (never in `init`). In All documents it reaches every
    /// file and this document (`SearchFilter.all`); with the open document as the scope, only
    /// this document (`.document`), and nothing is scanned.
    private func setQuery(_ newQuery: String) {
        if !newQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { WordMenuTiming.begin(.search) }
        query = newQuery
        if search == nil, !newQuery.isEmpty {
            let made = SearchController(
                editor: editor ?? NoEditorCommands(document: document),
                files: store,
                currentURL: { [weak document] in document?.url },
                open: SearchController.opener(for: document)
            )
            made.setFilter(scope.filter)
            search = made
        }
        search?.setQuery(newQuery)
    }

    @ViewBuilder
    private var roots: some View {
        ForEach(Self.phoneRoots(store.roots)) { root in
            rootSection(root)
        }
    }

    /// Recent: the newest documents, as cards (`recentDocuments(acrossRoots:)`).
    @ViewBuilder
    private var recent: some View {
        let documents = Self.recentDocuments(acrossRoots: store.roots)
        if !documents.isEmpty {
            WordMenuGroupLabel(title: Self.recentTitle)
            WordMenuCardGrid(items: documents) { item in
                DocumentCard(item: item, document: document, store: store, actions: actions) { open(item.url) }
            }
        }
    }

    @ViewBuilder
    private func rootSection(_ root: FilesRoot) -> some View {
        // Each root is a card holding its rows; a tap on its heading collapses it, so a long root
        // does not have to be scrolled past (owner review 4). No motion: it opens and closes at once.
        let heading = Self.heading(for: root)
        let collapsed = isCollapsed(root.id)
        let shape = RoundedRectangle(cornerRadius: WordMenuMetrics.rowRadius + 4, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Button {
                    toggleCollapsed(root.id)
                } label: {
                    HStack(spacing: 6) {
                        WordMenuGroupLabel(title: heading.title, systemImage: heading.systemImage, isTight: true)
                        // One chevron that turns (right when collapsed, down when open), never a
                        // crossfade between two symbols.
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(palette.color(palette.tertiary))
                            .rotationEffect(.degrees(collapsed ? 0 : 90))
                            .animation(.easeInOut(duration: 0.2), value: collapsed)
                            .accessibilityHidden(true)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: WordMenuMetrics.minimumTarget)
                    .contentShape(Rectangle())
                }
                // No press dimming: the heading and its icon stay steady; only the chevron turns.
                .buttonStyle(SteadyButtonStyle())
                .accessibilityLabel(Text(heading.title))
                .accessibilityValue(Text(collapsed ? Self.collapsedValue : Self.expandedValue))
                .accessibilityHint(Text(collapsed ? Self.expandHint : Self.collapseHint))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("files.root.\(root.id.rawValue)")
                if let folder = root.folderURL, root.state == .available {
                    // A document made here saves here.
                    WordMenuRoundButton(systemImage: "plus", label: Self.newDocumentLabel(in: heading.title)) {
                        newDocument(in: folder)
                    }
                    .accessibilityIdentifier("files.add.\(root.id.rawValue)")
                }
            }
            if !collapsed {
                if !root.hasScanned {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                } else {
                    // An empty root is its heading and "+" alone: no empty-state text (owner review 4).
                    FilesFolderRows(items: root.items, store: store, actions: actions, onOpenFolder: onOpenFolder)
                    rootDocumentCards(root)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .padding(.bottom, collapsed ? 4 : 10)
        // The same surface and shadow as the document cards (`DocumentCard`).
        .background(shape.fill(palette.color(palette.card)))
        .shadow(color: .black.opacity(palette.cardHasShadow ? 0.07 : 0), radius: 7, x: 0, y: 3)
    }

    static var collapsedValue: String { String(localized: "Collapsed") }
    static var expandedValue: String { String(localized: "Expanded") }
    static var expandHint: String { String(localized: "Shows its folders and documents.") }
    static var collapseHint: String { String(localized: "Hides its folders and documents.") }

    /// The root's own documents as plain rows under its folders, newest first, iCloud
    /// placeholders included (opening one downloads it). Rows, not cards: cards are Recent's.
    @ViewBuilder
    private func rootDocumentCards(_ root: FilesRoot) -> some View {
        let documents = Self.documents(in: root)
        if !documents.isEmpty {
            FilesDocumentRows(items: documents, store: store, actions: actions) { item in open(item.url) }
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
        session.noteOpenedDocument()
        Task { await document.openReportingFailure(url) }
        onDismiss()
    }
}

extension View {
    /// A field inside Files' search box: the field colour, radius 10, a fixed 40 pt height.
    fileprivate func boxField() -> some View { modifier(FilesBoxField()) }
}

private struct FilesBoxField: ViewModifier {
    @Environment(\.wordMenuPalette) private var palette

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .frame(height: FilesSection.fieldHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: FilesSection.fieldRadius, style: .continuous)
                    .fill(palette.color(palette.field))
            )
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

/// A root's own documents as rows in the folder rows' style: the name, and when it changed on
/// the right. Swipe and long-press offer what a card's ⋯ does.
struct FilesDocumentRows: View {
    var items: [OutlineFileTreeItem]
    var store: FilesStore
    var actions: FilesItemActions
    var onOpen: (OutlineFileTreeItem) -> Void

    static func when(_ item: OutlineFileTreeItem, now: Date = Date()) -> String? {
        item.modifiedAt.map { $0.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)) }
    }

    var body: some View {
        VStack(spacing: 6) {
            ForEach(items) { item in
                Button {
                    onOpen(item)
                } label: {
                    WordMenuRowLabel(
                        title: item.url.deletingPathExtension().lastPathComponent,
                        systemImage: "doc.text",
                        accessory: Self.when(item).map { .text($0) } ?? .none
                    )
                    .opacity(item.isHidden ? 0.7 : 1)
                }
                .buttonStyle(WordMenuPressStyle())
                // VoiceOver: the name, then when it changed and any state.
                .accessibilityLabel(Text(verbatim: item.url.deletingPathExtension().lastPathComponent))
                .accessibilityValue(Text(verbatim: [Self.when(item), FilesRow.accessibilityValue(for: item)]
                    .compactMap { $0 }.joined(separator: ", ")))
                .filesSwipeAccessibilityActions(FilesSwipeAction.actions(for: item, store: store))
                .filesSwipeActions(FilesSwipeAction.actions(for: item, store: store))
                .contextMenu {
                    ForEach(FilesRowAction.menuActions(for: item), id: \.self) { action in
                        Button {
                            actions.perform(action, on: item)
                        } label: {
                            Label(action.title, systemImage: action.systemImage)
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

    /// The words drawn on the swipe button: short enough for one line on a folder row (a 46 pt
    /// row cut "Move to On My iPhone" off). VoiceOver keeps the full `title`.
    var shortTitle: String {
        switch kind {
        case .trash: String(localized: "Trash")
        case .move(.icloud): String(localized: "To iCloud")
        case .move: String(localized: "To iPhone")
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
                                Text(action.shortTitle)
                                    .font(.caption2.weight(.semibold))
                                    .lineLimit(1)
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

/// A button that draws its label exactly as it is, pressed or not.
struct SteadyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}
