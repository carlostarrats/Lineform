import AppKit
import SwiftUI

enum OutlineSidebarTab: String, CaseIterable, Identifiable {
    case outline = "Outline"
    case files = "Files"
    case markdownBasics = "Markdown Basics"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .outline: return "list.bullet"
        case .files: return "folder"
        case .markdownBasics: return "curlybraces"
        }
    }
}

struct OutlineFileTreeItem: Identifiable, Equatable, Codable {
    var url: URL
    var name: String
    var isDirectory: Bool
    var children: [OutlineFileTreeItem]
    var isHidden: Bool = false
    var createdAt: Date?
    var modifiedAt: Date?

    var id: String { url.path }

    /// A copy with `children` dropped. Used for the flattened sidebar rows: the row view reads
    /// only scalar fields, so carrying the whole subtree by value would make SwiftUI's per-row
    /// diff (and the flat-list build) O(subtree) on the hot path (Task 5). The parent flattener
    /// still recurses over the ORIGINAL `children` before stripping, so nothing is lost.
    var withoutChildren: OutlineFileTreeItem {
        var copy = self
        copy.children = []
        return copy
    }

    init(
        url: URL,
        name: String,
        isDirectory: Bool,
        children: [OutlineFileTreeItem],
        isHidden: Bool = false,
        createdAt: Date? = nil,
        modifiedAt: Date? = nil
    ) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.children = children
        self.isHidden = isHidden
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    private enum CodingKeys: String, CodingKey {
        case url, name, isDirectory, children, isHidden, createdAt, modifiedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decode(URL.self, forKey: .url)
        name = try container.decode(String.self, forKey: .name)
        isDirectory = try container.decode(Bool.self, forKey: .isDirectory)
        children = try container.decode([OutlineFileTreeItem].self, forKey: .children)
        // Tolerate snapshots written before isHidden existed (they only held visible items).
        isHidden = try container.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        // Tolerate snapshots written before the date-sort keys existed.
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        modifiedAt = try container.decodeIfPresent(Date.self, forKey: .modifiedAt)
    }
}

/// One visible row of the flattened file tree: an item plus its indent depth. Rendering the
/// tree from a flat list of these in a `LazyVStack` (rather than recursive `VStack`s) is what
/// virtualizes a large workspace so only on-screen rows are laid out.
struct OutlineFileTreeFlatRow: Identifiable {
    let item: OutlineFileTreeItem
    let depth: Int
    var id: String { item.id }
}

struct OutlineSidebarView: View {
    struct OutlineNode: Identifiable, Equatable {
        var item: MarkdownOutlineItem
        var children: [OutlineNode]

        var id: String { item.id }
    }

    static let emptyStateInstruction = "Add # Title or ## Section to build an outline."
    /// Matches the Markdown Basics section header exactly: size 12 medium, inactive-tab grey,
    /// same leading x (pillHorizontalInset + 10) and same y below the divider (tabDividerGap + 4).
    static let emptyStateFontSize: CGFloat = 12
    static let titleShowsIcon = false
    static let usesSubtleGradientBackground = false
    static let usesThemeIndependentLightChrome = false
    static let backgroundOpacity: Double = 0.94
    static let lightBackgroundWhiteComponent: CGFloat = 0.988
    static let darkBackgroundWhiteComponent: CGFloat = 0.18
    static let primaryTextWhiteComponent: CGFloat = 0.16
    static let secondaryTextWhiteComponent: CGFloat = 0.43
    static let darkPrimaryTextWhiteComponent: CGFloat = 0.90
    static let darkSecondaryTextWhiteComponent: CGFloat = 0.68
    static let rowsShowHoverFeedback = true
    static let rowHoverFillOpacity = 0.08
    // Soft translucent accent tint for the selected (currently-shown) file row — the native
    // macOS source-list selection look, paired with accent-colored label/icon.
    static let rowSelectionFillOpacity = 0.15
    static let tabTitles = OutlineSidebarTab.allCases.map(\.rawValue)
    static let tabsFillAvailableWidth = true
    static let tabsUseNativeEqualWidthSegments = true
    static let tabsUseExplicitThemeAppearance = true
    static let chooseWorkspaceButtonTitle = "Choose"
    static let changeWorkspaceButtonTitle = "Change"
    static let filesRowsFillAvailableWidth = true
    /// Left inset of the Files tree from the sidebar edge. Sits at the CHEVRON column so
    /// disclosure chevrons hang here and the icons after them land on `sidebarIconColumnLeading`
    /// (6 + 10 chevron + 8 gap = 24), aligning file/folder icons with the tab icons above.
    static let filesContentHorizontalPadding: CGFloat = 6
    static let filesRootRowHeight: CGFloat = 28
    static let filesChildRowHeight: CGFloat = 26
    static let filesUnavailableRootOpacity = 0.56
    static let filesActionUsesPillStyle = true
    static let filesActionButtonsUseHighContrastFill = true
    static let filesActionButtonsReverseInDarkMode = true
    static let filesActionButtonsShowHoverState = true
    static let filesRootRowsShowLeadingIcons = true
    static let filesRootTextFollowsDisclosureDirectly = true
    static let filesRootDisclosureIsVisualOnly = true
    static let filesRootTextTogglesCollapse = true
    static let fileSelectionReplacesCurrentWindow = true
    static let fileSelectionUsesNativeSavePrompt = true
    static let workspaceDisconnectedSystemImage = "exclamationmark.triangle.fill"
    static let filesSortMenuLabelPrefix = "Sort: "
    /// The sort row renders only under an expanded, connected, non-empty section — a
    /// disconnected/dimmed/empty section has nothing meaningful to reorder.
    static let filesSortRowShowsForAvailableRootsOnly = true

    /// Per-level horizontal indent for Files-tab tree rows. Nesting is carried by indentation +
    /// disclosure chevrons alone (the native macOS source-list convention — Finder, Notes, Mail —
    /// no vertical guide lines), so the step is generous enough for the eye to track structure by
    /// row x-position.
    static let filesTreeIndentStep: CGFloat = 14

    /// A root shows a disclosure chevron only when it has an expandable child area — i.e. it
    /// actually has files. Empty/unavailable/unassigned roots have nothing to expand.
    static func rootShowsDisclosure(state: OutlineFileRootState, isEmpty: Bool) -> Bool {
        (state == .available || state == .disconnected) && !isEmpty
    }

    /// The iCloud root reads as "inactive" (dimmed) when it is connected but has no files.
    static func iCloudRootIsDimmed(state: OutlineFileRootState, isEmpty: Bool) -> Bool {
        state == .available && isEmpty
    }

    /// The iCloud root is hidden entirely when its container can't resolve — i.e. the user has no
    /// iCloud / isn't signed in (in Debug there is no iCloud entitlement, so it is always hidden).
    /// Showing a dead root to someone without iCloud is just noise. Every other root/state shows.
    static func rootIsVisible(id: String, state: OutlineFileRootState) -> Bool {
        !(id == "icloud" && state == .unavailable)
    }

    /// The iCloud root shows only when its container resolves AND the user hasn't
    /// hidden it in Settings. Workspace visibility is unaffected by this setting.
    static func iCloudRootVisible(state: OutlineFileRootState, showICloudInSidebar: Bool) -> Bool {
        rootIsVisible(id: "icloud", state: state) && showICloudInSidebar
    }

    /// A root's collapse chevron is suppressed entirely when root collapsing is
    /// locked off (Settings › Allow root folders to expand and collapse — either
    /// turned off explicitly, or auto-locked while only the Workspace root shows).
    static func rootDisclosureVisible(state: OutlineFileRootState, isEmpty: Bool, lockExpanded: Bool) -> Bool {
        rootShowsDisclosure(state: state, isEmpty: isEmpty) && !lockExpanded
    }

    /// When roots are locked expanded, a root is never treated as collapsed even if
    /// its id lingers in the in-memory collapsed set (so toggling the setting back
    /// off restores the prior in-session state).
    static func rootIsCollapsed(isInCollapsedSet: Bool, lockExpanded: Bool) -> Bool {
        !lockExpanded && isInCollapsedSet
    }

    /// Flattens a file tree into the rows currently VISIBLE (depth-first: parent, then its
    /// children only when the folder is expanded), each tagged with its indent depth. The tree
    /// is rendered from this flat list in a `LazyVStack` so a large workspace only lays out the
    /// rows in the scroll viewport — the recursive non-lazy `VStack` rendering it replaced forced
    /// SwiftUI to lay out every row of a fully-expanded tree at once, which froze typing and
    /// file-switching on big workspaces (Task 5 — the real bottleneck, not the directory scan).
    static func visibleFileRows(
        _ items: [OutlineFileTreeItem],
        collapsedIDs: Set<String>,
        depth: Int = 1
    ) -> [OutlineFileTreeFlatRow] {
        var rows: [OutlineFileTreeFlatRow] = []
        for item in items {
            // Store a children-stripped copy: the row view never reads `children`, and keeping
            // the subtree would make SwiftUI's per-row diff O(subtree). Recurse over the
            // ORIGINAL children below so the flattened output is unchanged.
            rows.append(OutlineFileTreeFlatRow(item: item.withoutChildren, depth: depth))
            if item.isDirectory, !collapsedIDs.contains(item.id) {
                rows.append(contentsOf: visibleFileRows(item.children, collapsedIDs: collapsedIDs, depth: depth + 1))
            }
        }
        return rows
    }
    static let minimumColumnWidth: CGFloat = 220
    static let idealColumnWidth: CGFloat = 260
    static let maximumColumnWidth: CGFloat = 300

    @Environment(\.colorScheme) private var colorScheme
    @State private var collapsedNodeIDs: Set<String> = []
    @State private var selectedTab = OutlineSidebarTab.outline
    @State private var isSettingsHovered = false
    @StateObject private var fileBrowserStore: OutlineFileBrowserStore

    static func showsTitle(for items: [MarkdownOutlineItem]) -> Bool {
        false
    }

    static func iconName(forHeadingLevel level: Int) -> String {
        switch level {
        case 1:
            return "textformat.size"
        case 2:
            return "list.bullet.indent"
        default:
            return "text.alignleft"
        }
    }

    /// VoiceOver label for a Files-tab row. Rows previously exposed only text + selection
    /// trait; folders and de-emphasized hidden items need to say what they are.
    static func fileRowAccessibilityLabel(name: String, isDirectory: Bool, isHidden: Bool) -> String {
        switch (isDirectory, isHidden) {
        case (true, true): return "\(name), hidden folder"
        case (true, false): return "\(name), folder"
        case (false, true): return "\(name), hidden"
        case (false, false): return name
        }
    }

    /// Whether a Files-tab row represents the document currently shown in the window. Folders
    /// are never selectable. Both URLs are standardized before comparison — the same normalization
    /// the sidebar file opener uses (see `replaceCurrentDocument`), so a file opened from the
    /// sidebar reliably matches its own row.
    static func fileRowIsSelected(itemURL: URL, isDirectory: Bool, currentFileURL: URL?) -> Bool {
        guard !isDirectory, let currentFileURL else {
            return false
        }
        return itemURL.standardizedFileURL == currentFileURL.standardizedFileURL
    }

