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

    /// Display name. `rawValue` stays English forever — it is identity, not copy.
    var title: String {
        switch self {
        case .outline: return String(localized: "Outline")
        case .files: return String(localized: "Files")
        case .markdownBasics: return String(localized: "Markdown Basics")
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

    static let emptyStateInstruction = String(localized: "Add # Title or ## Section to build an outline.")
    /// Matches the Markdown Basics section header exactly: size 12 medium, inactive-tab grey,
    /// same leading x (pillHorizontalInset + 10) and same y below the divider (tabDividerGap + 4).
    static let emptyStateFontSize: CGFloat = 12
    static let titleShowsIcon = false
    static let usesSubtleGradientBackground = false
    static let usesThemeIndependentLightChrome = false
    static let backgroundOpacity: Double = 0.94
    static let lightBackgroundWhiteComponent: CGFloat = 0.988
    // #313131, specified. A step BELOW the Quiet page it sits beside — which renders ≈#3F3F3F,
    // not #303030: `Theme.quiet` is `calibratedWhite: 0.19` and that space is NOT sRGB, so the
    // two numbers are not comparable as written. Under Night (≈#191919) the nav is the lighter
    // surface instead; both read as a distinct edge, which is what this is for.
    // An NSColor rather than a white scalar, and sRGB rather than `calibratedWhite`: the
    // calibrated grey space is a plain gamma-2.2 ramp, so the same number renders a visibly
    // different swatch. A hex the designer picked has to be built in the space they picked it in.
    static let darkBackgroundNSColor = NSColor(
        srgbRed: 49.0 / 255.0, green: 49.0 / 255.0, blue: 49.0 / 255.0, alpha: 1
    )
    static let primaryTextWhiteComponent: CGFloat = 0.16
    static let secondaryTextWhiteComponent: CGFloat = 0.43
    static let darkPrimaryTextWhiteComponent: CGFloat = 0.90
    static let darkSecondaryTextWhiteComponent: CGFloat = 0.68
    static let rowsShowHoverFeedback = true
    static let rowHoverFillOpacity = 0.08
    // The Files tree hovers FAINTER than the rest of the sidebar, because it is the only list
    // carrying a persistent selection fill and that fill is now a light grey: hover has to stay
    // clearly below it, or a merely-hovered row out-shouts the current file. The Outline tab has
    // no selection fill and keeps the standard strength.
    static let filesRowHoverFillOpacity = 0.045
    // Soft translucent accent tint for a selected row. The Files tree does NOT use this — it
    // takes the system unemphasized grey (see `rowSelectionFillColor`). Retained for the ⌘K
    // quick-open palette, which is a transient accent-tinted list, not a source list.
    static let rowSelectionFillOpacity = 0.15
    static let tabTitles = OutlineSidebarTab.allCases.map(\.title)
    static let tabsFillAvailableWidth = true
    static let tabsUseNativeEqualWidthSegments = true
    static let tabsUseExplicitThemeAppearance = true
    static let chooseWorkspaceButtonTitle = String(localized: "Choose")
    static let changeWorkspaceButtonTitle = String(localized: "Change")
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
        case (true, true): return String(localized: "\(name), hidden folder")
        case (true, false): return String(localized: "\(name), folder")
        case (false, true): return String(localized: "\(name), hidden")
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
    /// Explicit "open somewhere else" actions. A plain click REPLACES the document in the
    /// current tab (Apple Notes-style, the documented behaviour); these are the opt-ins —
    /// Command-click and the context menu — for the other two destinations.
    var openFileInNewTab: (URL) -> Void = { url in
        LineformSidebarFileOpener.open(url, replacing: nil)
    }
    var openFileInNewWindow: (URL) -> Void = { url in
        LineformSidebarFileOpener.open(url, replacing: nil)
    }
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
        revealItem: @escaping (OutlineFileTreeItem) -> Void = { _ in },
        openFileInNewTab: @escaping (URL) -> Void = { url in
            LineformSidebarFileOpener.open(url, replacing: nil)
        },
        openFileInNewWindow: @escaping (URL) -> Void = { url in
            LineformSidebarFileOpener.open(url, replacing: nil)
        }
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
        self.openFileInNewTab = openFileInNewTab
        self.openFileInNewWindow = openFileInNewWindow
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
        .accessibilityLabel(String(localized: "Document outline"))
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
            revealItem: revealItem,
            openFileInNewTab: openFileInNewTab,
            openFileInNewWindow: openFileInNewWindow
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
                HStack(spacing: 8) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 18, alignment: .center)

                    Text(String(localized: "Settings"))
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

    /// Dark chrome draws its background OPAQUE. The 0.94 veil lets the window behind bleed
    /// through, and what is behind differs per theme (Quiet's page is 0.19, Night's 0.09), so a
    /// translucent nav cannot land on one specified hex — it would render two different greys and
    /// neither would be #232323. Light chrome keeps its translucency.
    private var sidebarBackground: Color {
        Self.backgroundColor(usesDarkChrome: usesDarkChrome)
            .opacity(usesDarkChrome ? 1 : Self.backgroundOpacity)
    }

    private var usesDarkChrome: Bool {
        colorScheme == .dark
    }

    static func backgroundColor(usesDarkChrome: Bool) -> Color {
        if usesDarkChrome {
            return Color(nsColor: darkBackgroundNSColor)
        }
        return Color(nsColor: NSColor(calibratedWhite: lightBackgroundWhiteComponent, alpha: 1))
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

    /// The selected file row's fill. LIGHT chrome takes AppKit's unemphasized source-list
    /// selection grey — the same swatch Finder and Notes draw — resolved against the sidebar's
    /// OWN themed appearance, never the ambient one: a dynamic `NSColor` read outside
    /// `performAsCurrentDrawingAppearance` picks up the system light/dark, which is the
    /// `usesDarkChrome` threading rule stated for every other colour in this file. Deliberately
    /// grey rather than accent-tinted — accent fill under an accent label is what made the row
    /// hard to read on the dark themes.
    /// Resolved ONCE per appearance rather than per call: this is read from `rowBackgroundStyle`,
    /// which SwiftUI re-evaluates on every body pass of every visible row, and each miss would
    /// allocate an `NSAppearance` and re-resolve a dynamic colour on the main thread.
    /// The light swatch is then lifted toward the sidebar page by this fraction — a
    /// lighter, quieter grey than AppKit's, which reads heavy against this sidebar's near-white
    /// (0.988) page.
    static let rowSelectionFillLightening: CGFloat = 0.55
    /// DARK chrome does not use AppKit's grey at all: that swatch is LIGHTER than this nav, so a
    /// selected row glowed. It recesses instead — a well cut into the nav, darker than both the
    /// nav and the hover fill. That also puts the blue label at ~4.3:1 here, against 2.8:1 on the
    /// grey it replaces. Light chrome is UNCHANGED by this.
    /// #282828 — neutral, like the nav, and sRGB for the same reason.
    static let darkRowSelectionFillWhiteComponent: CGFloat = 40.0 / 255.0
    static func rowSelectionFillNSColor(usesDarkChrome: Bool) -> NSColor {
        if let cached = cachedRowSelectionFill[usesDarkChrome] { return cached }
        if usesDarkChrome {
            let recessed = NSColor(
                srgbRed: darkRowSelectionFillWhiteComponent,
                green: darkRowSelectionFillWhiteComponent,
                blue: darkRowSelectionFillWhiteComponent,
                alpha: 1
            )
            cachedRowSelectionFill[true] = recessed
            return recessed
        }
        var resolved = NSColor.unemphasizedSelectedContentBackgroundColor
        NSAppearance(named: tabAppearanceName(usesDarkChrome: usesDarkChrome))?
            .performAsCurrentDrawingAppearance {
                resolved = NSColor.unemphasizedSelectedContentBackgroundColor
                    .usingColorSpace(.sRGB) ?? resolved
            }
        if !usesDarkChrome {
            let page = NSColor(calibratedWhite: lightBackgroundWhiteComponent, alpha: 1)
                .usingColorSpace(.sRGB) ?? .white
            resolved = resolved.blended(withFraction: rowSelectionFillLightening, of: page)
                ?? resolved
        }
        cachedRowSelectionFill[usesDarkChrome] = resolved
        return resolved
    }

    static func rowSelectionFillColor(usesDarkChrome: Bool) -> Color {
        Color(nsColor: rowSelectionFillNSColor(usesDarkChrome: usesDarkChrome))
    }

    /// The selected file row's label and icon: the system blue Finder draws over that same grey.
    /// `systemBlue` rather than `controlAccentColor` — this is specified as *blue*, so it must not
    /// follow a pink or graphite accent setting. Dynamic like the fill, so it is resolved against
    /// the sidebar's OWN appearance (the light and dark system blues differ) and memoized per
    /// appearance for the same reason: this is read on every body pass of every visible row.
    static func rowSelectionLabelNSColor(usesDarkChrome: Bool) -> NSColor {
        if let cached = cachedRowSelectionLabel[usesDarkChrome] { return cached }
        var resolved = NSColor.systemBlue
        NSAppearance(named: tabAppearanceName(usesDarkChrome: usesDarkChrome))?
            .performAsCurrentDrawingAppearance {
                resolved = NSColor.systemBlue.usingColorSpace(.sRGB) ?? resolved
            }
        cachedRowSelectionLabel[usesDarkChrome] = resolved
        return resolved
    }

    static func rowSelectionLabelColor(usesDarkChrome: Bool) -> Color {
        Color(nsColor: rowSelectionLabelNSColor(usesDarkChrome: usesDarkChrome))
    }

    /// Main-thread only (SwiftUI body evaluation and the tests that mirror it), which is what
    /// makes these unsynchronised dictionaries safe.
    @MainActor private static var cachedRowSelectionFill: [Bool: NSColor] = [:]
    @MainActor private static var cachedRowSelectionLabel: [Bool: NSColor] = [:]

    /// `~`-relative, and clipped from the LEFT when long so the tail — the part that actually
    /// distinguishes `Test Folder` from `Test Folder/Test Folder` — always survives.
    /// Static so it is unit-testable without building a view.
    static func abbreviatedWorkspacePath(
        _ path: String,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        limit: Int = 44
    ) -> String {
        // Match the home directory only on a COMPONENT boundary. A bare `hasPrefix` abbreviates
        // `/Users/carlostarrats/x` against a home of `/Users/carlos` into `~tarrats/x` — a path
        // that never existed, in the one message whose whole job is to name the real folder.
        var display = path
        if path == homeDirectory {
            display = "~"
        } else if path.hasPrefix(homeDirectory + "/") {
            display = "~" + path.dropFirst(homeDirectory.count)
        }
        if display.count > limit {
            display = "…" + display.suffix(limit)
        }
        return display
    }

    // MARK: - Unified leading geometry

    /// The single icon column every section aligns to (icon left edge, measured from the
    /// sidebar's content edge). Disclosure chevrons hang in the reserved slot to the LEFT of
    /// this column (the Finder/Xcode source-list convention), so tab icons, Settings, outline
    /// rows, the Files sort row, root icons, and file/folder icons all share one vertical line.
    static let sidebarIconColumnLeading: CGFloat = 22
    /// Disclosure chevron (Files tree AND root headers): a small glyph right-aligned in this slot
    /// with `filesChevronToIconGap` to the icon, so the chevron sits close to the folder/doc icon
    /// it discloses. Slot + gap = 16 = the icon column's offset from the content edge, so the icon
    /// column is unchanged whether or not a chevron is drawn.
    /// Command-click on a file row opens it in a NEW TAB instead of replacing the current one —
    /// the browser/Finder convention. Static and flag-taking so it is testable without an event.
    /// Option and Control are excluded deliberately: Option-click is a system drag-copy modifier
    /// and Control-click IS the context menu, which must not also open a tab behind the menu.
    static func opensInNewTab(modifiers: NSEvent.ModifierFlags) -> Bool {
        modifiers.contains(.command) && !modifiers.contains(.control) && !modifiers.contains(.option)
    }
    static let filesChevronSlotWidth: CGFloat = 12
    static let filesChevronToIconGap: CGFloat = 4
    /// Horizontal inset of the tab-picker / Settings / outline pills from the sidebar edge.
    /// The pill's own internal leading padding then carries the icon to `sidebarIconColumnLeading`.
    static let pillHorizontalInset: CGFloat = 14
    static let pillInnerLeading: CGFloat = 8
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
            HStack(spacing: 6) {
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
            // Icon rides the shared column: pill inner leading (8) + depth indent, inside the
            // outline content's 14pt inset, lands the icon at `sidebarIconColumnLeading` (22).
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
        .accessibilityLabel(String(localized: "Jump to heading \(node.item.title)"))
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
            HStack(spacing: 8) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18, alignment: .center)

                Text(tab.title)
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
        title: String(localized: "Workspace"),
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
                // Toggling OFF re-scans live roots so the backing snapshot and the display stay
                // in sync. Cached/disconnected fallbacks still filter in memory because no live
                // scan is possible there.
                refreshICloudRoot()
                refreshWorkspaceRoot()
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

    /// A sort change re-scans a live root so its snapshot, dates, and directory contents are
    /// refreshed together. Only cached/disconnected trees fall back to an in-memory re-sort.
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
    /// Readable so the sidebar can show WHICH folder it is scanning; writes stay internal to the
    /// store because every one of them must also retarget the FSEvents watcher.
    private(set) var workspaceURL: URL?
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
        // One global Sort row now drives both roots, so the two persisted keys must agree. They
        // could disagree only on a profile carried over from 1.2.0, which had a separate row per
        // section: the row reads the iCloud key while the workspace tree is SCANNED with the
        // workspace key, so the label described an order the files were not in. Reconcile once
        // at load, preferring the workspace value: a user with no iCloud
        // root visible could only ever have set that one.
        //
        // Assigned through the `Published(initialValue:)` backing storage, never by plain
        // assignment — a plain assignment here fires the didSet observers, and theirs run the
        // init-forbidden iCloud scan.
        let storedICloudSort = OutlineFileSortOrder(rawValue: defaults.string(forKey: Self.iCloudSortOrderDefaultsKey) ?? "")
        let storedWorkspaceSort = OutlineFileSortOrder(rawValue: defaults.string(forKey: Self.workspaceSortOrderDefaultsKey) ?? "")
        let sortOrder = storedWorkspaceSort ?? storedICloudSort ?? .name
        if storedICloudSort != storedWorkspaceSort {
            defaults.set(sortOrder.rawValue, forKey: Self.iCloudSortOrderDefaultsKey)
            defaults.set(sortOrder.rawValue, forKey: Self.workspaceSortOrderDefaultsKey)
        }
        _iCloudSortOrder = Published(initialValue: sortOrder)
        _workspaceSortOrder = Published(initialValue: sortOrder)
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
        let panel = folderSelectionPanel(prompt: String(localized: "Choose"))

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

    /// Tears down the workspace FSEvents stream so the next `beginWatchingForExternalChanges`
    /// creates one on the CURRENT `workspaceURL`.
    ///
    /// Every write to `workspaceURL` must call this. `DirectoryEventMonitor` binds the stream to a
    /// path string and does not set `kFSEventStreamCreateFlagWatchRoot`, so a stream on a moved or
    /// renamed folder is silently dead — the tab keeps looking correct while it stops refreshing.
    private func retargetWorkspaceWatcher() {
        workspaceMonitor?.stop()
        workspaceMonitor = nil
        // Drop any debounced rescan queued against the old monitor; the caller re-scans directly,
        // so a late fire would only be redundant work.
        pendingWorkspaceRescan?.cancel()
        pendingWorkspaceRescan = nil
    }

    private func setWorkspaceURL(_ url: URL) {
        // Retarget a live watcher at the newly chosen folder (stop now, restart after the
        // refresh below re-resolves everything). Keyed off isWatchingForExternalChanges,
        // not monitor existence — a first-ever workspace choice has no monitor yet but
        // still needs one if the Files tab is watching.
        retargetWorkspaceWatcher()

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
        url?.lastPathComponent ?? String(localized: "Workspace")
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
            // The bookmark followed the folder to a new path, so the FSEvents stream — created
            // with the OLD path string and no `kFSEventStreamCreateFlagWatchRoot` — is now dead
            // and will never fire again. Every `workspaceURL` write must retarget the watcher;
            // `setWorkspaceURL` did and this path did not, so renaming the workspace in Finder
            // killed live refresh for the rest of the session while the tree still looked right.
            retargetWorkspaceWatcher()
            refreshWorkspaceRoot()
            if isWatchingForExternalChanges {
                beginWatchingForExternalChanges()
            }
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
    /// hiding a root the sidebar could visibly render files under. It inspects one
    /// child-folder level, matching the document-only sidebar definition without
    /// walking a whole large iCloud tree. Read-only; never writes.
    static func documentsFolderIsEmpty(at url: URL, fileManager: FileManager) -> Bool {
        items(
            in: url,
            fileManager: fileManager,
            depth: maximumTreeDepth - 2,
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

        // Resolve and sort each child's shallow attributes first (children left empty — no
        // recursion yet). Empty directories are removed before the tree is published, so they
        // cannot obscure document-bearing folders.
        // A directory is kept only when its scanned subtree contains a supported document;
        // folders that contain only images, build artifacts, or nothing are not useful in a
        // document-only browser.
        let candidates = urls.compactMap { childURL -> OutlineFileTreeItem? in
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

        var visible: [OutlineFileTreeItem] = []
        visible.reserveCapacity(candidates.count)
        for item in candidates {
            guard item.isDirectory else {
                visible.append(item)
                continue
            }

            var populated = item
            populated.children = items(
                in: item.url,
                fileManager: fileManager,
                depth: depth + 1,
                showsHiddenFolders: showsHiddenFolders,
                inheritedHidden: item.isHidden,
                sortOrder: sortOrder
            )
            if !populated.children.isEmpty {
                visible.append(populated)
            }
        }
        return visible
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
    var openFileInNewTab: (URL) -> Void = { _ in }
    var openFileInNewWindow: (URL) -> Void = { _ in }
    @State private var collapsedIDs: Set<String> = []
    @State private var isSortHovered = false

    var body: some View {
        // "Show Hidden Folders" now lives in the View menu (⌘⇧.), so the Files tab is just
        // the file tree — no in-sidebar toggle chrome.
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                globalSortRow

                if iCloudRootIsVisible {
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
            Picker(String(localized: "Sort folders by"), selection: globalSortOrder) {
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
                Text(String(localized: "Sort folders by: \(globalSortOrder.wrappedValue.title)"))
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
        .accessibilityLabel(String(localized: "Sort folders by"))
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

    /// The real folder a root is scanning, for the disambiguating path shown on the row and in
    /// the empty state. Only the workspace root has a user-chosen (and therefore ambiguous)
    /// location; the iCloud root is a fixed app container, so it has nothing to disambiguate.
    private func rootPath(for root: OutlineFileRoot) -> URL? {
        root.id == "workspace" ? store.workspaceURL : nil
    }

    @ViewBuilder
    private func rootView(_ root: OutlineFileRoot) -> some View {
        // Whether root collapsing is allowed only decides if a chevron is drawn; the chevron
        // slot is ALWAYS reserved so root/file/folder icons stay pinned to the shared icon
        // column whether or not a chevron is visible (no left-shift on lock).
        let usesMinimalWorkspaceChrome = root.id == "workspace" && !iCloudRootIsVisible
        // A lone workspace is the Files tab's fixed context, so it stays expanded with no
        // disclosure affordance. When iCloud is visible, both roots honor the collapse setting.
        let lockExpanded = self.lockExpanded || usesMinimalWorkspaceChrome

        VStack(alignment: .leading, spacing: 2) {
            OutlineFileRootRow(
                root: root,
                isCollapsed: isRootCollapsed(root.id, lockExpanded: lockExpanded),
                lockExpanded: lockExpanded,
                usesMinimalWorkspaceChrome: usesMinimalWorkspaceChrome,
                usesDarkChrome: usesDarkChrome,
                toggleCollapsed: { toggle(root.id) },
                chooseWorkspaceFolder: store.chooseWorkspaceFolder
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            // The row prints only the folder's LAST path component, so two folders of the same
            // name — including a folder nested inside its own namesake — are indistinguishable.
            // NSOpenPanel's `url` is the SELECTED row, not the directory on screen, so expanding
            // a subfolder's disclosure triangle and pressing Choose silently targets that
            // subfolder. Surface the full path so the sidebar can't misrepresent which folder is
            // actually the workspace.
            .help(rootPath(for: root).map { String(localized: "Workspace: \($0.path)") } ?? root.title)

            // A dimmed iCloud root (unavailable or connected-but-empty) reads as inactive: no
            // expandable tree, no empty-state line — just the quiet header.
            if root.showsTree, !isRootCollapsed(root.id, lockExpanded: lockExpanded), !rootIsDimmed(root) {
                if root.items.isEmpty {
                    // Only a connected (.available) empty folder is genuinely "no Markdown." A
                    // disconnected folder's emptiness just means the cached snapshot is empty — the
                    // header's disconnected icon already signals that, so don't claim it's empty.
                    if root.state == .available {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(localized: "No Markdown files"))
                            // "No Markdown files" under a name that matches the folder the user
                            // believes they picked reads as a scan failure. Naming the scanned
                            // path is the only thing that distinguishes "this folder is empty"
                            // from "you are looking at a different folder than you think".
                            if let path = rootPath(for: root)?.path {
                                Text(OutlineSidebarView.abbreviatedWorkspacePath(path))
                                    .font(.system(size: 11))
                                    .textSelection(.enabled)
                                    .help(path)
                                    // The visible string is elided from the left; announcing
                                    // "…older/Test Folder" would strand a VoiceOver user with
                                    // exactly the ambiguity this line exists to resolve.
                                    .accessibilityLabel(String(localized: "Scanned folder: \(path)"))
                            }
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(OutlineSidebarView.secondaryTextColor(usesDarkChrome: usesDarkChrome))
                        .padding(.leading, OutlineSidebarView.sidebarIconColumnLeading - OutlineSidebarView.filesContentHorizontalPadding)
                        .padding(.trailing, 8)
                        .padding(.vertical, 4)
                    }
                } else {
                    // Render the tree from a FLATTENED list of visible rows in a LazyVStack, so a
                    // large fully-expanded workspace only lays out the rows in the viewport. The
                    // old recursive non-lazy VStacks laid out every row at once (~3,840 on a big
                    // workspace), which froze typing/file-switching (Task 5's real cause). Direct
                    // children start at depth 1 so they indent one step past the root's icon.
                    let rows = OutlineSidebarView.visibleFileRows(root.items, collapsedIDs: collapsedIDs)
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(rows) { flatRow in
                            OutlineFileTreeNodeView(
                                item: flatRow.item,
                                depth: flatRow.depth,
                                collapsedIDs: $collapsedIDs,
                                openFile: openFile,
                                currentFileURL: currentFileURL,
                                usesDarkChrome: usesDarkChrome,
                                renameItem: renameItem,
                                deleteItem: deleteItem,
                                revealItem: revealItem,
                                openFileInNewTab: openFileInNewTab,
                                openFileInNewWindow: openFileInNewWindow
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

    private var iCloudRootIsVisible: Bool {
        OutlineSidebarView.iCloudRootVisible(
            state: store.iCloudRoot.state,
            showICloudInSidebar: settings.showICloudInSidebar
        )
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
    /// A lone workspace is already the Files tab's context, so it needs no hierarchy chrome. Its
    /// desktop glyph distinguishes the user-selected workspace from a folder in the file tree.
    var usesMinimalWorkspaceChrome = false
    // Threaded from the theme (see SidebarTabButton) rather than read from ambient colorScheme,
    // which a nested Button re-derives from the window's drift-prone effectiveAppearance.
    var usesDarkChrome: Bool
    var toggleCollapsed: () -> Void
    var chooseWorkspaceFolder: () -> Void
    @State private var isWorkspaceActionHovered = false

    var body: some View {
        HStack(spacing: 8) {
            // An expandable root uses a chevron; a non-expandable header renders as plain views
            // so VoiceOver doesn't announce an "Expand/Collapse" affordance it can't honor.
            if usesMinimalWorkspaceChrome {
                rootLeadingContent(showsChevron: false)
            } else if showsDisclosure {
                Button(action: toggleCollapsed) {
                    rootLeadingContent(showsChevron: true)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isCollapsed
                    ? String(localized: "Expand \(root.title)")
                    : String(localized: "Collapse \(root.title)"))
            } else {
                // The chevron slot is ALWAYS reserved (even when collapse is locked off) so the
                // root icon stays pinned to the shared icon column, aligned with the file/folder
                // icons below it.
                rootLeadingContent(showsChevron: false)
            }

            Spacer(minLength: 0)

            if root.id == "workspace", root.state != .unavailable {
                if root.state == .disconnected {
                    // The only signal that the workspace folder is gone is this glyph's shape, so
                    // it carries a label rather than being decorative — an unlabelled icon is the
                    // state simply not existing for a VoiceOver user.
                    Image(systemName: OutlineSidebarView.workspaceDisconnectedSystemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(OutlineSidebarView.secondaryTextColor(usesDarkChrome: usesDarkChrome))
                        .accessibilityLabel(String(localized: "Workspace folder unavailable"))
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
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(OutlineSidebarView.secondaryTextColor(usesDarkChrome: usesDarkChrome))
                .frame(width: 18, alignment: .center)
                .opacity(root.state == .disconnected ? 0.48 : 1)
                .accessibilityHidden(true)
        } else if root.id == "workspace", root.state != .unavailable {
            // This denotes the selected workspace rather than a folder in its file tree.
            Image(systemName: "tray.full")
                .font(.system(size: 13, weight: .medium))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(OutlineSidebarView.primaryTextColor(usesDarkChrome: usesDarkChrome))
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
    var openFileInNewTab: (URL) -> Void = { _ in }
    var openFileInNewWindow: (URL) -> Void = { _ in }
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
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(rowForegroundColor)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .opacity(0)
                }
            }
            .frame(width: OutlineSidebarView.filesChevronSlotWidth, alignment: .trailing)

            Image(systemName: item.isDirectory ? "folder" : "doc.text")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(rowForegroundColor)
                .frame(width: 18)
                .padding(.leading, 2)

            Text(item.name)
                // Selected rows carry weight as well as colour, matching the sidebar's tab
                // buttons — so selection survives being read at a glance, on a grey-only
                // screenshot, or by anyone who can't separate the blue from the fill.
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(rowForegroundColor)
                .lineLimit(1)
                .padding(.leading, 4)

            Spacer(minLength: 0)
        }
        // depth starts at 1 for a root's direct children; the whole child tree begins 14pt past
        // the root chrome, and each deeper level indents one `filesTreeIndentStep` from there.
        .padding(.leading, 14 + CGFloat(depth - 1) * OutlineSidebarView.filesTreeIndentStep)
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
            } else if OutlineSidebarView.opensInNewTab(modifiers: NSEvent.modifierFlags) {
                openFileInNewTab(item.url)
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
        .accessibilityHint(item.isDirectory
            ? (isCollapsed ? String(localized: "Expands the folder") : String(localized: "Collapses the folder"))
            : String(localized: "Opens the file"))
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
        // Icons on every row, not just the new ones: a menu with some items iconed and some
        // not reads as broken, and this menu is the only place the two "open elsewhere"
        // destinations exist besides Command-click.
        if !item.isDirectory {
            Button {
                openFileInNewTab(item.url)
            } label: {
                Label(String(localized: "Open in New Tab"), systemImage: "plus.rectangle.on.rectangle")
            }
            Button {
                openFileInNewWindow(item.url)
            } label: {
                Label(String(localized: "Open in New Window"), systemImage: "macwindow.badge.plus")
            }
            Divider()
        }
        Button {
            renameItem(item)
        } label: {
            Label(ellipsized ? String(localized: "Rename...") : String(localized: "Rename"), systemImage: "pencil")
        }
        if !item.isDirectory {
            // No folder delete (spec): a folder's files are too much to trash from a
            // quiet sidebar menu. Files go to the Trash, behind a confirmation.
            Button(role: .destructive) {
                deleteItem(item)
            } label: {
                Label(ellipsized ? String(localized: "Delete...") : String(localized: "Delete"), systemImage: "trash")
            }
        }
        Button {
            revealItem(item)
        } label: {
            Label(String(localized: "Show in Finder"), systemImage: "folder")
        }
    }

    private func toggleCollapsed() {
        if collapsedIDs.contains(item.id) {
            collapsedIDs.remove(item.id)
        } else {
            collapsedIDs.insert(item.id)
        }
    }

    /// The row fill: the macOS sidebar selection — the system unemphasized selection grey on the
    /// currently-shown file (like Finder/Notes source lists), a fainter text-colored tint on hover
    /// otherwise. Selection wins over hover. Folders take NO fill — they convey hover by darkening
    /// their text/icon instead (they're collapse targets, not openable rows), leaving the settled
    /// `.md` file look untouched.
    private var rowBackgroundStyle: Color {
        if isSelected {
            return OutlineSidebarView.rowSelectionFillColor(usesDarkChrome: usesDarkChrome)
        }
        if item.isDirectory {
            return Color.clear
        }
        return OutlineSidebarView.primaryTextColor(usesDarkChrome: usesDarkChrome)
            .opacity(isHovered ? OutlineSidebarView.filesRowHoverFillOpacity : 0)
    }

    private var rowForegroundColor: Color {
        if isSelected {
            // Blue label + icon over the grey fill: the pairing Finder's sidebar draws for the
            // selected row. It is the specified look, and it is BELOW WCAG AA (~2.9:1 light,
            // ~2.8:1 dark) — acceptable here only because selection is also carried by the fill,
            // so no information depends on reading the blue. Do not copy this pairing into
            // document ink, which goes through `Theme.readableInk`.
            return OutlineSidebarView.rowSelectionLabelColor(usesDarkChrome: usesDarkChrome)
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
