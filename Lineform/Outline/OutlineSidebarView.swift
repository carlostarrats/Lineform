import SwiftUI

struct OutlineSidebarView: View {
    struct OutlineNode: Identifiable, Equatable {
        var item: MarkdownOutlineItem
        var children: [OutlineNode]

        var id: String { item.id }
    }

    static let emptyStateTitle = "No headings yet"
    static let emptyStateMessage = "Add # Title or ## Section to build an outline."
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
    static let minimumColumnWidth: CGFloat = 220
    static let idealColumnWidth: CGFloat = 260
    static let maximumColumnWidth: CGFloat = 300

    @Environment(\.colorScheme) private var colorScheme
    @State private var collapsedNodeIDs: Set<String> = []

    static func showsTitle(for items: [MarkdownOutlineItem]) -> Bool {
        items.isEmpty
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
                if Self.showsTitle(for: items) {
                    sidebarTitle
                }

                if items.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(Self.emptyStateTitle)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Self.primaryTextColor(usesDarkChrome: usesDarkChrome))

                        Text(Self.emptyStateMessage)
                            .font(.system(size: 12))
                            .foregroundStyle(Self.secondaryTextColor(usesDarkChrome: usesDarkChrome))
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
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
        }
        .frame(minWidth: Self.minimumColumnWidth, idealWidth: Self.idealColumnWidth, maxWidth: Self.maximumColumnWidth)
        .accessibilityLabel("Document outline")
    }

    private var sidebarTitle: some View {
        HStack {
            Text("Outline")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Self.secondaryTextColor(usesDarkChrome: usesDarkChrome))

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 6)
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