    static func outlineTree(from items: [MarkdownOutlineItem]) -> [OutlineNode] {
        final class MutableNode {
            var item: MarkdownOutlineItem
            var children: [MutableNode] = []

            init(item: MarkdownOutlineItem) {
                self.item = item
            }
        }

        var roots: [MutableNode] = []
        var stack: [MutableNode] = []

        for item in items {
            let node = MutableNode(item: item)

            while let parent = stack.last, parent.item.level >= item.level {
                stack.removeLast()
            }

            if let parent = stack.last {
                parent.children.append(node)
            } else {
                roots.append(node)
            }

            stack.append(node)
        }

        func immutableNode(from node: MutableNode) -> OutlineNode {
            OutlineNode(item: node.item, children: node.children.map(immutableNode))
        }

        return roots.map(immutableNode)
    }

    var items: [MarkdownOutlineItem]
    /// Source-text range of the heading currently at/near the top of the editor viewport.
    /// When nil, no outline item is highlighted as active.
    var activeSourceRange: NSRange? = nil
    var jumpToHeading: (MarkdownOutlineItem) -> Void
    var openFile: (URL) -> Void = { url in
        LineformSidebarFileOpener.open(url, replacing: nil)
    }
    /// The file currently shown in this window, so its Files-tab row can render the native
    /// selection highlight. `nil` for untitled documents (no on-disk URL to match).
    var currentFileURL: URL?
    /// Context-menu actions on Files-tab rows. The sidebar stays dumb: the window's
    /// editor container supplies these (it presents the dialogs, performs the file
    /// operation, and broadcasts the app-wide refresh/retarget notifications).
    var renameItem: (OutlineFileTreeItem) -> Void = { _ in }
    var deleteItem: (OutlineFileTreeItem) -> Void = { _ in }
    var revealItem: (OutlineFileTreeItem) -> Void = { _ in }
    /// The app-wide settings store, injectable so hosted tests can isolate the two
    /// sidebar-affecting preferences (Show iCloud, Keep roots expanded) on their own
    /// defaults suite instead of leaking the developer's real prefs into test geometry.
    private let settings: LineformSettingsStore

    init(
        items: [MarkdownOutlineItem],
        activeSourceRange: NSRange? = nil,
        jumpToHeading: @escaping (MarkdownOutlineItem) -> Void,
        openFile: @escaping (URL) -> Void = { url in
            LineformSidebarFileOpener.open(url, replacing: nil)
        },
        currentFileURL: URL? = nil,
        fileBrowserStore: OutlineFileBrowserStore? = nil,
        settings: LineformSettingsStore = .shared,
        renameItem: @escaping (OutlineFileTreeItem) -> Void = { _ in },
        deleteItem: @escaping (OutlineFileTreeItem) -> Void = { _ in },
        revealItem: @escaping (OutlineFileTreeItem) -> Void = { _ in }
    ) {
        self.items = items
        self.activeSourceRange = activeSourceRange
        self.jumpToHeading = jumpToHeading
        self.openFile = openFile
        self.currentFileURL = currentFileURL
        self.settings = settings
        self.renameItem = renameItem
        self.deleteItem = deleteItem
        self.revealItem = revealItem
        // Production passes nil → a real store is created lazily on first render. Tests inject
        // a store on an isolated defaults suite so they never resolve the user's real workspace
        // bookmark (which would touch ~/Documents and prompt for access).
        // Production opts into background scanning: the recursive directory walk must not block
        // the main thread (typing/file-switching) on large workspaces (Task 5). Tests default to
        // synchronous scanning (never a race, and they keep asserting inline).
        _fileBrowserStore = StateObject(wrappedValue: fileBrowserStore ?? OutlineFileBrowserStore(runsScanInBackground: true))
    }

    var body: some View {
        ZStack {
            sidebarBackground
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                tabPicker

                tabContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    // safeAreaInset reserves space for the Settings bar so the last scroll row
                    // can't hide behind it (a plain ZStack overlay let content underlap the bar).
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        bottomBar
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: Self.minimumColumnWidth, idealWidth: Self.idealColumnWidth, maxWidth: Self.maximumColumnWidth)
        .accessibilityLabel("Document outline")
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .outline:
            outlineContent
        case .files:
            filesContent
        case .markdownBasics:
            OutlineMarkdownBasicsTabView(usesDarkChrome: usesDarkChrome)
        }
    }

    @ViewBuilder
    private var filesContent: some View {
        OutlineFileBrowserView(
            store: fileBrowserStore,
            openFile: openFile,
            currentFileURL: currentFileURL,
            settings: settings,
            usesDarkChrome: usesDarkChrome,
            renameItem: renameItem,
            deleteItem: deleteItem,
            revealItem: revealItem
        )
        .onAppear {
            // Reconcile the app-wide "Show Hidden Folders" preference (driven from
            // the View menu) each time the Files tab becomes visible, then run the
            // deferred iCloud scan exactly once. Only an OFF→ON change scans iCloud
            // via the store's `didSet` (it must enumerate previously-skipped hidden
            // entries); every other path — unchanged, or a change toward OFF whose
            // `didSet` only filters cached items — still needs the sanctioned
            // `refreshICloud()` here. The scan stays deferred to this point, so it
            // never runs for windows whose Files tab isn't shown.
            let desired = HiddenFoldersMenuState.shared.isOn
            let turnedOn = desired && !fileBrowserStore.showsHiddenFolders
            fileBrowserStore.showsHiddenFolders = desired
            // Reconcile BOTH roots on every appearance (previously only iCloud
            // refreshed here, so workspace changes made while the tab was hidden
            // never showed). When the toggle just turned ON, its didSet already
            // re-scanned both roots — don't walk them twice in one appearance.
            if !turnedOn {
                fileBrowserStore.refreshICloud()
                fileBrowserStore.refreshWorkspace()
            }
            // Start live watching after the refresh above so the resolved
            // iCloud container URL is available to watch.
            fileBrowserStore.beginWatchingForExternalChanges()
        }
        .onDisappear {
            fileBrowserStore.endWatchingForExternalChanges()
        }
        .onReceive(NotificationCenter.default.publisher(for: LineformAppNotification.toggleHiddenFolders.name)) { _ in
            // Live update while the Files tab is visible (its iCloud container is
            // already resolved, so the store's re-scan matches the old in-sidebar
            // toggle's cost). Windows on the Outline tab or with the sidebar collapsed
            // don't observe this, preserving the deferred-scan invariant; they
            // reconcile via .onAppear when the Files tab next appears.
            fileBrowserStore.showsHiddenFolders = HiddenFoldersMenuState.shared.isOn
        }
        .onReceive(NotificationCenter.default.publisher(for: LineformAppNotification.refreshSidebarFiles.name)) { notification in
            // An in-app rename/delete happened (any window). Refresh
            // immediately — the FSEvents path would also catch it, but only
            // after its coalescing latency. Scoped to the root containing the
            // affected URL; only visible Files tabs observe this, preserving
            // the deferred-scan invariant.
            fileBrowserStore.refreshRoots(affecting: notification.object as? URL)
        }
    }

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 0) {
            sidebarDivider

            Button {
                LineformAppNotification.showSettings.post()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 18, alignment: .center)

                    Text("Settings")
                        .font(.system(size: 13, weight: .medium))

                    Spacer(minLength: 0)
                }
                // Settings reads dark by default and LIGHTENS on hover (the reverse of the
                // tabs): not hovered → darkest (isSelected), hovered → the quiet grey.
                .foregroundStyle(OutlineSidebarView.tabTextColor(
                    usesDarkChrome: usesDarkChrome,
                    isSelected: !isSettingsHovered,
                    isHovered: false
                ))
                .padding(.leading, OutlineSidebarView.pillInnerLeading)
                .padding(.trailing, OutlineSidebarView.pillInnerLeading)
                .frame(height: 32)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Hover scoped to the button itself, not the whole bar/divider, so only hovering
            // the Settings row highlights it.
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) {
                    isSettingsHovered = hovering
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
        .background(sidebarBackground)
    }

    private var tabPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(OutlineSidebarTab.allCases) { tab in
                    SidebarTabButton(
                        tab: tab,
                        isSelected: selectedTab == tab,
                        usesDarkChrome: usesDarkChrome,
                        action: { selectedTab = tab }
                    )
                }
            }
            .padding(.bottom, Self.tabDividerGap)

            sidebarDivider
                .padding(.horizontal, 0)
        }
        .padding(.horizontal, Self.pillHorizontalInset)
        .padding(.top, 12)
    }

    private var sidebarDivider: some View {
        Rectangle()
            .fill(OutlineSidebarView.primaryTextColor(usesDarkChrome: usesDarkChrome).opacity(0.10))
            .frame(height: 0.5)
            .frame(maxWidth: .infinity)
    }

    /// Heading items shown in the outline, with the first H1 (document title/page name)
    /// omitted — it is already visible at the top of the editor.
    private var displayedItems: [MarkdownOutlineItem] {
        if items.first?.level == 1 {
            return Array(items.dropFirst())
        }
        return items
    }

    /// The outline item nearest the top of the current viewport, if any. Choosing the last
    /// heading whose source position is at or before the viewport top means the heading
    /// currently being read is bolded, even when its text line has just scrolled past the top.
    private var activeItemID: String? {
        guard let activeSourceRange else { return nil }
        return displayedItems.last { $0.characterRange.location <= activeSourceRange.location }?.id
    }

    @ViewBuilder
    private var outlineContent: some View {
        if items.isEmpty {
            Text(Self.emptyStateInstruction)
                .font(.system(size: Self.emptyStateFontSize, weight: .medium))
                .foregroundStyle(Self.tabTextColor(usesDarkChrome: usesDarkChrome, isSelected: false, isHovered: false))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, Self.pillHorizontalInset + 10)
                .padding(.trailing, Self.pillHorizontalInset)
                .padding(.top, Self.tabDividerGap + 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Self.outlineTree(from: displayedItems)) { node in
                        OutlineSidebarNodeView(
                            node: node,
                            depth: 0,
                            activeItemID: activeItemID,
                            collapsedNodeIDs: $collapsedNodeIDs,
                            usesDarkChrome: usesDarkChrome,
                            jumpToHeading: jumpToHeading
                        )
                    }
                }
                .padding(.horizontal, Self.pillHorizontalInset)
                .padding(.top, Self.tabDividerGap)
            }
            .scrollContentBackground(.hidden)
        }
    }

    private var sidebarBackground: Color {
        Self.backgroundColor(usesDarkChrome: usesDarkChrome)
            .opacity(Self.backgroundOpacity)
    }

    private var usesDarkChrome: Bool {
        colorScheme == .dark
    }

    static func backgroundColor(usesDarkChrome: Bool) -> Color {
        Color(nsColor: NSColor(
            calibratedWhite: usesDarkChrome ? darkBackgroundWhiteComponent : lightBackgroundWhiteComponent,
            alpha: 1
        ))
    }

    static func tabAppearanceName(usesDarkChrome: Bool) -> NSAppearance.Name {
        usesDarkChrome ? .darkAqua : .aqua
    }

    static func primaryTextColor(usesDarkChrome: Bool) -> Color {
        Color(nsColor: NSColor(
            calibratedWhite: usesDarkChrome ? darkPrimaryTextWhiteComponent : primaryTextWhiteComponent,
            alpha: 1
        ))
    }

    static func secondaryTextColor(usesDarkChrome: Bool) -> Color {
        Color(nsColor: NSColor(
            calibratedWhite: usesDarkChrome ? darkSecondaryTextWhiteComponent : secondaryTextWhiteComponent,
            alpha: 1
        ))
    }

    // MARK: - Unified leading geometry

    /// The single icon column every section aligns to (icon left edge, measured from the
    /// sidebar's content edge). Disclosure chevrons hang in the reserved slot to the LEFT of
    /// this column (the Finder/Xcode source-list convention), so tab icons, Settings, outline
    /// rows, the Files sort row, root icons, and file/folder icons all share one vertical line.
    static let sidebarIconColumnLeading: CGFloat = 24
    /// Disclosure chevron (Files tree AND root headers): a small glyph right-aligned in this slot
    /// with `filesChevronToIconGap` to the icon, so the chevron sits close to the folder/doc icon
    /// it discloses. Slot + gap = 18 = the icon column's offset from the content edge, so the icon
    /// column is unchanged whether or not a chevron is drawn.
    static let filesChevronSlotWidth: CGFloat = 12
    static let filesChevronToIconGap: CGFloat = 6
    /// Horizontal inset of the tab-picker / Settings / outline pills from the sidebar edge.
    /// The pill's own internal leading padding then carries the icon to `sidebarIconColumnLeading`.
    static let pillHorizontalInset: CGFloat = 14
    static let pillInnerLeading: CGFloat = 10
    /// Symmetric breathing room above and below the divider under the three tabs. Applied as
    /// the tabs' bottom padding AND each tab-content's top padding so the line sits centered.
    static let tabDividerGap: CGFloat = 16

    // MARK: - Tab / Settings text states (no pill; state is carried by text color)

    static let tabSelectedLightWhite: CGFloat = 0.16
    static let tabUnselectedLightWhite: CGFloat = 0.56
    static let tabUnselectedHoverLightWhite: CGFloat = 0.30
    static let tabSelectedDarkWhite: CGFloat = 0.93
    static let tabUnselectedDarkWhite: CGFloat = 0.56
    static let tabUnselectedHoverDarkWhite: CGFloat = 0.82

    /// Text/icon color for a tab or the Settings button. Selected reads darkest; an
    /// unselected item is a quiet grey that darkens on hover (never a background fill).
    static func tabTextColor(usesDarkChrome: Bool, isSelected: Bool, isHovered: Bool) -> Color {
        let white: CGFloat
        if isSelected {
            white = usesDarkChrome ? tabSelectedDarkWhite : tabSelectedLightWhite
        } else if isHovered {
            white = usesDarkChrome ? tabUnselectedHoverDarkWhite : tabUnselectedHoverLightWhite
        } else {
            white = usesDarkChrome ? tabUnselectedDarkWhite : tabUnselectedLightWhite
        }
        return Color(nsColor: NSColor(calibratedWhite: white, alpha: 1))
    }
}

