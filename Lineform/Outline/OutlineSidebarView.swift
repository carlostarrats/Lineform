import AppKit
import SwiftUI

enum OutlineSidebarTab: String, CaseIterable, Identifiable {
    case outline = "Outline"
    case files = "Files"

    var id: Self { self }
}

struct OutlineFileTreeItem: Identifiable, Equatable, Codable {
    var url: URL
    var name: String
    var isDirectory: Bool
    var children: [OutlineFileTreeItem]
    var isHidden: Bool = false

    var id: String { url.path }

    init(url: URL, name: String, isDirectory: Bool, children: [OutlineFileTreeItem], isHidden: Bool = false) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.children = children
        self.isHidden = isHidden
    }

    private enum CodingKeys: String, CodingKey {
        case url, name, isDirectory, children, isHidden
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decode(URL.self, forKey: .url)
        name = try container.decode(String.self, forKey: .name)
        isDirectory = try container.decode(Bool.self, forKey: .isDirectory)
        children = try container.decode([OutlineFileTreeItem].self, forKey: .children)
        // Tolerate snapshots written before isHidden existed (they only held visible items).
        isHidden = try container.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
    }
}

struct OutlineSidebarView: View {
    struct OutlineNode: Identifiable, Equatable {
        var item: MarkdownOutlineItem
        var children: [OutlineNode]

        var id: String { item.id }
    }

    static let emptyStateTitle = "No headings yet"
    static let emptyStatePossibilityMessage = "No sections. No hierarchy. Just possibilities."
    static let emptyStateInstruction = "Add # Title or ## Section to build an outline."
    static let emptyStateTopPadding: CGFloat = 10
    static let emptyStateHorizontalPadding: CGFloat = 16
    static let emptyStateTitleBodySpacing: CGFloat = 7
    static let emptyStateMessageInstructionSpacing: CGFloat = 24
    static let emptyStateTitleFontSize: CGFloat = 13
    static let emptyStateBodyFontSize: CGFloat = 12
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
    static let filesContentHorizontalPadding: CGFloat = 10
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

    /// Per-level horizontal indent for Files-tab tree rows. Kept gentle because the vertical
    /// guide line (one per open folder) carries most of the "this is nested" signal.
    static let filesTreeIndentStep: CGFloat = 12
    /// x of the guide line for a depth-0 parent's children: row-content leading (6) + chevron (10)
    /// + gap (8) + half icon (9) = the parent icon's horizontal center. Deeper parents shift by one step.
    static let filesGuideLineDepthZeroInset: CGFloat = 33

    static func filesGuideLineInset(forParentDepth depth: Int) -> CGFloat {
        filesGuideLineDepthZeroInset + CGFloat(depth) * filesTreeIndentStep
    }

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
    static let minimumColumnWidth: CGFloat = 220
    static let idealColumnWidth: CGFloat = 260
    static let maximumColumnWidth: CGFloat = 300

    @Environment(\.colorScheme) private var colorScheme
    @State private var collapsedNodeIDs: Set<String> = []
    @State private var selectedTab = OutlineSidebarTab.outline
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
    var jumpToHeading: (MarkdownOutlineItem) -> Void
    var openFile: (URL) -> Void = { url in
        LineformSidebarFileOpener.open(url, replacing: nil)
    }
    /// The file currently shown in this window, so its Files-tab row can render the native
    /// selection highlight. `nil` for untitled documents (no on-disk URL to match).
    var currentFileURL: URL?

    init(
        items: [MarkdownOutlineItem],
        jumpToHeading: @escaping (MarkdownOutlineItem) -> Void,
        openFile: @escaping (URL) -> Void = { url in
            LineformSidebarFileOpener.open(url, replacing: nil)
        },
        currentFileURL: URL? = nil,
        fileBrowserStore: OutlineFileBrowserStore? = nil
    ) {
        self.items = items
        self.jumpToHeading = jumpToHeading
        self.openFile = openFile
        self.currentFileURL = currentFileURL
        // Production passes nil → a real store is created lazily on first render. Tests inject
        // a store on an isolated defaults suite so they never resolve the user's real workspace
        // bookmark (which would touch ~/Documents and prompt for access).
        _fileBrowserStore = StateObject(wrappedValue: fileBrowserStore ?? OutlineFileBrowserStore())
    }

