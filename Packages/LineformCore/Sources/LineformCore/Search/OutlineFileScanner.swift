import Foundation

/// The Files tree scan both apps use: a recursive, read-only walk of one root folder.
///
/// The rules, carried over unchanged from the Mac sidebar (`OutlineFileBrowserStore`, which keeps
/// its old names as forwarders):
/// - at most `maximumTreeDepth` folder levels;
/// - only `supportedFileExtensions` files are listed;
/// - `excludedDirectoryNames` are always dropped, even with hidden folders shown;
/// - a folder with no supported document anywhere in its scanned subtree is dropped;
/// - a dot-prefixed item (and everything under it) is flagged `isHidden`; with hidden folders
///   off, hidden items are skipped by the enumerator instead.
///
/// It never writes and never coordinates. Callers decide when and on which thread to run it.
public enum OutlineFileScanner {
    public static let maximumTreeDepth = 4
    public static let supportedFileExtensions: Set<String> = ["md", "markdown", "txt"]
    /// Directory names always hidden from the tree, even with "Show hidden folders" on —
    /// build/vcs noise that is never useful reading material.
    public static let excludedDirectoryNames: Set<String> = ["node_modules", ".git"]

    public static func items(
        in root: URL,
        showsHidden: Bool,
        sortOrder: OutlineFileSortOrder = .name,
        fileManager: FileManager = .default
    ) -> [OutlineFileTreeItem] {
        items(in: root, fileManager: fileManager, depth: 0, showsHiddenFolders: showsHidden, sortOrder: sortOrder)
    }

    /// Whether `url` holds no supported document. Hidden folders are included (independent of
    /// the user's Show Hidden Folders setting), so a folder whose only content is dot-folder
    /// Markdown still counts as non-empty — a guard built on this must never hide a root the
    /// tree could visibly render files under. It inspects one child-folder level, matching the
    /// document-only definition without walking a whole large iCloud tree. Read-only.
    public static func documentsFolderIsEmpty(at url: URL, fileManager: FileManager = .default) -> Bool {
        items(
            in: url,
            fileManager: fileManager,
            depth: maximumTreeDepth - 2,
            showsHiddenFolders: true,
            sortOrder: .name
        ).isEmpty
    }

    private static func items(
        in url: URL,
        fileManager: FileManager,
        depth: Int,
        showsHiddenFolders: Bool,
        inheritedHidden: Bool = false,
        sortOrder: OutlineFileSortOrder
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