private struct OutlineSidebarNodeView: View {
    var node: OutlineSidebarView.OutlineNode
    var depth: Int
    var activeItemID: String?
    @Binding var collapsedNodeIDs: Set<String>
    // Threaded from the theme (see SidebarTabButton) rather than read from ambient colorScheme,
    // which a nested Button re-derives from the window's drift-prone effectiveAppearance.
    var usesDarkChrome: Bool
    var jumpToHeading: (MarkdownOutlineItem) -> Void

    private var isCollapsed: Bool {
        collapsedNodeIDs.contains(node.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            OutlineSidebarRow(
                node: node,
                depth: depth,
                isActive: node.id == activeItemID,
                isCollapsed: isCollapsed,
                usesDarkChrome: usesDarkChrome,
                toggleCollapsed: toggleCollapsed,
                jumpToHeading: jumpToHeading
            )

            if !isCollapsed {
                ForEach(node.children) { child in
                    OutlineSidebarNodeView(
                        node: child,
                        depth: depth + 1,
                        activeItemID: activeItemID,
                        collapsedNodeIDs: $collapsedNodeIDs,
                        usesDarkChrome: usesDarkChrome,
                        jumpToHeading: jumpToHeading
                    )
                }
            }
        }
    }

    private func toggleCollapsed() {
        if isCollapsed {
            collapsedNodeIDs.remove(node.id)
        } else {
            collapsedNodeIDs.insert(node.id)
        }
    }
}

private struct OutlineSidebarRow: View {
    var node: OutlineSidebarView.OutlineNode
    var depth: Int
    var isActive: Bool
    var isCollapsed: Bool
    var usesDarkChrome: Bool
    var toggleCollapsed: () -> Void
    var jumpToHeading: (MarkdownOutlineItem) -> Void
    @State private var isHovered = false

    var body: some View {
        Button {
            jumpToHeading(node.item)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(rowForegroundColor)
                    .frame(width: 18)

                Text(node.item.title)
                    .font(.system(size: 13, weight: isActive ? .bold : baseFontWeight))
                    .foregroundStyle(rowForegroundColor)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            // Icon rides the shared column: pill inner leading (10) + depth indent, inside the
            // outline content's 14pt inset, lands the icon at `sidebarIconColumnLeading` (24).
            .padding(.leading, OutlineSidebarView.pillInnerLeading + CGFloat(depth) * OutlineSidebarView.filesTreeIndentStep)
            .padding(.trailing, OutlineSidebarView.pillInnerLeading)
            .frame(height: 26)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(OutlineSidebarView.primaryTextColor(usesDarkChrome: usesDarkChrome)
                        .opacity(isHovered ? OutlineSidebarView.rowHoverFillOpacity : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .accessibilityLabel("Jump to heading \(node.item.title)")
    }

    /// The non-active weight; the active heading swaps to `.bold` (see body).
    private var baseFontWeight: Font.Weight {
        node.item.level == 1 ? .medium : .regular
    }

    private var rowForegroundColor: Color {
        OutlineSidebarView.primaryTextColor(usesDarkChrome: usesDarkChrome)
    }
}

private struct SidebarTabButton: View {
    let tab: OutlineSidebarTab
    let isSelected: Bool
    // Threaded from the theme, NOT read from @Environment(\.colorScheme): this Button's label is a
    // nested SwiftUI control whose colorScheme re-derives from the window's effectiveAppearance,
    // which can lag/drift from the active theme (see WindowChromeReader). Passing the theme's value
    // keeps the selected/hover text color correct even mid-transition.
    let usesDarkChrome: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18, alignment: .center)

                Text(tab.rawValue)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))

                Spacer(minLength: 0)
            }
            // No pill: the selected tab reads darkest, unselected tabs are a quiet grey that
            // darkens on hover. The icon rides the shared `sidebarIconColumnLeading`.
            .foregroundStyle(foregroundColor)
            .padding(.leading, OutlineSidebarView.pillInnerLeading)
            .padding(.trailing, OutlineSidebarView.pillInnerLeading)
            .frame(height: 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }

    private var foregroundColor: Color {
        OutlineSidebarView.tabTextColor(
            usesDarkChrome: usesDarkChrome,
            isSelected: isSelected,
            isHovered: isHovered
        )
    }
}

enum OutlineFileRootState: Equatable {
    case available
    case unavailable
    case unassigned
    case disconnected
}

struct OutlineFileRoot: Identifiable, Equatable {
    var id: String
    var title: String
    var systemImage: String
    var state: OutlineFileRootState
    var items: [OutlineFileTreeItem]

    var showsTree: Bool {
        state == .available || state == .disconnected
    }
}

/// Abstraction over `FileManager.startDownloadingUbiquitousItem(at:)` so the
/// keep-downloaded behavior can be exercised in tests without real iCloud files.
/// Abstraction over security-scoped URL access so tests can observe the scope lifecycle.
/// The workspace folder's scope must be HELD while the workspace is set — not flashed on
/// transiently around a directory scan — or file reads (document open, live reload) fail
/// with "you don't have permission" after every relaunch.
protocol SecurityScopedResourceAccessing {
    /// Begins security-scoped access. Returns false when the URL carries no scope
    /// (e.g. a plain path or a same-session NSOpenPanel URL, which needs none).
    func beginAccess(to url: URL) -> Bool
    /// Ends access previously begun with `beginAccess(to:)`. Only call after a `true` return.
    func endAccess(to url: URL)
}

struct URLSecurityScopedResourceAccessor: SecurityScopedResourceAccessing {
    func beginAccess(to url: URL) -> Bool { url.startAccessingSecurityScopedResource() }
    func endAccess(to url: URL) { url.stopAccessingSecurityScopedResource() }
}

protocol UbiquitousItemDownloader {
    func startDownloadingUbiquitousItem(at url: URL) throws
}

extension FileManager: UbiquitousItemDownloader {}

final class OutlineFileBrowserStore: ObservableObject {
    // Production container. Debug builds intentionally ship no iCloud entitlement,
    // so this resolves to nil there and the Files sidebar shows iCloud as
    // unavailable — which keeps local/CI build churn from ever touching (and
    // letting macOS purge) the real users' production container.
    static let iCloudContainerIdentifier = "iCloud.com.lineform.app"
    static let iCloudSnapshotDefaultsKey = "Lineform.outline.iCloudSnapshot"
    static let workspaceBookmarkDefaultsKey = "Lineform.outline.workspaceBookmark"
    static let workspaceSnapshotDefaultsKey = "Lineform.outline.workspaceSnapshot"
    static let showsHiddenFoldersDefaultsKey = "Lineform.outline.showsHiddenFolders"
    static let iCloudSortOrderDefaultsKey = "Lineform.outline.sortOrder.icloud"
    static let workspaceSortOrderDefaultsKey = "Lineform.outline.sortOrder.workspace"
    static let lastKnownICloudAvailableDefaultsKey = "Lineform.outline.lastKnownICloudAvailable"
    static let maximumTreeDepth = 4
    static let maximumChildrenPerFolder = 80
    /// Trailing debounce for FSEvents-driven rescans (Task 5). Autosave-while-typing writes
    /// fire the monitor; without a debounce each coalesced tick ran the recursive directory
    /// walk synchronously on the main thread ~every `DirectoryEventMonitor.coalescingLatency`
    /// (0.5s), which is the large-workspace typing hitch. MUST exceed that latency: during
    /// continuous churn FSEvents delivers a callback roughly every `coalescingLatency`, so a
    /// longer debounce is guaranteed to keep resetting (never fire) until the churn stops —
    /// converting the mid-typing hitch into a single settle-after-pause rescan.
    static let directoryRescanDebounceInterval: TimeInterval = 0.75
    static let supportedFileExtensions: Set<String> = ["md", "markdown", "txt"]
    /// Directory names always hidden from the tree, even with "Show hidden folders" on —
    /// build/vcs noise that is never useful reading material.
    static let excludedDirectoryNames: Set<String> = ["node_modules", ".git"]

    @Published var iCloudRoot = OutlineFileRoot(
        id: "icloud",
        title: "Lineform",
        systemImage: "icloud",
        state: .unavailable,
        items: []
    )
    @Published var workspaceRoot = OutlineFileRoot(
        id: "workspace",
        title: "Workspace",
        systemImage: "folder",
        state: .unassigned,
        items: []
    )
    @Published var showsHiddenFolders = false {
        didSet {
            guard oldValue != showsHiddenFolders else { return }
            defaults.set(showsHiddenFolders, forKey: Self.showsHiddenFoldersDefaultsKey)
            if showsHiddenFolders {
                // Hidden entries were never enumerated, so a re-scan is required. This runs
                // the same refresh path used when the Files tab appears (main-actor,
                // user-initiated).
                refreshICloudRoot()
                refreshWorkspaceRoot()
            } else {
                // Toggling OFF: the last scans are supersets of the visible tree, so filter
                // in memory instead of re-walking the disk and re-resolving the iCloud
                // container on the main thread just to hide rows we already have.
                if iCloudRoot.showsTree {
                    iCloudRoot.items = filteredForDisplay(lastICloudItems)
                }
                if workspaceRoot.showsTree {
                    workspaceRoot.items = filteredForDisplay(lastWorkspaceItems)
                }
            }
        }
    }

