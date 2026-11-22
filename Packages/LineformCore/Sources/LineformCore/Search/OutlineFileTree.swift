import Foundation

public struct OutlineFileTreeItem: Identifiable, Equatable, Codable, Sendable {
    public var url: URL
    public var name: String
    public var isDirectory: Bool
    public var children: [OutlineFileTreeItem]
    public var isHidden: Bool = false
    public var createdAt: Date?
    public var modifiedAt: Date?
    /// True for an iCloud placeholder (`.Name.md.icloud`, a file iCloud has not downloaded) that
    /// the iPhone's scan lists under its real name. Never encoded: the Mac's snapshots and scan
    /// never carry placeholders.
    public var isICloudPlaceholder: Bool = false

    public var id: String { url.path }

    /// A copy with `children` dropped. Used for the flattened sidebar rows: the row view reads
    /// only scalar fields, so carrying the whole subtree by value would make SwiftUI's per-row
    /// diff (and the flat-list build) O(subtree) on the hot path (Task 5). The parent flattener
    /// still recurses over the ORIGINAL `children` before stripping, so nothing is lost.
    public var withoutChildren: OutlineFileTreeItem {
        var copy = self
        copy.children = []
        return copy
    }

    public init(
        url: URL,
        name: String,
        isDirectory: Bool,
        children: [OutlineFileTreeItem],
        isHidden: Bool = false,
        createdAt: Date? = nil,
        modifiedAt: Date? = nil,
        isICloudPlaceholder: Bool = false
    ) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.children = children
        self.isHidden = isHidden
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.isICloudPlaceholder = isICloudPlaceholder
    }

    private enum CodingKeys: String, CodingKey {
        case url, name, isDirectory, children, isHidden, createdAt, modifiedAt
    }

    public init(from decoder: Decoder) throws {
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

public enum OutlineFileRootState: Equatable {
    case available
    case unavailable
    case unassigned
    case disconnected
}

public struct OutlineFileRoot: Identifiable, Equatable {
    public var id: String
    public var title: String
    var systemImage: String
    public var state: OutlineFileRootState
    public var items: [OutlineFileTreeItem]

    public init(id: String, title: String, systemImage: String, state: OutlineFileRootState, items: [OutlineFileTreeItem]) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.state = state
        self.items = items
    }

    public var showsTree: Bool {
        state == .available || state == .disconnected
    }
}