    var body: some View {
        ZStack {
            sidebarBackground
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                tabPicker

                if selectedTab == .outline {
                    outlineContent
                } else {
                    OutlineFileBrowserView(store: fileBrowserStore, openFile: openFile, currentFileURL: currentFileURL)
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
                            if !turnedOn {
                                fileBrowserStore.refreshICloud()
                            }
                        }
                        .onReceive(NotificationCenter.default.publisher(for: LineformAppNotification.toggleHiddenFolders.name)) { _ in
                            // Live update while the Files tab is visible (its iCloud container is
                            // already resolved, so the store's re-scan matches the old in-sidebar
                            // toggle's cost). Windows on the Outline tab or with the sidebar collapsed
                            // don't observe this, preserving the deferred-scan invariant; they
                            // reconcile via .onAppear when the Files tab next appears.
                            fileBrowserStore.showsHiddenFolders = HiddenFoldersMenuState.shared.isOn
                        }
                }
            }
        }
        .frame(minWidth: Self.minimumColumnWidth, idealWidth: Self.idealColumnWidth, maxWidth: Self.maximumColumnWidth)
        .accessibilityLabel("Document outline")
    }

    private var tabPicker: some View {
        OutlineSidebarSegmentedControl(selection: $selectedTab)
        .frame(maxWidth: .infinity)
        .frame(height: 32)
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var outlineContent: some View {
        if items.isEmpty {
            VStack(alignment: .leading, spacing: Self.emptyStateTitleBodySpacing) {
                Text(Self.emptyStateTitle)
                    .font(.system(size: Self.emptyStateTitleFontSize, weight: .semibold))
                    .foregroundStyle(Self.primaryTextColor(usesDarkChrome: usesDarkChrome))

                VStack(alignment: .leading, spacing: Self.emptyStateMessageInstructionSpacing) {
                    Text(Self.emptyStatePossibilityMessage)
                        .foregroundStyle(Self.primaryTextColor(usesDarkChrome: usesDarkChrome))

                    Text(Self.emptyStateInstruction)
                        .foregroundStyle(Self.secondaryTextColor(usesDarkChrome: usesDarkChrome))
                }
                .font(.system(size: Self.emptyStateBodyFontSize))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Self.emptyStateHorizontalPadding)
            .padding(.top, Self.emptyStateTopPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Self.outlineTree(from: items)) { node in
                        OutlineSidebarNodeView(
                            node: node,
                            depth: 0,
                            collapsedNodeIDs: $collapsedNodeIDs,
                            jumpToHeading: jumpToHeading
                        )
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 4)
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

    fileprivate static func primaryTextColor(usesDarkChrome: Bool) -> Color {
        Color(nsColor: NSColor(
            calibratedWhite: usesDarkChrome ? darkPrimaryTextWhiteComponent : primaryTextWhiteComponent,
            alpha: 1
        ))
    }

    fileprivate static func secondaryTextColor(usesDarkChrome: Bool) -> Color {
        Color(nsColor: NSColor(
            calibratedWhite: usesDarkChrome ? darkSecondaryTextWhiteComponent : secondaryTextWhiteComponent,
            alpha: 1
        ))
    }
}

private struct OutlineSidebarNodeView: View {
    var node: OutlineSidebarView.OutlineNode
    var depth: Int
    @Binding var collapsedNodeIDs: Set<String>
    var jumpToHeading: (MarkdownOutlineItem) -> Void

    private var isCollapsed: Bool {
        collapsedNodeIDs.contains(node.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            OutlineSidebarRow(
                node: node,
                depth: depth,
                isCollapsed: isCollapsed,
                toggleCollapsed: toggleCollapsed,
                jumpToHeading: jumpToHeading
            )

            if !isCollapsed {
                ForEach(node.children) { child in
                    OutlineSidebarNodeView(
                        node: child,
                        depth: depth + 1,
                        collapsedNodeIDs: $collapsedNodeIDs,
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
    var isCollapsed: Bool
    var toggleCollapsed: () -> Void
    var jumpToHeading: (MarkdownOutlineItem) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            if node.children.isEmpty {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .opacity(0)
                    .frame(width: 10)
            } else {
                Button(action: toggleCollapsed) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(OutlineSidebarView.secondaryTextColor(usesDarkChrome: usesDarkChrome))
                        .frame(width: 10)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isCollapsed ? "Expand \(node.item.title)" : "Collapse \(node.item.title)")
            }

            Button {
                jumpToHeading(node.item)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: OutlineSidebarView.iconName(forHeadingLevel: node.item.level))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(OutlineSidebarView.primaryTextColor(usesDarkChrome: usesDarkChrome))
                        .frame(width: 18)

                    Text(node.item.title)
                        .font(.system(size: 13, weight: node.item.level == 1 ? .medium : .regular))
                        .foregroundStyle(OutlineSidebarView.primaryTextColor(usesDarkChrome: usesDarkChrome))
                        .lineLimit(1)

                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Jump to heading \(node.item.title)")

            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(depth) * 14)
        .padding(.horizontal, 6)
        .frame(height: 26)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(OutlineSidebarView.primaryTextColor(usesDarkChrome: usesDarkChrome).opacity(isHovered ? OutlineSidebarView.rowHoverFillOpacity : 0))
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }

    private var usesDarkChrome: Bool {
        colorScheme == .dark
    }
}

private struct OutlineSidebarSegmentedControl: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var selection: OutlineSidebarTab

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: OutlineSidebarView.tabTitles, trackingMode: .selectOne, target: context.coordinator, action: #selector(Coordinator.selectionChanged(_:)))
        control.segmentStyle = .rounded
        control.segmentDistribution = .fillEqually
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        control.selectedSegment = selectedSegmentIndex
        control.appearance = appearance
        return control
    }

    func updateNSView(_ nsView: NSSegmentedControl, context: Context) {
        nsView.selectedSegment = selectedSegmentIndex
        nsView.appearance = appearance
        nsView.segmentDistribution = .fillEqually
        nsView.setWidth(0, forSegment: 0)
        nsView.setWidth(0, forSegment: 1)
        nsView.needsDisplay = true
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    private var selectedSegmentIndex: Int {
        OutlineSidebarTab.allCases.firstIndex(of: selection) ?? 0
    }

    private var appearance: NSAppearance? {
        NSAppearance(named: OutlineSidebarView.tabAppearanceName(usesDarkChrome: colorScheme == .dark))
    }

    final class Coordinator: NSObject {
        @Binding var selection: OutlineSidebarTab

        init(selection: Binding<OutlineSidebarTab>) {
            _selection = selection
        }

        @MainActor
        @objc func selectionChanged(_ sender: NSSegmentedControl) {
            guard OutlineSidebarTab.allCases.indices.contains(sender.selectedSegment) else {
                return
            }

            selection = OutlineSidebarTab.allCases[sender.selectedSegment]
        }
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
    static let maximumTreeDepth = 4
    static let maximumChildrenPerFolder = 80
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

    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let iCloudDocumentsURLProvider: (FileManager) -> URL?
    private let iCloudDownloader: UbiquitousItemDownloader
    private var lastICloudItems: [OutlineFileTreeItem] = []
    private var workspaceURL: URL?
    private var lastWorkspaceItems: [OutlineFileTreeItem] = []

    init(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        iCloudDocumentsURLProvider: @escaping (FileManager) -> URL? = OutlineFileBrowserStore.lineformICloudDocumentsURL,
        iCloudDownloader: UbiquitousItemDownloader? = nil
    ) {
        self.defaults = defaults
        self.fileManager = fileManager
        self.iCloudDocumentsURLProvider = iCloudDocumentsURLProvider
        self.iCloudDownloader = iCloudDownloader ?? fileManager
        // Set before any refresh; `didSet` does not fire during initialization, so this does
        // not trigger an (init-forbidden) iCloud scan.
        showsHiddenFolders = defaults.bool(forKey: Self.showsHiddenFoldersDefaultsKey)
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
        refreshICloudRoot()
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

            return url
        } catch {
            return nil
        }
    }

    private func loadICloudSnapshot() {
        lastICloudItems = loadSnapshot(defaultsKey: Self.iCloudSnapshotDefaultsKey)
    }

    private func loadWorkspaceSnapshot() {
        lastWorkspaceItems = loadSnapshot(defaultsKey: Self.workspaceSnapshotDefaultsKey)
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
        workspaceURL = url
        saveBookmark(for: url, defaultsKey: Self.workspaceBookmarkDefaultsKey)
        refreshWorkspaceRoot()
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

    private func refreshICloudRoot() {
        guard let url = iCloudDocumentsURLProvider(fileManager) else {
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
            iCloudRoot = OutlineFileRoot(
                id: "icloud",
                title: "Lineform",
                systemImage: "icloud",
                state: .unavailable,
                items: []
            )
            return
        }

        let items = Self.items(in: url, fileManager: fileManager, showsHiddenFolders: showsHiddenFolders)
        lastICloudItems = items
        saveSnapshot(items, defaultsKey: Self.iCloudSnapshotDefaultsKey)

        // Keep the user's iCloud working set materialized locally. Evicted
        // (dataless) files otherwise show in search but fail to open or drag,
        // which is one of the failure modes that made files feel "lost."
        Self.ensureDownloaded(items, using: iCloudDownloader)

        iCloudRoot = OutlineFileRoot(
            id: "icloud",
            title: "Lineform",
            systemImage: "icloud",
            state: .available,
            items: items
        )
    }

    /// The workspace root's display title: the chosen folder's name, or "Workspace" when unassigned.
    static func workspaceTitle(for url: URL?) -> String {
        url?.lastPathComponent ?? "Workspace"
    }

    private func refreshWorkspaceRoot() {
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

        let didAccess = workspaceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                workspaceURL.stopAccessingSecurityScopedResource()
            }
        }

        let items = Self.items(in: workspaceURL, fileManager: fileManager, showsHiddenFolders: showsHiddenFolders)
        lastWorkspaceItems = items
        saveSnapshot(items, defaultsKey: Self.workspaceSnapshotDefaultsKey)

        workspaceRoot = OutlineFileRoot(
            id: "workspace",
            title: Self.workspaceTitle(for: workspaceURL),
            systemImage: "folder",
            state: .available,
            items: items
        )
    }

    private static func lineformICloudDocumentsURL(fileManager: FileManager) -> URL? {
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

    private static func items(
        in url: URL,
        fileManager: FileManager,
        depth: Int = 0,
        showsHiddenFolders: Bool,
        inheritedHidden: Bool = false
    ) -> [OutlineFileTreeItem] {
        guard depth < maximumTreeDepth else {
            return []
        }

        let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isHiddenKey]
        let options: FileManager.DirectoryEnumerationOptions = showsHiddenFolders ? [] : [.skipsHiddenFiles]
        let urls = (try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(resourceKeys),
            options: options
        )) ?? []

        return urls.compactMap { childURL -> OutlineFileTreeItem? in
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

            let itemHidden = inheritedHidden || isDotPrefixed

            return OutlineFileTreeItem(
                url: childURL,
                name: name,
                isDirectory: isDirectory,
                children: isDirectory
                    ? items(
                        in: childURL,
                        fileManager: fileManager,
                        depth: depth + 1,
                        showsHiddenFolders: showsHiddenFolders,
                        inheritedHidden: itemHidden
                    )
                    : [],
                isHidden: itemHidden
            )
        }
        .sorted { first, second in
            if first.isDirectory != second.isDirectory {
                return first.isDirectory
            }

            return first.name.localizedStandardCompare(second.name) == .orderedAscending
        }
        .prefix(maximumChildrenPerFolder)
        .map { $0 }
    }
}

private struct OutlineFileBrowserView: View {
    @ObservedObject var store: OutlineFileBrowserStore
    var openFile: (URL) -> Void
    var currentFileURL: URL?
    @Environment(\.colorScheme) private var colorScheme
    @State private var collapsedIDs: Set<String> = []

    var body: some View {
        // "Show Hidden Folders" now lives in the View menu (⌘⇧.), so the Files tab is just
        // the file tree — no in-sidebar toggle chrome.
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if OutlineSidebarView.rootIsVisible(id: store.iCloudRoot.id, state: store.iCloudRoot.state) {
                    rootView(store.iCloudRoot)
                }
                rootView(store.workspaceRoot)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, OutlineSidebarView.filesContentHorizontalPadding)
            .padding(.top, 4)
            .padding(.bottom, 14)
        }
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func rootView(_ root: OutlineFileRoot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            OutlineFileRootRow(
                root: root,
                isCollapsed: collapsedIDs.contains(root.id),
                toggleCollapsed: { toggle(root.id) },
                chooseWorkspaceFolder: store.chooseWorkspaceFolder
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            // A dimmed iCloud root (unavailable or connected-but-empty) reads as inactive: no
            // expandable tree, no empty-state line — just the quiet header.
            if root.showsTree, !collapsedIDs.contains(root.id), !rootIsDimmed(root) {
                if root.items.isEmpty {
                    // Only a connected (.available) empty folder is genuinely "no Markdown." A
                    // disconnected folder's emptiness just means the cached snapshot is empty — the
                    // header's disconnected icon already signals that, so don't claim it's empty.
                    if root.state == .available {
                        Text("No Markdown files")
                            .font(.system(size: 12))
                            .foregroundStyle(OutlineSidebarView.secondaryTextColor(usesDarkChrome: usesDarkChrome))
                            .padding(.leading, 28)
                            .padding(.vertical, 4)
                    }
                } else {
                    // Direct children start at depth 1 so they indent one step past the root's
                    // icon; each row draws its own guide line back to its parent (see the node).
                    ForEach(root.items) { item in
                        OutlineFileTreeNodeView(
                            item: item,
                            depth: 1,
                            collapsedIDs: $collapsedIDs,
                            openFile: openFile,
                            currentFileURL: currentFileURL
                        )
                        .opacity(root.state == .disconnected ? 0.48 : 1)
                        .allowsHitTesting(root.state != .disconnected)
                    }
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

    private func toggle(_ id: String) {
        if collapsedIDs.contains(id) {
            collapsedIDs.remove(id)
        } else {
            collapsedIDs.insert(id)
        }
    }

    private var usesDarkChrome: Bool {
        colorScheme == .dark
    }
}

private struct OutlineFileRootRow: View {
    var root: OutlineFileRoot
    var isCollapsed: Bool
    var toggleCollapsed: () -> Void
    var chooseWorkspaceFolder: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false
    @State private var isWorkspaceActionHovered = false

    var body: some View {
        HStack(spacing: 8) {
            // The chevron slot is always reserved so titles align, but the glyph only shows when
            // the root actually has an expandable child area.
            Group {
                if showsDisclosure {
                    Image(systemName: chevronSystemImage)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(OutlineSidebarView.secondaryTextColor(usesDarkChrome: usesDarkChrome))
                } else {
                    Color.clear
                }
            }
            .frame(width: 10)
            .accessibilityHidden(true)

            Image(systemName: root.systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(OutlineSidebarView.secondaryTextColor(usesDarkChrome: usesDarkChrome))
                .frame(width: 18)
                .opacity(root.state == .disconnected ? 0.48 : 1)
                .accessibilityHidden(true)

            // Only an expandable root is a real disclosure control. A non-expandable header
            // renders as plain text so VoiceOver doesn't announce an "Expand/Collapse" affordance
            // it can't honor.
            if showsDisclosure {
                Button(action: toggleCollapsed) {
                    titleLabel
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isCollapsed ? "Expand \(root.title)" : "Collapse \(root.title)")
            } else {
                titleLabel
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
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, minHeight: OutlineSidebarView.filesRootRowHeight, maxHeight: OutlineSidebarView.filesRootRowHeight, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(OutlineSidebarView.primaryTextColor(usesDarkChrome: usesDarkChrome).opacity(isHovered && root.state != .unavailable ? OutlineSidebarView.rowHoverFillOpacity : 0))
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }

    private var titleLabel: some View {
        Text(root.title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(OutlineSidebarView.primaryTextColor(usesDarkChrome: usesDarkChrome))
            .lineLimit(1)
            .opacity(root.state == .disconnected ? 0.48 : 1)
    }

    private var showsDisclosure: Bool {
        OutlineSidebarView.rootShowsDisclosure(state: root.state, isEmpty: root.items.isEmpty)
    }

    private var chevronSystemImage: String {
        isCollapsed ? "chevron.right" : "chevron.down"
    }

    private var workspaceActionTitle: String {
        root.state == .unassigned
            ? OutlineSidebarView.chooseWorkspaceButtonTitle
            : OutlineSidebarView.changeWorkspaceButtonTitle
    }

    private var fileActionBackgroundColor: Color {
        Color(nsColor: NSColor(
            calibratedWhite: usesDarkChrome
                ? (isWorkspaceActionHovered ? 1.0 : 0.92)
                : (isWorkspaceActionHovered ? 0.12 : 0.20),
            alpha: 1
        ))
    }

    private var fileActionTextColor: Color {
        Color(nsColor: NSColor(
            calibratedWhite: usesDarkChrome ? 0.10 : 1.0,
            alpha: 1
        ))
    }

    private var usesDarkChrome: Bool {
        colorScheme == .dark
    }
}

private struct OutlineFileTreeNodeView: View {
    var item: OutlineFileTreeItem
    var depth: Int
    @Binding var collapsedIDs: Set<String>
    var openFile: (URL) -> Void
    var currentFileURL: URL?
    @Environment(\.colorScheme) private var colorScheme
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

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            row

            if item.isDirectory, !isCollapsed {
                ForEach(item.children) { child in
                    OutlineFileTreeNodeView(
                        item: child,
                        depth: depth + 1,
                        collapsedIDs: $collapsedIDs,
                        openFile: openFile,
                        currentFileURL: currentFileURL
                    )
                }
            }
        }
    }

    private var row: some View {
        HStack(spacing: 8) {
            if item.isDirectory {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(OutlineSidebarView.secondaryTextColor(usesDarkChrome: usesDarkChrome))
                    .frame(width: 10)
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .opacity(0)
                    .frame(width: 10)
            }

            Image(systemName: item.isDirectory ? "folder" : "doc.text")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(rowForegroundColor)
                .frame(width: 18)

            Text(item.name)
                .font(.system(size: 13))
                .foregroundStyle(rowForegroundColor)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(depth) * OutlineSidebarView.filesTreeIndentStep)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, minHeight: OutlineSidebarView.filesChildRowHeight, maxHeight: OutlineSidebarView.filesChildRowHeight, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(rowBackgroundStyle)
        }
        .overlay(alignment: .topLeading) { guideLine }
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
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// A single faint vertical line in this row's left gutter, aligned under the parent's icon,
    /// connecting the row to its parent. Contiguous siblings form one continuous line; a folder's
    /// expanded children sit at a deeper inset, so the parent's line naturally breaks across them
    /// (one line per open folder, no stacked ladder). Height overshoots the row slightly to bridge
    /// the inter-row spacing.
    @ViewBuilder
    private var guideLine: some View {
        if depth >= 1 {
            Rectangle()
                .fill(OutlineSidebarView.secondaryTextColor(usesDarkChrome: usesDarkChrome).opacity(0.22))
                .frame(width: 1, height: OutlineSidebarView.filesChildRowHeight + 2)
                .padding(.leading, OutlineSidebarView.filesGuideLineInset(forParentDepth: depth - 1))
                .allowsHitTesting(false)
        }
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
    /// otherwise. Selection wins over hover.
    private var rowBackgroundStyle: Color {
        if isSelected {
            return Color.accentColor.opacity(OutlineSidebarView.rowSelectionFillOpacity)
        }
        return OutlineSidebarView.primaryTextColor(usesDarkChrome: usesDarkChrome)
            .opacity(isHovered ? OutlineSidebarView.rowHoverFillOpacity : 0)
    }

    private var rowForegroundColor: Color {
        if isSelected {
            // Accent-colored label + icon over the soft tint, matching the native sidebar look.
            return Color.accentColor
        }
        return item.isHidden
            ? OutlineSidebarView.secondaryTextColor(usesDarkChrome: usesDarkChrome)
            : OutlineSidebarView.primaryTextColor(usesDarkChrome: usesDarkChrome)
    }

    private var usesDarkChrome: Bool {
        colorScheme == .dark
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