    /// Whether the iCloud container resolved on this machine the LAST time any scan
    /// ran, persisted across launches. Surfaces that need "is iCloud a thing here"
    /// BEFORE the deferred Files-tab scan (the adaptive root-collapse lock, the
    /// Settings modal's first frame) read this instead of live root state — which is
    /// hardcoded `.unavailable` until a scan and would otherwise flash locked/wrong
    /// UI on iCloud machines. Optimistic `true` when never recorded, so fresh
    /// installs (mostly real users with iCloud) don't flash either.
    @Published private(set) var lastKnownICloudAvailable = true

    /// True once refreshICloud() has run this session. Quick-open (⌘K) reads this to
    /// trigger the deferred iCloud scan exactly once per session instead of on every
    /// palette open — the Files tab's every-appearance refresh is unchanged.
    private(set) var hasPerformedICloudScan = false

    private func recordICloudAvailability(_ available: Bool) {
        guard available != lastKnownICloudAvailable else { return }
        lastKnownICloudAvailable = available
        defaults.set(available, forKey: Self.lastKnownICloudAvailableDefaultsKey)
    }

    /// Per-section sort preferences (spec: independent for iCloud and workspace, like Muse).
    @Published var iCloudSortOrder = OutlineFileSortOrder.name {
        didSet {
            guard oldValue != iCloudSortOrder else { return }
            defaults.set(iCloudSortOrder.rawValue, forKey: Self.iCloudSortOrderDefaultsKey)
            applySortOrderChange(toICloudRoot: true)
        }
    }
    @Published var workspaceSortOrder = OutlineFileSortOrder.name {
        didSet {
            guard oldValue != workspaceSortOrder else { return }
            defaults.set(workspaceSortOrder.rawValue, forKey: Self.workspaceSortOrderDefaultsKey)
            applySortOrderChange(toICloudRoot: false)
        }
    }

    /// A sort change re-SCANS a live root rather than re-sorting the cached tree: the
    /// 80-per-folder cap is applied in display order, so the order decides WHICH children
    /// are retained, not just their arrangement (re-sorting 80 name-first files can never
    /// surface the recently-modified ones the old cap discarded). Only cached/disconnected
    /// trees fall back to an in-memory re-sort. Sort changes originate from the visible
    /// Files tab's sort row, so the scan is as sanctioned as the tab-appear refresh.
    private func applySortOrderChange(toICloudRoot: Bool) {
        if toICloudRoot {
            if resolvedICloudDocumentsURL != nil {
                refreshICloudRoot()
            } else {
                lastICloudItems = OutlineFileSortOrder.sorted(lastICloudItems, by: iCloudSortOrder)
                if iCloudRoot.showsTree {
                    iCloudRoot.items = filteredForDisplay(lastICloudItems)
                }
            }
        } else {
            if workspaceURL != nil, workspaceRoot.state == .available {
                refreshWorkspaceRoot()
            } else {
                lastWorkspaceItems = OutlineFileSortOrder.sorted(lastWorkspaceItems, by: workspaceSortOrder)
                if workspaceRoot.showsTree {
                    workspaceRoot.items = filteredForDisplay(lastWorkspaceItems)
                }
            }
        }
    }

    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let iCloudDocumentsURLProvider: (FileManager) -> URL?
    private let iCloudDownloader: UbiquitousItemDownloader
    private let scopeAccessor: SecurityScopedResourceAccessing
    private let directoryMonitorFactory: DirectoryChangeMonitorFactory
    /// Trailing debounce interval for monitor-driven rescans (0 → run synchronously, the
    /// test fast-path). Only the FSEvents `onChange` path is debounced; every user-initiated
    /// refresh stays instant.
    private let directoryRescanDebounce: TimeInterval
    private var pendingWorkspaceRescan: DispatchWorkItem?
    private var pendingICloudRescan: DispatchWorkItem?
    /// When true (production), the recursive `items(in:)` walk runs on `scanQueue` and its
    /// result is applied back on the main thread — so a ~35ms+ scan of thousands of files never
    /// blocks typing/file-switching (Task 5 escalation). Default false keeps the walk inline
    /// and synchronous: concurrency is opt-in at the one production site, and the existing test
    /// suite keeps asserting synchronously (never a race by default).
    private let runsScanInBackground: Bool
    private let scanQueue = DispatchQueue(label: "com.lineform.outline.directory-scan", qos: .userInitiated)
    /// Latest-wins guards: bumped at each refresh entry so a background scan whose apply arrives
    /// after a newer refresh started (e.g. the workspace was reassigned meanwhile) is discarded.
    private(set) var workspaceScanGeneration: UInt64 = 0
    private(set) var iCloudScanGeneration: UInt64 = 0
    private var workspaceMonitor: DirectoryChangeMonitoring?
    private var iCloudMonitor: DirectoryChangeMonitoring?
    /// Whether the Files tab wants live watching right now. Tracked separately from the
    /// monitors because a root can be watchable-but-unassigned (no workspace chosen yet):
    /// choosing one mid-session must start its monitor even though none existed before.
    private var isWatchingForExternalChanges = false
    /// The resolved iCloud Documents URL from the last successful refresh; nil until the
    /// deferred first scan has run (so watching can never resolve the container itself).
    private var resolvedICloudDocumentsURL: URL?
    private var lastICloudItems: [OutlineFileTreeItem] = []
    private var workspaceURL: URL?
    private var lastWorkspaceItems: [OutlineFileTreeItem] = []
    /// The workspace URL whose security scope is currently held (nil when none is active).
    /// Held for the store's lifetime so every read under the workspace — opening a document
    /// from the sidebar, live reload, the directory scan — happens under a live grant.
    private var heldWorkspaceScopeURL: URL?

    init(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        iCloudDocumentsURLProvider: @escaping (FileManager) -> URL? = OutlineFileBrowserStore.lineformICloudDocumentsURL,
        iCloudDownloader: UbiquitousItemDownloader? = nil,
        scopeAccessor: SecurityScopedResourceAccessing = URLSecurityScopedResourceAccessor(),
        directoryMonitorFactory: DirectoryChangeMonitorFactory? = nil,
        directoryRescanDebounce: TimeInterval = OutlineFileBrowserStore.directoryRescanDebounceInterval,
        runsScanInBackground: Bool = false
    ) {
        self.defaults = defaults
        self.fileManager = fileManager
        self.iCloudDocumentsURLProvider = iCloudDocumentsURLProvider
        self.iCloudDownloader = iCloudDownloader ?? fileManager
        self.scopeAccessor = scopeAccessor
        self.directoryRescanDebounce = directoryRescanDebounce
        self.runsScanInBackground = runsScanInBackground
        // The background scan path uses FileManager.default (FileManager isn't Sendable), so an
        // injected non-default FileManager is honored ONLY on the synchronous path. Guard the
        // mismatch: a test/variant injecting a fake FileManager with background scanning would
        // silently diverge (sync branch uses the fake, background branch uses .default).
        assert(
            !runsScanInBackground || fileManager === FileManager.default,
            "runsScanInBackground uses FileManager.default; injecting a non-default FileManager is unsupported"
        )
        self.directoryMonitorFactory = directoryMonitorFactory ?? { url, onChange in
            DirectoryEventMonitor(url: url, onChange: onChange)
        }
        // Set before any refresh. IMPORTANT: `didSet` observers on @Published properties DO
        // fire for plain assignments made in init (the assignment goes through the wrapper's
        // setter — unlike plain stored properties), so initialize the backing storage
        // directly. A persisted showsHiddenFolders=true would otherwise trigger the
        // init-forbidden main-thread iCloud scan via its didSet.
        _showsHiddenFolders = Published(initialValue: defaults.bool(forKey: Self.showsHiddenFoldersDefaultsKey))
        _iCloudSortOrder = Published(
            initialValue: OutlineFileSortOrder(rawValue: defaults.string(forKey: Self.iCloudSortOrderDefaultsKey) ?? "") ?? .name
        )
        _workspaceSortOrder = Published(
            initialValue: OutlineFileSortOrder(rawValue: defaults.string(forKey: Self.workspaceSortOrderDefaultsKey) ?? "") ?? .name
        )
        _lastKnownICloudAvailable = Published(
            initialValue: defaults.object(forKey: Self.lastKnownICloudAvailableDefaultsKey) as? Bool ?? true
        )
        loadICloudSnapshot()
        loadWorkspaceSnapshot()
        loadWorkspaceBookmark()
        // The live iCloud scan resolves the ubiquity container and enumerates the
        // directory, which is expensive and must not run on the main thread at
        // construction (it blocks launch and perturbs hosted-view layout). It is
        // deferred to refreshICloud(), called when the Files tab is actually shown.
        refreshWorkspaceRoot()
    }

    /// Performs the live iCloud container scan. Call this when the Files tab
    /// becomes visible (or from tests); it is intentionally not run at init.
    func refreshICloud() {
        hasPerformedICloudScan = true
        refreshICloudRoot()
    }

    /// Re-scans the workspace folder (same path init uses). Exposed for tests that
    /// assert the held security scope survives re-scans.
    func refreshWorkspace() {
        refreshWorkspaceRoot()
    }

    /// Starts watching both roots for external file-system changes. Called when the
    /// Files tab becomes visible, AFTER refreshICloud() has resolved the container —
    /// this never resolves or scans anything itself, preserving the deferred-scan
    /// invariant. Idempotent while watching.
    func beginWatchingForExternalChanges() {
        isWatchingForExternalChanges = true
        if workspaceMonitor == nil, let workspaceURL {
            workspaceMonitor = directoryMonitorFactory(workspaceURL) { [weak self] in
                self?.scheduleWorkspaceRescan()
            }
        }
        if iCloudMonitor == nil, let url = resolvedICloudDocumentsURL {
            iCloudMonitor = directoryMonitorFactory(url) { [weak self] in
                self?.scheduleICloudRescan()
            }
        }
    }

    /// Stops watching (Files tab hidden / view gone). Cheap to call repeatedly. Also cancels
    /// any pending debounced rescan: once the tab is hidden a late walk is wasted work, and
    /// the next tab-appear rescans anyway.
    func endWatchingForExternalChanges() {
        isWatchingForExternalChanges = false
        workspaceMonitor?.stop()
        workspaceMonitor = nil
        iCloudMonitor?.stop()
        iCloudMonitor = nil
        pendingWorkspaceRescan?.cancel()
        pendingWorkspaceRescan = nil
        pendingICloudRescan?.cancel()
        pendingICloudRescan = nil
    }

    /// Trailing-debounced rescan for the workspace root, fed by the FSEvents monitor only.
    /// Autosave-while-typing churn keeps resetting the timer so the recursive directory walk
    /// runs once after the burst settles instead of on every coalesced tick (Task 5). Mirrors
    /// `DocumentReloadController`'s debounce, including the `interval == 0` synchronous
    /// fast-path used by tests. User-initiated refreshes call `refreshWorkspaceRoot()` directly.
    private func scheduleWorkspaceRescan() {
        pendingWorkspaceRescan?.cancel()
        guard directoryRescanDebounce > 0 else {
            refreshWorkspaceRoot()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.pendingWorkspaceRescan = nil
            self?.refreshWorkspaceRoot()
        }
        pendingWorkspaceRescan = work
        DispatchQueue.main.asyncAfter(deadline: .now() + directoryRescanDebounce, execute: work)
    }

