import LineformCore
import SwiftUI

/// One folder's contents, pushed with the system's sideways slide. Like the root list it is one
/// flat, lazy `List` level: a large folder lays out only the rows on screen, and a subfolder is
/// its own pushed level, never a nested tree.
struct FolderView: View {
    var store: FilesStore
    var route: FilesFolderRoute
    var actions: FilesRowHandlers

    var body: some View {
        List {
            let items = store.children(of: route.url) ?? []
            if items.isEmpty {
                Text(String(localized: "No Markdown files"))
                    .opacity(0.6)
                    .listRowBackground(Color.clear)
            }
            ForEach(items) { item in
                FilesItemRow(item: item, sortOrder: store.sortOrder, actions: actions)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .containerBackground(.clear, for: .navigation)
        .navigationTitle(route.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }
}

/// What a row does when tapped, renamed or deleted. The section owns the alerts.
struct FilesRowHandlers {
    var open: (OutlineFileTreeItem) -> Void
    var rename: (OutlineFileTreeItem) -> Void
    var delete: (OutlineFileTreeItem) -> Void
}

/// A file or folder row: a folder pushes its own list, a file opens. Files swipe to Rename and
/// Delete; a long press offers the same, and Rename alone for a folder.
struct FilesItemRow: View {
    var item: OutlineFileTreeItem
    var sortOrder: OutlineFileSortOrder
    var actions: FilesRowHandlers

    var body: some View {
        Group {
            if item.isDirectory {
                NavigationLink(value: FilesFolderRoute(url: item.url, title: item.name)) {
                    FilesRow(item: item, sortOrder: sortOrder)
                }
            } else {
                Button {
                    actions.open(item)
                } label: {
                    FilesRow(item: item, sortOrder: sortOrder)
                }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // Swipe actions lay out from the trailing edge: Delete outermost.
            ForEach(FilesRowAction.swipeActions(for: item).reversed(), id: \.self) { action in
                actionButton(action)
            }
        }
        .contextMenu {
            ForEach(FilesRowAction.menuActions(for: item), id: \.self) { action in
                actionButton(action)
            }
        }
    }

    @ViewBuilder
    private func actionButton(_ action: FilesRowAction) -> some View {
        switch action {
        case .rename:
            Button {
                actions.rename(item)
            } label: {
                Label(String(localized: "Rename"), systemImage: "pencil")
            }
            .tint(.gray)
        case .delete:
            // Not `role: .destructive`: that would take the row away before the confirmation.
            Button {
                actions.delete(item)
            } label: {
                Label(String(localized: "Delete"), systemImage: "trash")
            }
            .tint(.red)
        }
    }
}

/// A row's look: an SF Symbol and the name, with the date the list is ordered by when it is sorted
/// by date. Hidden (dot) items read a step quieter.
struct FilesRow: View {
    var item: OutlineFileTreeItem
    var sortOrder: OutlineFileSortOrder

    /// The date shown under a file's name: the one the list is in order of, so none for a name
    /// sort or a folder.
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

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let date = Self.shownDate(for: item, sortOrder: sortOrder) {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .opacity(0.6)
                }
            }
        } icon: {
            Image(systemName: Self.systemImage(for: item))
        }
        .opacity(item.isHidden ? 0.6 : 1)
    }
}
