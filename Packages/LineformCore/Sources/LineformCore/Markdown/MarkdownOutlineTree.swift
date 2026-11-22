import Foundation

/// The document outline as a tree: each heading holds the headings below it until the next
/// heading of the same or a higher level. The Mac sidebar keeps its old names
/// (`OutlineSidebarView.OutlineNode`, `outlineTree(from:)`, `showsTitle(for:)`) as forwarders.
public enum MarkdownOutlineTree {
    public struct Node: Identifiable, Equatable {
        public var item: MarkdownOutlineItem
        public var children: [Node]

        public var id: String { item.id }

        public init(item: MarkdownOutlineItem, children: [Node]) {
            self.item = item
            self.children = children
        }
    }

    public static func tree(from items: [MarkdownOutlineItem]) -> [Node] {
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

        func immutableNode(from node: MutableNode) -> Node {
            Node(item: node.item, children: node.children.map(immutableNode))
        }

        return roots.map(immutableNode)
    }

    /// Whether the outline shows a title row above its headings. It never does: the outline
    /// opens straight on its first heading, or on the empty-state text.
    public static func showsTitle(for items: [MarkdownOutlineItem]) -> Bool {
        false
    }
}
