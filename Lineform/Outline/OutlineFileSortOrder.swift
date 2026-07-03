import Foundation

/// Sidebar file-tree sort orders. Deliberately no "Manual" — the sidebar has no
/// drag-to-reorder, so offering it would be a dead option (Muse's Manual mode
/// exists only because Muse supports reordering).
enum OutlineFileSortOrder: String, CaseIterable, Identifiable {
    case name
    case dateCreated
    case dateModified

    var id: Self { self }

    var title: String {
        switch self {
        case .name: return "Name"
        case .dateCreated: return "Date Created"
        case .dateModified: return "Date Modified"
        }
    }

    /// Folders always group before files; within each group the chosen key applies.
    /// Date orders are newest-first; missing dates sort last; ties fall back to name.
    static func areInIncreasingOrder(_ first: OutlineFileTreeItem, _ second: OutlineFileTreeItem, order: OutlineFileSortOrder) -> Bool {
        if first.isDirectory != second.isDirectory {
            return first.isDirectory
        }
        switch order {
        case .name:
            break
        case .dateCreated:
            let lhs = first.createdAt ?? .distantPast
            let rhs = second.createdAt ?? .distantPast
            if lhs != rhs { return lhs > rhs }
        case .dateModified:
            let lhs = first.modifiedAt ?? .distantPast
            let rhs = second.modifiedAt ?? .distantPast
            if lhs != rhs { return lhs > rhs }
        }
        return first.name.localizedStandardCompare(second.name) == .orderedAscending
    }

    /// Returns a deep-sorted copy of the tree.
    static func sorted(_ items: [OutlineFileTreeItem], by order: OutlineFileSortOrder) -> [OutlineFileTreeItem] {
        items
            .map { item in
                var copy = item
                copy.children = sorted(item.children, by: order)
                return copy
            }
            .sorted { areInIncreasingOrder($0, $1, order: order) }
    }
}
