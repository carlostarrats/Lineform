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

    var id: String { url.path }
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
    static let tabTitles = OutlineSidebarTab.allCases.map(\.rawValue)
    static let tabsFillAvailableWidth = true
    static let tabsUseNativeEqualWidthSegments = true
    static let tabsUseExplicitThemeAppearance = true
    static let fileRootTitles = ["iCloud", "Workspace"]
    static let chooseWorkspaceButtonTitle = "Choose"
    static let replaceWorkspaceButtonTitle = "Replace"
    static let iCloudUnavailableShowsLabel = true
    static let iCloudUnavailableStatusTitle = "Unavailable"
    static let filesRowsFillAvailableWidth = true
    static let filesContentHorizontalPadding: CGFloat = 10
    static let filesRootRowHeight: CGFloat = 28
    static let filesChildRowHeight: CGFloat = 26
    static let filesUnavailableRootOpacity = 0.56
    static let filesActionUsesPillStyle = true
    static let filesActionButtonsUseHighContrastFill = true
    static let filesActionButtonsReverseInDarkMode = true
    static let filesActionButtonsShowHoverState = true
    static let filesRootRowsShowLeadingIcons = false
    static let filesRootRowsAlwaysShowDisclosure = true
    static let filesRootTextFollowsDisclosureDirectly = true
    static let filesRootDisclosureIsVisualOnly = true
    static let filesRootTextTogglesCollapse = true
    static let workspaceDisconnectedSystemImage = "exclamationmark.triangle.fill"
    static let minimumColumnWidth: CGFloat = 220
    static let idealColumnWidth: CGFloat = 260
    static let maximumColumnWidth: CGFloat = 300

    @Environment(\.colorScheme) private var colorScheme
    @State private var collapsedNodeIDs: Set<String> = []
    @State private var selectedTab = OutlineSidebarTab.outline
    @StateObject private var fileBrowserStore = OutlineFileBrowserStore()

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

    var body: some View {
        ZStack {
            sidebarBackground
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                tabPicker

                if selectedTab == .outline {
                    outlineContent
                } else {
                    OutlineFileBrowserView(store: fileBrowserStore)
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

private enum OutlineFileRootState: Equatable {
    case available
    case unavailable
    case unassigned
    case disconnected
}

private struct OutlineFileRoot: Identifiable, Equatable {
    var id: String
    var title: String
    var systemImage: String
    var state: OutlineFileRootState
    var items: [OutlineFileTreeItem]

    var showsTree: Bool {
        state == .available || state == .disconnected
    }
}

private final class OutlineFileBrowserStore: ObservableObject {
    static let workspaceBookmarkDefaultsKey = "Lineform.outline.workspaceBookmark"
    static let workspaceSnapshotDefaultsKey = "Lineform.outline.workspaceSnapshot"
    static let maximumTreeDepth = 4
    static let maximumChildrenPerFolder = 80
    static let supportedFileExtensions: Set<String> = ["md", "markdown", "txt"]

    @Published var iCloudRoot = OutlineFileRoot(
        id: "icloud",
        title: "iCloud",
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

    private let defaults: UserDefaults
    private let fileManager: FileManager
    private var workspaceURL: URL?
    private var lastWorkspaceItems: [OutlineFileTreeItem] = []

    init(defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        self.defaults = defaults
        self.fileManager = fileManager
        loadWorkspaceSnapshot()
        loadWorkspaceBookmark()
        refresh()
    }

    func refresh() {
        refreshICloudRoot()
        refreshWorkspaceRoot()
    }

    @MainActor
    func chooseWorkspaceFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Choose"

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        setWorkspaceURL(url)
    }

    func clearWorkspaceAssignment() {
        workspaceURL = nil
        lastWorkspaceItems = []
        defaults.removeObject(forKey: Self.workspaceBookmarkDefaultsKey)
        defaults.removeObject(forKey: Self.workspaceSnapshotDefaultsKey)
        refreshWorkspaceRoot()
    }

    @MainActor
    func openFile(_ item: OutlineFileTreeItem) {
        guard !item.isDirectory else {
            return
        }

        NSDocumentController.shared.openDocument(withContentsOf: item.url, display: true) { _, _, _ in }
    }

    private func loadWorkspaceBookmark() {
        guard let data = defaults.data(forKey: Self.workspaceBookmarkDefaultsKey) else {
            workspaceURL = nil
            return
        }

        workspaceURL = resolveWorkspaceBookmark(from: data)
    }

    private func resolveWorkspaceBookmark(from data: Data) -> URL? {
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            if isStale {
                saveWorkspaceBookmark(for: url)
            }

            return url
        } catch {
            return nil
        }
    }

    private func loadWorkspaceSnapshot() {
        guard let data = defaults.data(forKey: Self.workspaceSnapshotDefaultsKey),
              let items = try? JSONDecoder().decode([OutlineFileTreeItem].self, from: data)
        else {
            return
        }

        lastWorkspaceItems = items
    }

    private func saveWorkspaceSnapshot(_ items: [OutlineFileTreeItem]) {
        guard let data = try? JSONEncoder().encode(items) else {
            return
        }

        defaults.set(data, forKey: Self.workspaceSnapshotDefaultsKey)
    }

    private func setWorkspaceURL(_ url: URL) {
        workspaceURL = url
        saveWorkspaceBookmark(for: url)
        refreshWorkspaceRoot()
    }

    private func saveWorkspaceBookmark(for url: URL) {
        do {
            let bookmark = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            defaults.set(bookmark, forKey: Self.workspaceBookmarkDefaultsKey)
        } catch {
            defaults.removeObject(forKey: Self.workspaceBookmarkDefaultsKey)
        }
    }

    private func refreshICloudRoot() {
        guard let url = Self.iCloudDriveURL(fileManager: fileManager) else {
            iCloudRoot = OutlineFileRoot(
                id: "icloud",
                title: "iCloud",
                systemImage: "icloud",
                state: .unavailable,
                items: []
            )
            return
        }

        iCloudRoot = OutlineFileRoot(
            id: "icloud",
            title: "iCloud",
            systemImage: "icloud",
            state: .available,
            items: Self.items(in: url, fileManager: fileManager)
        )
    }

    private func refreshWorkspaceRoot() {
        guard let workspaceURL else {
            workspaceRoot = OutlineFileRoot(
                id: "workspace",
                title: "Workspace",
                systemImage: "folder",
                state: .unassigned,
                items: []
            )
            return
        }

        if let data = defaults.data(forKey: Self.workspaceBookmarkDefaultsKey),
           let resolvedURL = resolveWorkspaceBookmark(from: data),
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
                title: "Workspace",
                systemImage: "folder.badge.questionmark",
                state: .disconnected,
                items: lastWorkspaceItems
            )
            return
        }

        let didAccess = workspaceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                workspaceURL.stopAccessingSecurityScopedResource()
            }
        }

        let items = Self.items(in: workspaceURL, fileManager: fileManager)
        lastWorkspaceItems = items
        saveWorkspaceSnapshot(items)

        workspaceRoot = OutlineFileRoot(
            id: "workspace",
            title: "Workspace",
            systemImage: "folder",
            state: .available,
            items: items
        )
    }

    private static func iCloudDriveURL(fileManager: FileManager) -> URL? {
        if let ubiquityURL = fileManager.url(forUbiquityContainerIdentifier: nil) {
            return ubiquityURL.appendingPathComponent("Documents", isDirectory: true)
        }

        let cloudDocsURL = fileManager
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        var isDirectory: ObjCBool = false

        guard
            fileManager.fileExists(atPath: cloudDocsURL.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            return nil
        }

        return cloudDocsURL
    }

    private static func items(
        in url: URL,
        fileManager: FileManager,
        depth: Int = 0
    ) -> [OutlineFileTreeItem] {
        guard depth < maximumTreeDepth else {
            return []
        }

        let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey]
        let urls = (try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        )) ?? []

        return urls.compactMap { childURL in
            guard let values = try? childURL.resourceValues(forKeys: resourceKeys) else {
                return nil
            }

            let isDirectory = values.isDirectory == true
            let isSupportedFile = values.isRegularFile == true
                && supportedFileExtensions.contains(childURL.pathExtension.lowercased())

            guard isDirectory || isSupportedFile else {
                return nil
            }

            return OutlineFileTreeItem(
                url: childURL,
                name: childURL.lastPathComponent,
                isDirectory: isDirectory,
                children: isDirectory
                    ? items(in: childURL, fileManager: fileManager, depth: depth + 1)
                    : []
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
    @Environment(\.colorScheme) private var colorScheme
    @State private var collapsedIDs: Set<String> = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                rootView(store.iCloudRoot)
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
                chooseWorkspaceFolder: store.chooseWorkspaceFolder,
                replaceWorkspaceFolder: store.clearWorkspaceAssignment
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            if root.showsTree, !collapsedIDs.contains(root.id) {
                if root.items.isEmpty {
                    Text("No Markdown files")
                        .font(.system(size: 12))
                        .foregroundStyle(OutlineSidebarView.secondaryTextColor(usesDarkChrome: usesDarkChrome))
                        .padding(.leading, 28)
                        .padding(.vertical, 4)
                        .opacity(root.state == .disconnected ? 0.48 : 1)
                } else {
                    ForEach(root.items) { item in
                        OutlineFileTreeNodeView(
                            item: item,
                            depth: 0,
                            collapsedIDs: $collapsedIDs,
                            openFile: store.openFile
                        )
                        .opacity(root.state == .disconnected ? 0.48 : 1)
                        .allowsHitTesting(root.state != .disconnected)
                    }
                }
            }
        }
        .opacity(root.state == .unavailable ? OutlineSidebarView.filesUnavailableRootOpacity : 1)
        .frame(maxWidth: .infinity, alignment: .leading)
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
    var replaceWorkspaceFolder: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false
    @State private var isWorkspaceActionHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: chevronSystemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(OutlineSidebarView.secondaryTextColor(usesDarkChrome: usesDarkChrome))
                .frame(width: 10)
                .accessibilityHidden(true)

            Button(action: toggleCollapsed) {
                Text(root.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OutlineSidebarView.primaryTextColor(usesDarkChrome: usesDarkChrome))
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .opacity(root.state == .disconnected ? 0.48 : 1)
            .accessibilityLabel(isCollapsed ? "Expand \(root.title)" : "Collapse \(root.title)")

            Spacer(minLength: 0)

            if root.id == "icloud", root.state == .unavailable {
                Text(Self.unavailableStatusTitle)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                    .background {
                        Capsule()
                            .fill(OutlineSidebarView.primaryTextColor(usesDarkChrome: usesDarkChrome).opacity(usesDarkChrome ? 0.16 : 0.08))
                    }
                    .foregroundStyle(OutlineSidebarView.primaryTextColor(usesDarkChrome: usesDarkChrome))
                    .allowsHitTesting(false)
            }

            if root.id == "workspace", root.state != .unavailable {
                if root.state == .disconnected {
                    Image(systemName: OutlineSidebarView.workspaceDisconnectedSystemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(OutlineSidebarView.secondaryTextColor(usesDarkChrome: usesDarkChrome))
                }

                Button {
                    if root.state == .unassigned {
                        chooseWorkspaceFolder()
                    } else {
                        replaceWorkspaceFolder()
                    }
                } label: {
                    Text(workspaceActionTitle)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                }
                .buttonStyle(.plain)
                .background {
                    Capsule()
                        .fill(workspaceActionBackgroundColor)
                }
                .foregroundStyle(workspaceActionTextColor)
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

    private var chevronSystemImage: String {
        isCollapsed ? "chevron.right" : "chevron.down"
    }

    private var workspaceActionTitle: String {
        root.state == .unassigned
            ? OutlineSidebarView.chooseWorkspaceButtonTitle
            : OutlineSidebarView.replaceWorkspaceButtonTitle
    }

    private var workspaceActionBackgroundColor: Color {
        Color(nsColor: NSColor(
            calibratedWhite: usesDarkChrome
                ? (isWorkspaceActionHovered ? 1.0 : 0.92)
                : (isWorkspaceActionHovered ? 0.12 : 0.20),
            alpha: 1
        ))
    }

    private var workspaceActionTextColor: Color {
        Color(nsColor: NSColor(
            calibratedWhite: usesDarkChrome ? 0.10 : 1.0,
            alpha: 1
        ))
    }

    private static var unavailableStatusTitle: String {
        OutlineSidebarView.iCloudUnavailableStatusTitle
    }

    private var usesDarkChrome: Bool {
        colorScheme == .dark
    }
}

private struct OutlineFileTreeNodeView: View {
    var item: OutlineFileTreeItem
    var depth: Int
    @Binding var collapsedIDs: Set<String>
    var openFile: (OutlineFileTreeItem) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    private var isCollapsed: Bool {
        collapsedIDs.contains(item.id)
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
                        openFile: openFile
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
                .foregroundStyle(OutlineSidebarView.primaryTextColor(usesDarkChrome: usesDarkChrome))
                .frame(width: 18)

            Text(item.name)
                .font(.system(size: 13))
                .foregroundStyle(OutlineSidebarView.primaryTextColor(usesDarkChrome: usesDarkChrome))
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(depth) * 14)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, minHeight: OutlineSidebarView.filesChildRowHeight, maxHeight: OutlineSidebarView.filesChildRowHeight, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(OutlineSidebarView.primaryTextColor(usesDarkChrome: usesDarkChrome).opacity(isHovered ? OutlineSidebarView.rowHoverFillOpacity : 0))
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if item.isDirectory {
                toggleCollapsed()
            } else {
                openFile(item)
            }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }

    private func toggleCollapsed() {
        if collapsedIDs.contains(item.id) {
            collapsedIDs.remove(item.id)
        } else {
            collapsedIDs.insert(item.id)
        }
    }

    private var usesDarkChrome: Bool {
        colorScheme == .dark
    }
}