    /// Trailing-debounced rescan for the iCloud root, fed by the FSEvents monitor only.
    private func scheduleICloudRescan() {
        pendingICloudRescan?.cancel()
        guard directoryRescanDebounce > 0 else {
            refreshICloudRoot()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.pendingICloudRescan = nil
            self?.refreshICloudRoot()
        }
        pendingICloudRescan = work
        DispatchQueue.main.asyncAfter(deadline: .now() + directoryRescanDebounce, execute: work)
    }

    /// Targeted refresh after an in-app rename/delete: re-scan only the root containing
    /// `url` (nil or unmatched → both), keeping the app-wide broadcast cheap when several
    /// windows show Files tabs. Only called from visible Files tabs, so the iCloud
    /// resolution stays as sanctioned as the tab-appear refresh.
    func refreshRoots(affecting url: URL?) {
        func rootContains(_ root: URL?) -> Bool {
            guard let root, let path = url?.standardizedFileURL.path else { return false }
            let rootPath = root.standardizedFileURL.path
            return path == rootPath || path.hasPrefix(rootPath + "/")
        }

        let inWorkspace = rootContains(workspaceURL)
        let inICloud = rootContains(resolvedICloudDocumentsURL)
        if inWorkspace || !inICloud {
            refreshWorkspaceRoot()
        }
        if inICloud || !inWorkspace {
            refreshICloudRoot()
        }
    }

    @MainActor
    func chooseWorkspaceFolder() {
        let panel = folderSelectionPanel(prompt: "Choose")

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        setWorkspaceURL(url)
    }

    @MainActor
    private func folderSelectionPanel(prompt: String) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = prompt
        return panel
    }

    private func loadWorkspaceBookmark() {
        guard let data = defaults.data(forKey: Self.workspaceBookmarkDefaultsKey) else {
            workspaceURL = nil
            return
        }

        workspaceURL = resolveBookmark(from: data, defaultsKey: Self.workspaceBookmarkDefaultsKey)
    }

    private func resolveBookmark(from data: Data, defaultsKey: String) -> URL? {
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            if isStale {
                saveBookmark(for: url, defaultsKey: defaultsKey)
            }

            // Hold the resolved workspace's scope for the store's lifetime. A transient
            // start/stop around the directory scan is NOT enough: the moment the scope is
            // stopped, file reads under the workspace (opening a document from the sidebar,
            // live reload) fail with "you don't have permission" — which is exactly what
            // users hit on every launch after a relaunch, since only this bookmark carries
            // the sandbox grant across launches.
            holdWorkspaceScope(for: url)

            return url
        } catch {
            return nil
        }
    }

    /// Begins (and keeps) security-scoped access to `url`, releasing any previously held
    /// workspace scope first. No-ops when `url` is already the held workspace.
    private func holdWorkspaceScope(for url: URL) {
        guard heldWorkspaceScopeURL != url else { return }
        releaseWorkspaceScope()
        if scopeAccessor.beginAccess(to: url) {
            heldWorkspaceScopeURL = url
        }
    }

    private func releaseWorkspaceScope() {
        guard let held = heldWorkspaceScopeURL else { return }
        scopeAccessor.endAccess(to: held)
        heldWorkspaceScopeURL = nil
    }

    deinit {
        workspaceMonitor?.stop()
        iCloudMonitor?.stop()
        pendingWorkspaceRescan?.cancel()
        pendingICloudRescan?.cancel()
        releaseWorkspaceScope()
    }

    private func loadICloudSnapshot() {
        // Snapshots were saved under whatever sort order was active then; re-sort so a
        // changed preference applies to the cached tree before any live scan runs.
        lastICloudItems = OutlineFileSortOrder.sorted(
            loadSnapshot(defaultsKey: Self.iCloudSnapshotDefaultsKey),
            by: iCloudSortOrder
        )
    }

    private func loadWorkspaceSnapshot() {
        lastWorkspaceItems = OutlineFileSortOrder.sorted(
            loadSnapshot(defaultsKey: Self.workspaceSnapshotDefaultsKey),
            by: workspaceSortOrder
        )
    }

    private func loadSnapshot(defaultsKey: String) -> [OutlineFileTreeItem] {
        guard let data = defaults.data(forKey: defaultsKey),
              let items = try? JSONDecoder().decode([OutlineFileTreeItem].self, from: data)
        else {
            return []
        }

        return items
    }

    private func saveSnapshot(_ items: [OutlineFileTreeItem], defaultsKey: String) {
        guard let data = try? JSONEncoder().encode(items) else {
            return
        }

        defaults.set(data, forKey: defaultsKey)
    }

    /// Filter a cached tree for display against the current toggle. Live scans already honor
    /// `showsHiddenFolders`, but a snapshot may have been saved under a different toggle value;
    /// this keeps a stale cache (e.g. the disconnected-workspace fallback) consistent.
    private func filteredForDisplay(_ items: [OutlineFileTreeItem]) -> [OutlineFileTreeItem] {
        guard !showsHiddenFolders else { return items }
        return items.compactMap { item in
            guard !item.isHidden else { return nil }
            var visible = item
            visible.children = filteredForDisplay(item.children)
            return visible
        }
    }

    private func setWorkspaceURL(_ url: URL) {
        // Retarget a live watcher at the newly chosen folder (stop now, restart after the
        // refresh below re-resolves everything). Keyed off isWatchingForExternalChanges,
        // not monitor existence — a first-ever workspace choice has no monitor yet but
        // still needs one if the Files tab is watching.
        workspaceMonitor?.stop()
        workspaceMonitor = nil
        // Drop any debounced rescan queued against the old workspace's monitor; the direct
        // refresh below re-scans the new folder, so a late fire would only be redundant work.
        pendingWorkspaceRescan?.cancel()
        pendingWorkspaceRescan = nil

        workspaceURL = url
        saveBookmark(for: url, defaultsKey: Self.workspaceBookmarkDefaultsKey)
        // A same-session NSOpenPanel URL carries an implicit grant (beginAccess returns
        // false and nothing is held), but re-resolving our own saved bookmark yields a
        // scoped URL whose grant outlives this session. Swap the held scope to the new
        // workspace either way so the old folder's grant is released.
        var isStale = false
        if let bookmarkData = defaults.data(forKey: Self.workspaceBookmarkDefaultsKey),
           let scopedURL = try? URL(
               resolvingBookmarkData: bookmarkData,
               options: [.withSecurityScope],
               relativeTo: nil,
               bookmarkDataIsStale: &isStale
           ) {
            holdWorkspaceScope(for: scopedURL)
        } else {
            releaseWorkspaceScope()
        }
        refreshWorkspaceRoot()
        if isWatchingForExternalChanges {
            beginWatchingForExternalChanges()
        }
    }

    private func saveBookmark(for url: URL, defaultsKey: String) {
        do {
            let bookmark = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            defaults.set(bookmark, forKey: defaultsKey)
        } catch {
            defaults.removeObject(forKey: defaultsKey)
        }
    }

    /// Runs the recursive `items(in:)` walk and hands the result to `apply`. In production
    /// (`runsScanInBackground`) the walk runs on `scanQueue` — a ~35ms+ scan of thousands of
    /// files must not block the main thread (typing/file-switching) — and `apply` is invoked
    /// back on the main thread. Otherwise (tests, default) it runs inline and synchronously.
    ///
    /// `apply` is ALWAYS invoked on the main thread here (inline from a main-thread caller, or
    /// via `DispatchQueue.main.async`), so the `nonisolated(unsafe)` capture is safe: the
    /// closure mutates the store only on the main thread. The background path uses
    /// `FileManager.default` rather than the injected `fileManager` because `FileManager` is
    /// not `Sendable`; production always injects `.default` (equivalent), and test doubles use
    /// the synchronous path with their injected `fileManager`.
    private func performScan(
        in url: URL,
        showsHidden: Bool,
        sortOrder: OutlineFileSortOrder,
        apply: @escaping ([OutlineFileTreeItem]) -> Void
    ) {
        // The store isn't @MainActor, so the "everything but the walk runs on main" invariant
        // is convention. Assert it so a future off-main caller crashes loudly (in Debug/CI)
        // instead of racing silently — the `nonisolated(unsafe)` below disables the compiler's
        // one guard against exactly that.
        assert(Thread.isMainThread, "performScan must be called on the main thread")
        guard runsScanInBackground else {
            apply(Self.items(in: url, fileManager: fileManager, showsHiddenFolders: showsHidden, sortOrder: sortOrder))
            return
        }
        nonisolated(unsafe) let applyOnMain = apply
        scanQueue.async {
            let items = OutlineFileBrowserStore.items(
                in: url, fileManager: .default, showsHiddenFolders: showsHidden, sortOrder: sortOrder
            )
            DispatchQueue.main.async { applyOnMain(items) }
        }
    }

    private func refreshICloudRoot() {
        // Bumped up front so an in-flight background scan from a prior refresh is discarded
        // by the generation guard in applyICloudScan (latest-wins).
        iCloudScanGeneration &+= 1
        let generation = iCloudScanGeneration

        // Cleared up front so every early return leaves it nil; only a successful scan
        // (re)establishes the resolved URL the watcher is allowed to use.
        resolvedICloudDocumentsURL = nil

        guard let url = iCloudDocumentsURLProvider(fileManager) else {
            recordICloudAvailability(false)
            iCloudRoot = OutlineFileRoot(
                id: "icloud",
                title: "Lineform",
                systemImage: "icloud",
                state: .unavailable,
                items: []
            )
            return
        }

        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)

        var isDirectory: ObjCBool = false
        guard
            fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            recordICloudAvailability(false)
            iCloudRoot = OutlineFileRoot(
                id: "icloud",
                title: "Lineform",
                systemImage: "icloud",
                state: .unavailable,
                items: []
            )
            return
        }

        recordICloudAvailability(true)
        resolvedICloudDocumentsURL = url
        performScan(in: url, showsHidden: showsHiddenFolders, sortOrder: iCloudSortOrder) { [weak self] items in
            self?.applyICloudScan(items, generation: generation)
        }
    }

    /// Applies a completed iCloud scan on the main thread. Internal + generation-guarded so it
    /// is synchronously unit-testable and so a stale background scan (an older generation, e.g.
    /// after a newer refresh started) is dropped. Mirrors `DocumentReloadController.applyDiskSnapshot`.
    func applyICloudScan(_ items: [OutlineFileTreeItem], generation: UInt64) {
        assert(Thread.isMainThread, "applyICloudScan must run on the main thread (@Published mutation)")
        guard generation == iCloudScanGeneration else { return }
        let itemsChanged = items != lastICloudItems
        lastICloudItems = items
        if itemsChanged {
            saveSnapshot(items, defaultsKey: Self.iCloudSnapshotDefaultsKey)
            // Keep the user's iCloud working set materialized locally. Evicted
            // (dataless) files otherwise show in search but fail to open or drag,
            // which is one of the failure modes that made files feel "lost."
            Self.ensureDownloaded(items, using: iCloudDownloader)
        }

        let newRoot = OutlineFileRoot(
            id: "icloud",
            title: "Lineform",
            systemImage: "icloud",
            state: .available,
            items: items
        )
        // FSEvents ticks fire for any churn under the tree (temp files, non-Markdown
        // writes); skip the publish when the visible tree is identical so SwiftUI
        // doesn't re-diff it for nothing.
        if newRoot != iCloudRoot {
            iCloudRoot = newRoot
        }
    }

    /// The workspace root's display title: the chosen folder's name, or "Workspace" when unassigned.
    static func workspaceTitle(for url: URL?) -> String {
        url?.lastPathComponent ?? "Workspace"
    }

    private func refreshWorkspaceRoot() {
        // Bumped up front so an in-flight background scan from a prior refresh (or from before
        // the workspace was reassigned) is discarded by the generation guard in
        // applyWorkspaceScan (latest-wins).
        workspaceScanGeneration &+= 1
        let generation = workspaceScanGeneration

        guard let workspaceURL else {
            workspaceRoot = OutlineFileRoot(
                id: "workspace",
                title: Self.workspaceTitle(for: nil),
                systemImage: "folder",
                state: .unassigned,
                items: []
            )
            return
        }

        if let data = defaults.data(forKey: Self.workspaceBookmarkDefaultsKey),
           let resolvedURL = resolveBookmark(from: data, defaultsKey: Self.workspaceBookmarkDefaultsKey),
           resolvedURL != workspaceURL {
            self.workspaceURL = resolvedURL
            refreshWorkspaceRoot()
            return
        }

        var isDirectory: ObjCBool = false
        guard
            fileManager.fileExists(atPath: workspaceURL.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            workspaceRoot = OutlineFileRoot(
                id: "workspace",
                title: Self.workspaceTitle(for: workspaceURL),
                systemImage: "folder.badge.questionmark",
                state: .disconnected,
                // Cached snapshot may have been saved while the toggle was ON; re-filter it so
                // hidden items don't leak into a toggle-OFF view while disconnected.
                items: filteredForDisplay(lastWorkspaceItems)
            )
            return
        }

        // No transient start/stop here: the workspace scope is held for the store's
        // lifetime (see holdWorkspaceScope), which is what keeps file OPENS working —
        // a scope that ends when this scan returns leaves NSDocumentController reading
        // the user's files with no grant at all. The held scope is a PROCESS-wide grant, so
        // it also covers the background scan thread.
        let url = workspaceURL

        // Seed the visible root from the cached snapshot synchronously so the first frame after
        // launch shows the saved tree and folder name — NOT a "Choose folder"/empty flash —
        // while the background scan runs (the scan is off-main now, so it lands a frame + ~35ms
        // later). On a normal rescan the root is already `.available`, so this is skipped and
        // the background scan reconciles in place.
        if workspaceRoot.state != .available {
            let seededRoot = OutlineFileRoot(
                id: "workspace",
                title: Self.workspaceTitle(for: url),
                systemImage: "folder",
                state: .available,
                items: filteredForDisplay(lastWorkspaceItems)
            )
            if seededRoot != workspaceRoot {
                workspaceRoot = seededRoot
            }
        }

        performScan(in: url, showsHidden: showsHiddenFolders, sortOrder: workspaceSortOrder) { [weak self] items in
            self?.applyWorkspaceScan(items, url: url, generation: generation)
        }
    }

    /// Applies a completed workspace scan on the main thread. Internal + generation-guarded so
    /// it is synchronously unit-testable and so a stale background scan is dropped (e.g. one
    /// dispatched before the workspace was reassigned or the tab went unassigned/disconnected).
    /// The `url` guard is belt-and-suspenders alongside the generation guard: never publish a
    /// scan of a folder that is no longer the current workspace.
    func applyWorkspaceScan(_ items: [OutlineFileTreeItem], url: URL, generation: UInt64) {
        assert(Thread.isMainThread, "applyWorkspaceScan must run on the main thread (@Published mutation)")
        guard generation == workspaceScanGeneration, workspaceURL == url else { return }
        if items != lastWorkspaceItems {
            saveSnapshot(items, defaultsKey: Self.workspaceSnapshotDefaultsKey)
        }
        lastWorkspaceItems = items

        let newRoot = OutlineFileRoot(
            id: "workspace",
            title: Self.workspaceTitle(for: url),
            systemImage: "folder",
            state: .available,
            items: items
        )
        // Same publish guard as the iCloud root: don't re-diff an identical tree on
        // every coalesced FSEvents tick.
        if newRoot != workspaceRoot {
            workspaceRoot = newRoot
        }
    }

    /// Internal (not private) so the Settings iCloud probe resolves the SAME folder
    /// the sidebar renders — the container-relative path must live in one place.
    static func lineformICloudDocumentsURL(fileManager: FileManager) -> URL? {
        fileManager
            .url(forUbiquityContainerIdentifier: iCloudContainerIdentifier)?
            .appendingPathComponent("Documents", isDirectory: true)
    }

    /// Requests that every file in the tree be downloaded/kept local. Returns the
    /// files that were successfully requested. Folders are descended into but not
    /// themselves requested; items that cannot be materialized are skipped.
    @discardableResult
    static func ensureDownloaded(
        _ items: [OutlineFileTreeItem],
        using downloader: UbiquitousItemDownloader
    ) -> [URL] {
        var requested: [URL] = []
        for item in items {
            if item.isDirectory {
                requested.append(contentsOf: ensureDownloaded(item.children, using: downloader))
            } else if (try? downloader.startDownloadingUbiquitousItem(at: item.url)) != nil {
                requested.append(item.url)
            }
        }
        return requested
    }

    /// Whether a documents folder has no display-worthy content — used by the
    /// Settings iCloud toggle to decide if the user may hide the iCloud root.
    /// Deliberately CONSERVATIVE: scans with hidden folders INCLUDED (regardless of
    /// the user's Show Hidden Folders setting), so a folder whose only content is
    /// dot-folder Markdown still counts as non-empty — the guard must never allow
    /// hiding a root the sidebar could visibly render files under. Depth-limited to
    /// one level because `items(in:)` includes a directory regardless of its
    /// contents, so emptiness is decided entirely by the top-level enumeration (no
    /// full-tree walk on large iCloud folders). Read-only; never writes.
    static func documentsFolderIsEmpty(at url: URL, fileManager: FileManager) -> Bool {
        items(
            in: url,
            fileManager: fileManager,
            depth: maximumTreeDepth - 1,
            showsHiddenFolders: true
        ).isEmpty
    }

    private static func items(
        in url: URL,
        fileManager: FileManager,
        depth: Int = 0,
        showsHiddenFolders: Bool,
        inheritedHidden: Bool = false,
        sortOrder: OutlineFileSortOrder = .name
    ) -> [OutlineFileTreeItem] {
        guard depth < maximumTreeDepth else {
            return []
        }

        let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isHiddenKey, .creationDateKey, .contentModificationDateKey]
        let options: FileManager.DirectoryEnumerationOptions = showsHiddenFolders ? [] : [.skipsHiddenFiles]
        let urls = (try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(resourceKeys),
            options: options
        )) ?? []

        // Resolve each child's shallow attributes first (children left empty — no recursion
        // yet), then sort and cap. Recursing only into the retained children keeps the
        // per-folder cap from being defeated by folders with thousands of subdirectories:
        // we build subtrees for the ~80 we keep, not for every sibling we're about to
        // discard. Output is identical to sort-then-recurse because the sort order depends
        // only on `isDirectory`, `name`, and the item's own creation/modification dates,
        // all shallow attributes known here (and never on `children`).
        let shallow = urls.compactMap { childURL -> OutlineFileTreeItem? in
            guard let values = try? childURL.resourceValues(forKeys: resourceKeys) else {
                return nil
            }

            let name = childURL.lastPathComponent
            let isDirectory = values.isDirectory == true

            // Always exclude build/vcs noise directories, regardless of the toggle.
            if isDirectory, excludedDirectoryNames.contains(name) {
                return nil
            }

            // With hidden folders shown, .skipsHiddenFiles is dropped — so also drop genuinely
            // OS-hidden items that are NOT dot-prefixed (system junk), while keeping dotfiles.
            let isDotPrefixed = name.hasPrefix(".")
            if showsHiddenFolders, values.isHidden == true, !isDotPrefixed {
                return nil
            }

            let isSupportedFile = values.isRegularFile == true
                && supportedFileExtensions.contains(childURL.pathExtension.lowercased())

            guard isDirectory || isSupportedFile else {
                return nil
            }

            return OutlineFileTreeItem(
                url: childURL,
                name: name,
                isDirectory: isDirectory,
                children: [],
                isHidden: inheritedHidden || isDotPrefixed,
                createdAt: values.creationDate,
                modifiedAt: values.contentModificationDate
            )
        }
        .sorted { OutlineFileSortOrder.areInIncreasingOrder($0, $1, order: sortOrder) }
        .prefix(maximumChildrenPerFolder)

        return shallow.map { item in
            guard item.isDirectory else { return item }
            var populated = item
            populated.children = items(
                in: item.url,
                fileManager: fileManager,
                depth: depth + 1,
                showsHiddenFolders: showsHiddenFolders,
                inheritedHidden: item.isHidden,
                sortOrder: sortOrder
            )
            return populated
        }
    }
}

