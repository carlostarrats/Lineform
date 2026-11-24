import LineformCore
import SwiftUI

/// One folder's page: its subfolders as rows, its documents as cards (newest first), and New
/// Document as the full-width blue pill. A subfolder is its own page, never a nested tree.
struct FolderView: View {
    var store: FilesStore
    var document: OpenDocument
    var route: FilesFolderRoute
    var actions: FilesItemActions
    var onOpenFolder: (FilesFolderRoute) -> Void
    var onDismiss: () -> Void

    @Environment(\.wordMenuPalette) private var palette

    var body: some View {
        WordMenuPageScaffold(title: route.title) {
            let items = store.children(of: route.url) ?? []
            if items.isEmpty {
                Text(String(localized: "No Markdown files"))
                    .font(.subheadline)
                    .foregroundStyle(palette.color(palette.secondary))
                    .padding(.horizontal, 4)
            }
            FilesFolderRows(items: items, store: store, actions: actions, onOpenFolder: onOpenFolder)
            let documents = FilesSection.recentDocuments(in: items)
            if !documents.isEmpty {
                WordMenuCardGrid(items: documents) { item in
                    DocumentCard(item: item, document: document, store: store, actions: actions) {
                        Task { await document.openReportingFailure(item.url) }
                        onDismiss()
                    }
                }
                .padding(.top, 4)
            }
            // A document made here saves in this folder.
            WordMenuPrimaryButton(title: FilesSection.newDocumentTitle, systemImage: "plus") {
                Task { await document.newDocument(in: route.url) }
                onDismiss()
            }
        }
    }
}

/// A document card: the name, where it is and when it changed, and the start of its text, clipped
/// to the card's fixed height. White with a soft shadow on light; a lighter grey with no shadow on
/// dark. The open document gets no ring. Its ⋯ offers Rename… and Move to Trash.
struct DocumentCard: View {
    var item: OutlineFileTreeItem
    var document: OpenDocument
    var store: FilesStore
    var actions: FilesItemActions
    var open: () -> Void

    @State private var preview: String?
    @State private var frameBox = CardFrameBox()
    @Environment(\.wordMenuPalette) private var palette
    @Environment(\.cardOpenTransition) private var cardTransition

    private var isOpenDocument: Bool {
        guard let url = document.url else { return false }
        return url.resolvingSymlinksInPath().path == item.url.resolvingSymlinksInPath().path
    }

    static func title(for item: OutlineFileTreeItem) -> String {
        (item.name as NSString).deletingPathExtension
    }

    /// The folder it is in (the root's name at the top of iCloud or On My iPhone), then when it
    /// changed ("2 min. ago").
    @MainActor
    static func detail(for item: OutlineFileTreeItem, store: FilesStore? = nil, now: Date = Date()) -> String {
        let parent = item.url.deletingLastPathComponent()
        var folder = parent.lastPathComponent
        if let store, let id = store.rootID(containing: item.url), let root = store.root(id),
           let rootFolder = root.folderURL, FilesStore.key(rootFolder) == FilesStore.key(parent) {
            folder = FilesSection.heading(for: root).title
        }
        guard let date = item.modifiedAt else { return folder }
        let when = date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
        return String(localized: "\(folder) · \(when)")
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: WordMenuMetrics.rowRadius, style: .continuous)
        ZStack(alignment: .topTrailing) {
            Button {
                // A downloaded file expands into the page; a placeholder downloads first (no card).
                if !item.isICloudPlaceholder { cardTransition?.record(url: item.url, frame: frameBox.frame) }
                open()
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: Self.title(for: item))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(palette.color(palette.ink))
                        .lineLimit(2)
                        .padding(.trailing, 28)
                    Text(verbatim: Self.detail(for: item, store: store))
                        .font(.caption)
                        .foregroundStyle(palette.color(palette.secondary))
                        .lineLimit(1)
                    if let preview, !preview.isEmpty {
                        Text(verbatim: preview)
                            .font(.caption)
                            .foregroundStyle(palette.color(palette.secondary))
                            .padding(.top, 4)
                    }
                    Spacer(minLength: 0)
                }
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
                .background(shape.fill(palette.color(palette.card)))
                .shadow(color: .black.opacity(palette.cardHasShadow ? 0.07 : 0), radius: 7, x: 0, y: 3)
                .contentShape(shape)
            }
            .buttonStyle(WordMenuPressStyle())
            .accessibilityLabel(Text(verbatim: Self.title(for: item)))
            .accessibilityValue(Text(verbatim: [Self.detail(for: item, store: store), FilesRow.accessibilityValue(for: item)]
                .compactMap { $0 }.joined(separator: ", ")))
            .filesSwipeAccessibilityActions(FilesSwipeAction.actions(for: item, store: store))
            let menuActions = FilesRowAction.menuActions(for: item)
            if !menuActions.isEmpty {
                Menu {
                    ForEach(menuActions, id: \.self) { action in
                        Button(role: action == .delete ? .destructive : nil) {
                            actions.perform(action, on: item)
                        } label: {
                            Label(action.title, systemImage: action.systemImage)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(palette.color(palette.icon))
                        .frame(width: WordMenuMetrics.minimumTarget, height: WordMenuMetrics.minimumTarget)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(String(localized: "More actions for \(Self.title(for: item))"))
            }
        }
        .filesSwipeActions(FilesSwipeAction.actions(for: item, store: store))
        .recordsCardFrame(frameBox)
        .task(id: PreviewKey(url: item.url, modified: item.modifiedAt, isOpen: isOpenDocument)) {
            if isOpenDocument {
                preview = DocumentCardPreview.excerpt(from: document.text)
            } else if !item.isICloudPlaceholder {
                preview = await DocumentCardPreview.load(item.url)
            }
        }
    }

    private struct PreviewKey: Hashable {
        var url: URL
        var modified: Date?
        var isOpen: Bool
    }
}

/// The start of a document, for its card: read off the main thread, the first 2 KB only, the
/// title line and the Markdown marks dropped.
enum DocumentCardPreview {
    static let byteLimit = 2_048
    static let characterLimit = 220

    static func load(_ url: URL) async -> String? {
        await Task.detached(priority: .utility) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: byteLimit) else { return nil }
            // A cut in the middle of a character loses only that character.
            let text = String(decoding: data, as: UTF8.self)
            return excerpt(from: text)
        }.value
    }

    /// The text after the first heading, its lines joined, without leading Markdown marks.
    static func excerpt(from text: String) -> String {
        var lines = text.prefix(byteLimit).split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        if let first = lines.first, first.hasPrefix("#") { lines.removeFirst() }
        let cleaned = lines.compactMap { line -> String? in
            var line = Substring(line)
            while let first = line.first, "#>-*+".contains(first) { line = line.dropFirst() }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("```") || trimmed.hasPrefix("---") || trimmed.hasPrefix("|") { return nil }
            return trimmed
        }
        return String(cleaned.joined(separator: " ").prefix(characterLimit))
    }
}
