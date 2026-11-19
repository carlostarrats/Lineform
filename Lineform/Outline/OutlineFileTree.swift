import Foundation

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