private struct OutlineFileBrowserView: View {
    @ObservedObject var store: OutlineFileBrowserStore
    var openFile: (URL) -> Void
    var currentFileURL: URL?
    /// Injected from OutlineSidebarView (which defaults it to .shared for the app) so
    /// tests and previews can isolate the sidebar-affecting settings. Declared before
    /// the defaulted closures so the memberwise init's parameter order matches call sites.
    @ObservedObject var settings: LineformSettingsStore
    // Threaded from the theme (see SidebarTabButton) rather than read from ambient colorScheme:
    // nested rows here are Buttons whose colorScheme re-derives from the window's drift-prone
    // effectiveAppearance, which would flash near-black text on the near-black dark sidebar.
    var usesDarkChrome: Bool
    var renameItem: (OutlineFileTreeItem) -> Void = { _ in }
    var deleteItem: (OutlineFileTreeItem) -> Void = { _ in }
    var revealItem: (OutlineFileTreeItem) -> Void = { _ in }
    @State private var collapsedIDs: Set<String> = []
    @State private var isSortHovered = false

    var body: some View {
        // "Show Hidden Folders" now lives in the View menu (⌘⇧.), so the Files tab is just
        // the file tree — no in-sidebar toggle chrome.
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                globalSortRow

                if OutlineSidebarView.iCloudRootVisible(state: store.iCloudRoot.state, showICloudInSidebar: settings.showICloudInSidebar) {
                    rootView(store.iCloudRoot)
                }
                rootView(store.workspaceRoot)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, OutlineSidebarView.filesContentHorizontalPadding)
            .padding(.top, OutlineSidebarView.tabDividerGap)
            .padding(.bottom, 14)
        }
        .scrollContentBackground(.hidden)
    }

    private var globalSortRow: some View {
        Menu {
            // An inline Picker (not hand-rolled Buttons) so the checkmark uses the OS's native
            // selection gutter — matching the Font menu in the Reading Experience panel. The
            // hidden label keeps it header-free, and the custom trigger below is unaffected.
            Picker("Sort folders by", selection: globalSortOrder) {
                ForEach(OutlineFileSortOrder.allCases) { order in
                    Text(order.title).tag(order)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 10, weight: .semibold))
                Text("Sort folders by: \(globalSortOrder.wrappedValue.title)")
                    .font(.system(size: 12, weight: .medium))
            }
            // Same quiet grey as the inactive tabs above, darkening on hover.
            .foregroundStyle(OutlineSidebarView.tabTextColor(
                usesDarkChrome: usesDarkChrome,
                isSelected: false,
                isHovered: isSortHovered
            ))
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        // Align the sort icon to the shared icon column (content inset 6 + 18 = 24).
        .padding(.leading, OutlineSidebarView.sidebarIconColumnLeading - OutlineSidebarView.filesContentHorizontalPadding)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isSortHovered = hovering
            }
        }
        .accessibilityLabel("Sort folders by")
        .accessibilityValue(globalSortOrder.wrappedValue.title)
    }

    private var globalSortOrder: Binding<OutlineFileSortOrder> {
        Binding(
            get: { store.iCloudSortOrder },
            set: { newValue in
                store.iCloudSortOrder = newValue
                store.workspaceSortOrder = newValue
            }
        )
    }

    @ViewBuilder
    private func rootView(_ root: OutlineFileRoot) -> some View {
        // Whether root collapsing is allowed only decides if a chevron is drawn; the chevron
        // slot is ALWAYS reserved so root/file/folder icons stay pinned to the shared icon
        // column whether or not a chevron is visible (no left-shift on lock).
        let lockExpanded = self.lockExpanded

        VStack(alignment: .leading, spacing: 2) {
            OutlineFileRootRow(
                root: root,
                isCollapsed: isRootCollapsed(root.id, lockExpanded: lockExpanded),
                lockExpanded: lockExpanded,
                usesDarkChrome: usesDarkChrome,
                toggleCollapsed: { toggle(root.id) },
                chooseWorkspaceFolder: store.chooseWorkspaceFolder
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            // A dimmed iCloud root (unavailable or connected-but-empty) reads as inactive: no
            // expandable tree, no empty-state line — just the quiet header.
            if root.showsTree, !isRootCollapsed(root.id, lockExpanded: lockExpanded), !rootIsDimmed(root) {
                if root.items.isEmpty {
                    // Only a connected (.available) empty folder is genuinely "no Markdown." A
                    // disconnected folder's emptiness just means the cached snapshot is empty — the
                    // header's disconnected icon already signals that, so don't claim it's empty.
                    if root.state == .available {
                        Text("No Markdown files")
                            .font(.system(size: 12))
                            .foregroundStyle(OutlineSidebarView.secondaryTextColor(usesDarkChrome: usesDarkChrome))
                            .padding(.leading, OutlineSidebarView.sidebarIconColumnLeading - OutlineSidebarView.filesContentHorizontalPadding)
                            .padding(.vertical, 4)
                    }
                } else {
                    // Render the tree from a FLATTENED list of visible rows in a LazyVStack, so a
                    // large fully-expanded workspace only lays out the rows in the viewport. The
                    // old recursive non-lazy VStacks laid out every row at once (~3,840 on a big
                    // workspace), which froze typing/file-switching (Task 5's real cause). Direct
                    // children start at depth 1 so they indent one step past the root's icon.
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(OutlineSidebarView.visibleFileRows(root.items, collapsedIDs: collapsedIDs)) { flatRow in
                            OutlineFileTreeNodeView(
                                item: flatRow.item,
                                depth: flatRow.depth,
                                collapsedIDs: $collapsedIDs,
                                openFile: openFile,
                                currentFileURL: currentFileURL,
                                usesDarkChrome: usesDarkChrome,
                                renameItem: renameItem,
                                deleteItem: deleteItem,
                                revealItem: revealItem
                            )
                        }
                    }
                    .opacity(root.state == .disconnected ? 0.48 : 1)
                    .allowsHitTesting(root.state != .disconnected)
                }
            }
        }
        .opacity(rootIsDimmed(root) ? OutlineSidebarView.filesUnavailableRootOpacity : 1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rootIsDimmed(_ root: OutlineFileRoot) -> Bool {
        if root.id == "icloud" {
            return OutlineSidebarView.iCloudRootIsDimmed(state: root.state, isEmpty: root.items.isEmpty)
        }
        return root.state == .unavailable
    }

    /// Whether the root sections are locked open right now: the user's explicit
    /// Settings choice wins; with no choice, a lone Workspace root (iCloud
    /// unavailable or hidden) auto-locks — one section has nothing to collapse
    /// against, and dropping the chevrons reclaims their column. Reads the store's
    /// PERSISTED last-known iCloud availability, not live root state: live state is
    /// hardcoded `.unavailable` until the deferred Files-tab scan, which would
    /// flash locked geometry on every first tab reveal on iCloud machines.
    private var lockExpanded: Bool {
        !LineformSettingsStore.effectiveAllowRootFolderCollapse(
            choice: settings.allowRootFolderCollapseChoice,
            iCloudRootVisible: settings.showICloudInSidebar && store.lastKnownICloudAvailable
        )
    }

    private func isRootCollapsed(_ id: String, lockExpanded: Bool) -> Bool {
        OutlineSidebarView.rootIsCollapsed(
            isInCollapsedSet: collapsedIDs.contains(id),
            lockExpanded: lockExpanded
        )
    }

    private func toggle(_ id: String) {
        if collapsedIDs.contains(id) {
            collapsedIDs.remove(id)
        } else {
            collapsedIDs.insert(id)
        }
    }
}

private struct OutlineFileRootRow: View {
    var root: OutlineFileRoot
    var isCollapsed: Bool
    var lockExpanded: Bool = false
    // Threaded from the theme (see SidebarTabButton) rather than read from ambient colorScheme,
    // which a nested Button re-derives from the window's drift-prone effectiveAppearance.
    var usesDarkChrome: Bool
    var toggleCollapsed: () -> Void
    var chooseWorkspaceFolder: () -> Void
    @State private var isWorkspaceActionHovered = false

    var body: some View {
        HStack(spacing: 8) {
            // Root headers use a leading icon only for iCloud (the cloud). The workspace
            // root is plain text. An expandable root still uses a chevron; a non-expandable
            // header renders as plain views so VoiceOver doesn't announce an "Expand/Collapse"
            // affordance it can't honor.
            if showsDisclosure {
                Button(action: toggleCollapsed) {
                    rootLeadingContent(showsChevron: true)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isCollapsed ? "Expand \(root.title)" : "Collapse \(root.title)")
            } else {
                // The chevron slot is ALWAYS reserved (even when collapse is locked off) so the
                // root icon stays pinned to the shared icon column, aligned with the file/folder
                // icons below it.
                rootLeadingContent(showsChevron: false)
            }

            Spacer(minLength: 0)

            if root.id == "workspace", root.state != .unavailable {
                if root.state == .disconnected {
                    Image(systemName: OutlineSidebarView.workspaceDisconnectedSystemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(OutlineSidebarView.secondaryTextColor(usesDarkChrome: usesDarkChrome))
                }

                Button {
                    // Both "Choose" (first assign) and "Change" (swap) open the picker; the assign
                    // path overwrites the bookmark in place, and cancelling leaves the current folder.
                    chooseWorkspaceFolder()
                } label: {
                    Text(workspaceActionTitle)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                }
                .buttonStyle(.plain)
                .background {
                    Capsule()
                        .fill(fileActionBackgroundColor)
                }
                .foregroundStyle(fileActionTextColor)
                .onHover { hovering in
                    withAnimation(.easeOut(duration: 0.12)) {
                        isWorkspaceActionHovered = hovering
                    }
                }
            }
        }
        // Chevron hangs at the content edge (the LazyVStack already insets by the chevron
        // column); only a trailing inset for the Change button.
        .padding(.trailing, 6)
        .frame(maxWidth: .infinity, minHeight: OutlineSidebarView.filesRootRowHeight, maxHeight: OutlineSidebarView.filesRootRowHeight, alignment: .leading)
        // Root headers are quiet section labels, not file rows — no hover fill (per design:
        // a non-openable folder header shouldn't light up like a selectable row).
        .contentShape(Rectangle())
    }

    private var titleLabel: some View {
        Text(root.title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(OutlineSidebarView.primaryTextColor(usesDarkChrome: usesDarkChrome))
            .lineLimit(1)
            .opacity(root.state == .disconnected ? 0.48 : 1)
    }

    /// Chevron slot + root icon + title, using the same geometry as the file-tree rows: a small
    /// disclosure glyph right-aligned in a wider slot (nudged toward the icon), with slot + gap
    /// summing to 18 so the root icon stays on the shared icon column. `showsChevron` is false for
    /// a non-collapsible (locked/empty) root, which still reserves the slot so nothing shifts.
    @ViewBuilder
    private func rootLeadingContent(showsChevron: Bool) -> some View {
        HStack(spacing: 0) {
            Group {
                if showsChevron {
                    Image(systemName: chevronSystemImage)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(OutlineSidebarView.secondaryTextColor(usesDarkChrome: usesDarkChrome))
                } else {
                    Color.clear
                }
            }
            .frame(width: OutlineSidebarView.filesChevronSlotWidth, alignment: .trailing)
            .accessibilityHidden(true)

            rootIcon
                .padding(.leading, OutlineSidebarView.filesChevronToIconGap)

            titleLabel
                .padding(.leading, 8)
        }
    }

    @ViewBuilder
    private var rootIcon: some View {
        if root.id == "icloud", root.state != .unavailable {
            Image(systemName: "icloud")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(OutlineSidebarView.secondaryTextColor(usesDarkChrome: usesDarkChrome))
                .frame(width: 18, alignment: .center)
                .opacity(root.state == .disconnected ? 0.48 : 1)
                .accessibilityHidden(true)
        } else if root.id == "workspace", root.state != .unavailable {
            // A folder icon on the workspace header keeps it in the shared icon column
            // (matching the file/folder rows below it), like the iCloud cloud icon.
            Image(systemName: "folder")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(OutlineSidebarView.secondaryTextColor(usesDarkChrome: usesDarkChrome))
                .frame(width: 18, alignment: .center)
                .opacity(root.state == .disconnected ? 0.48 : 1)
                .accessibilityHidden(true)
        }
    }

    private var showsDisclosure: Bool {
        OutlineSidebarView.rootDisclosureVisible(
            state: root.state,
            isEmpty: root.items.isEmpty,
            lockExpanded: lockExpanded
        )
    }

    private var chevronSystemImage: String {
        isCollapsed ? "chevron.right" : "chevron.down"
    }

    private var workspaceActionTitle: String {
        root.state == .unassigned
            ? OutlineSidebarView.chooseWorkspaceButtonTitle
            : OutlineSidebarView.changeWorkspaceButtonTitle
    }

    /// The first-time "Choose" call-to-action is the only high-contrast (near-black) button.
    /// Once a workspace exists, "Change" is a secondary action, so it reads as a quiet grey.
    private var isChooseAction: Bool {
        root.state == .unassigned
    }

    private var fileActionBackgroundColor: Color {
        let white: CGFloat
        if isChooseAction {
            // Prominent CTA: near-black (light) / near-white (dark).
            white = usesDarkChrome
                ? (isWorkspaceActionHovered ? 1.0 : 0.92)
                : (isWorkspaceActionHovered ? 0.12 : 0.20)
        } else {
            // Quiet secondary "Change": light grey that shifts on hover.
            white = usesDarkChrome
                ? (isWorkspaceActionHovered ? 0.48 : 0.40)
                : (isWorkspaceActionHovered ? 0.86 : 0.91)
        }
        return Color(nsColor: NSColor(calibratedWhite: white, alpha: 1))
    }

    private var fileActionTextColor: Color {
        let white: CGFloat
        if isChooseAction {
            white = usesDarkChrome ? 0.10 : 1.0
        } else {
            // Softer than pure black/white on the light-grey fill.
            white = usesDarkChrome ? 0.98 : 0.34
        }
        return Color(nsColor: NSColor(calibratedWhite: white, alpha: 1))
    }
}

/// Muse-style quiet sort control above a section's contents: "Sort: Name ▾" opening a
/// three-option picker (no Manual — see OutlineFileSortOrder).
private struct OutlineFileSortRow: View {
    var rootTitle: String
    @Binding var sortOrder: OutlineFileSortOrder
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Menu {
            // Plain buttons (not a Picker) so the menu shows only the options with an
            // inline checkmark on the active one — no greyed "Sort" section header.
            ForEach(OutlineFileSortOrder.allCases) { order in
                Button {
                    sortOrder = order
                } label: {
                    if order == sortOrder {
                        Label(order.title, systemImage: "checkmark")
                    } else {
                        Text(order.title)
                    }
                }
                // Convey the active option to VoiceOver in the open menu (the checkmark
                // alone is only a visual cue).
                .accessibilityAddTraits(order == sortOrder ? [.isSelected] : [])
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                Text(OutlineSidebarView.filesSortMenuLabelPrefix + sortOrder.title)
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(OutlineSidebarView.secondaryTextColor(usesDarkChrome: colorScheme == .dark))
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("Sort \(rootTitle) files")
        .accessibilityValue(sortOrder.title)
    }
}

private struct OutlineFileTreeNodeView: View {
    var item: OutlineFileTreeItem
    var depth: Int
    @Binding var collapsedIDs: Set<String>
    var openFile: (URL) -> Void
    var currentFileURL: URL?
    // Threaded from the theme (see SidebarTabButton) rather than read from ambient colorScheme,
    // which a nested Button re-derives from the window's drift-prone effectiveAppearance — this
    // is the bulk of the Files tab, so a mis-derived value renders the whole tree near-invisible.
    var usesDarkChrome: Bool
    var renameItem: (OutlineFileTreeItem) -> Void = { _ in }
    var deleteItem: (OutlineFileTreeItem) -> Void = { _ in }
    var revealItem: (OutlineFileTreeItem) -> Void = { _ in }
    @State private var isHovered = false

    private var isCollapsed: Bool {
        collapsedIDs.contains(item.id)
    }

    private var isSelected: Bool {
        OutlineSidebarView.fileRowIsSelected(
            itemURL: item.url,
            isDirectory: item.isDirectory,
            currentFileURL: currentFileURL
        )
    }

    // A single flat row. Children are NOT rendered here — the parent flattens the visible tree
    // (see OutlineSidebarView.visibleFileRows) and renders every row in one LazyVStack, so the
    // whole tree virtualizes. This view stays responsible for its own row's chrome, indentation
    // (by `depth`), collapse toggle, selection, hover, context menu, and accessibility.
    var body: some View {
        row
    }

    private var row: some View {
        // spacing 0 with explicit per-element leading padding, so the chevron can sit in a wider,
        // right-aligned slot (nudged toward the icon, smaller glyph) without moving the icon or
        // text — the slot width + gap still sum to the default 18, pinning the icon column.
        HStack(spacing: 0) {
            Group {
                if item.isDirectory {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(rowForegroundColor)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .opacity(0)
                }
            }
            .frame(width: OutlineSidebarView.filesChevronSlotWidth, alignment: .trailing)

            Image(systemName: item.isDirectory ? "folder" : "doc.text")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(rowForegroundColor)
                .frame(width: 18)
                .padding(.leading, OutlineSidebarView.filesChevronToIconGap)

            Text(item.name)
                .font(.system(size: 13))
                .foregroundStyle(rowForegroundColor)
                .lineLimit(1)
                .padding(.leading, 8)

            Spacer(minLength: 0)
        }
        // depth starts at 1 for a root's direct children; that first level sits at the chevron
        // column (leading 0), each deeper level indents one `filesTreeIndentStep`. The chevron
        // then hangs and the icon lands on the shared icon column.
        .padding(.leading, CGFloat(depth - 1) * OutlineSidebarView.filesTreeIndentStep)
        .padding(.trailing, 6)
        .frame(maxWidth: .infinity, minHeight: OutlineSidebarView.filesChildRowHeight, maxHeight: OutlineSidebarView.filesChildRowHeight, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(rowBackgroundStyle)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if item.isDirectory {
                toggleCollapsed()
            } else {
                openFile(item.url)
            }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .contextMenu {
            rowActionButtons(ellipsized: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(OutlineSidebarView.fileRowAccessibilityLabel(name: item.name, isDirectory: item.isDirectory, isHidden: item.isHidden))
        .accessibilityHint(item.isDirectory ? (isCollapsed ? "Expands the folder" : "Collapses the folder") : "Opens the file")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
        .accessibilityAction {
            if item.isDirectory {
                toggleCollapsed()
            } else {
                openFile(item.url)
            }
        }
        // Right-click must not be the only path to these; VoiceOver users get the same
        // action set (un-ellipsized) from the actions rotor.
        .accessibilityActions {
            rowActionButtons(ellipsized: false)
        }
    }

    /// The single source of truth for a row's actions — used by both the context menu
    /// (ellipsized, matching the File menu's "..." convention) and the VoiceOver rotor,
    /// so the two can't drift apart.
    @ViewBuilder
    private func rowActionButtons(ellipsized: Bool) -> some View {
        Button(ellipsized ? "Rename..." : "Rename") { renameItem(item) }
        if !item.isDirectory {
            // No folder delete (spec): a folder's files are too much to trash from a
            // quiet sidebar menu. Files go to the Trash, behind a confirmation.
            Button(ellipsized ? "Delete..." : "Delete", role: .destructive) { deleteItem(item) }
        }
        Button("Show in Finder") { revealItem(item) }
    }

    private func toggleCollapsed() {
        if collapsedIDs.contains(item.id) {
            collapsedIDs.remove(item.id)
        } else {
            collapsedIDs.insert(item.id)
        }
    }

    /// The row fill: the modern macOS sidebar selection — a soft, translucent accent tint on the
    /// currently-shown file (like Finder/Notes source lists), a fainter text-colored tint on hover
    /// otherwise. Selection wins over hover. Folders take NO fill — they convey hover by darkening
    /// their text/icon instead (they're collapse targets, not openable rows), leaving the settled
    /// `.md` file look untouched.
    private var rowBackgroundStyle: Color {
        if isSelected {
            return Color.accentColor.opacity(OutlineSidebarView.rowSelectionFillOpacity)
        }
        if item.isDirectory {
            return Color.clear
        }
        return OutlineSidebarView.primaryTextColor(usesDarkChrome: usesDarkChrome)
            .opacity(isHovered ? OutlineSidebarView.rowHoverFillOpacity : 0)
    }

    private var rowForegroundColor: Color {
        if isSelected {
            // Accent-colored label + icon over the soft tint, matching the native sidebar look.
            return Color.accentColor
        }
        if item.isDirectory {
            // Subfolders read a step lighter than files; hovering darkens the whole row
            // (chevron + folder icon + name) toward primary, cueing that it's collapsible.
            return isHovered
                ? OutlineSidebarView.primaryTextColor(usesDarkChrome: usesDarkChrome)
                : OutlineSidebarView.secondaryTextColor(usesDarkChrome: usesDarkChrome)
        }
        return item.isHidden
            ? OutlineSidebarView.secondaryTextColor(usesDarkChrome: usesDarkChrome)
            : OutlineSidebarView.primaryTextColor(usesDarkChrome: usesDarkChrome)
    }
}

@MainActor
protocol LineformDocumentOpening: AnyObject {
    func openDocument(
        withContentsOf url: URL,
        display displayDocument: Bool,
        completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void
    )

    func noteNewRecentDocumentURL(_ url: URL)
}

extension NSDocumentController: LineformDocumentOpening {}

enum LineformSidebarFileOpener {
    @MainActor
    static func open(
        _ url: URL,
        replacing window: NSWindow?,
        updateEditorDocument: @escaping (LineformDocument) -> UUID? = { _ in nil },
        documentController: LineformDocumentOpening = NSDocumentController.shared
    ) {
        guard let window else {
            open(url, documentController: documentController)
            return
        }

        let session = LineformSidebarFileReplacementSession(
            url: url,
            window: window,
            updateEditorDocument: updateEditorDocument,
            documentController: documentController
        )
        session.begin()
    }

    @MainActor
    fileprivate static func open(
        _ url: URL,
        documentController: LineformDocumentOpening
    ) {
        documentController.openDocument(withContentsOf: url, display: true) { _, _, _ in }
    }

    @MainActor
    static func replaceCurrentDocument(
        with url: URL,
        backingDocument: NSDocument,
        window: NSWindow? = nil,
        updateEditorDocument: (LineformDocument) -> UUID?,
        documentController: LineformDocumentOpening = NSDocumentController.shared
    ) throws {
        let loadedDocument = try LineformDocument(contentsOf: url)
        let activeDocumentID = updateEditorDocument(loadedDocument) ?? loadedDocument.id

        backingDocument.fileURL = url
        backingDocument.fileType = LineformDocument.contentType(for: url).identifier
        backingDocument.fileModificationDate = LineformDocument.modificationDate(at: url)
        backingDocument.undoManager?.removeAllActions()
        backingDocument.updateChangeCount(.changeCleared)

        let targetWindow = window ?? backingDocument.windowControllers.first?.window
        targetWindow?.representedURL = url
        targetWindow?.setTitleWithRepresentedFilename(url.path)
        targetWindow?.isDocumentEdited = false
        // SwiftUI's DocumentGroup registers the binding writes made by updateEditorDocument
        // with this NSDocument's undo/change machinery asynchronously — after the
        // synchronous clears above. Without this deferred re-clear the swapped-in document
        // reads as edited though the user typed nothing, and the NEXT sidebar switch shows
        // a spurious unsaved-changes sheet for a file the user never touched.
        DispatchQueue.main.async { [weak backingDocument, weak targetWindow] in
            backingDocument?.undoManager?.removeAllActions()
            backingDocument?.updateChangeCount(.changeCleared)
            targetWindow?.isDocumentEdited = false
        }
        documentController.noteNewRecentDocumentURL(url)
        DocumentSaveStatus.shared.markSaved(
            documentID: activeDocumentID,
            at: LineformDocument.modificationDate(at: url) ?? Date(),
            text: loadedDocument.text
        )
    }
}

@MainActor
private final class LineformSidebarFileReplacementSession: NSObject {
    private let url: URL
    private weak var window: NSWindow?
    private let updateEditorDocument: (LineformDocument) -> UUID?
    private let documentController: LineformDocumentOpening
    private var retainedSession: LineformSidebarFileReplacementSession?

    init(
        url: URL,
        window: NSWindow,
        updateEditorDocument: @escaping (LineformDocument) -> UUID?,
        documentController: LineformDocumentOpening
    ) {
        self.url = url
        self.window = window
        self.updateEditorDocument = updateEditorDocument
        self.documentController = documentController
    }

    func begin() {
        retainedSession = self

        guard let document = window?.windowController?.document else {
            LineformSidebarFileOpener.open(url, documentController: documentController)
            finish()
            return
        }

        if document.fileURL?.standardizedFileURL == url.standardizedFileURL {
            finish()
            return
        }

        document.canClose(
            withDelegate: self,
            shouldClose: #selector(document(_:shouldClose:contextInfo:)),
            contextInfo: nil
        )
    }

    @objc private func document(
        _ document: NSDocument,
        shouldClose: Bool,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        guard shouldClose else {
            finish()
            return
        }

        do {
            try LineformSidebarFileOpener.replaceCurrentDocument(
                with: url,
                backingDocument: document,
                window: window,
                updateEditorDocument: updateEditorDocument,
                documentController: documentController
            )
        } catch {
            document.presentError(error)
        }

        finish()
    }

    private func finish() {
        retainedSession = nil
    }
}
