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
/// With `includesICloudPlaceholders` (the iPhone), an iCloud placeholder `.Name.md.icloud` (a file
/// iCloud has not downloaded) is listed as `Name.md`, under its real URL, and is not hidden. The
/// Mac's scan leaves it off, so a placeholder stays a hidden, unsupported entry there. Such an item
/// is flagged `isICloudPlaceholder`, and when the real file sits beside its placeholder (a download
/// in progress), only the real file is listed.
///
/// `alsoExcluding` adds directory names dropped at every level whatever Show Hidden Folders says
/// (the iPhone passes `.Trash`, where its Files section moves deleted documents).
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
        includesICloudPlaceholders: Bool = false,
        alsoExcluding extraExcludedDirectoryNames: Set<String> = [],
        fileManager: FileManager = .default
    ) -> [OutlineFileTreeItem] {
        items(
            in: root,
            fileManager: fileManager,
            depth: 0,
            showsHiddenFolders: showsHidden,
            sortOrder: sortOrder,
            includesICloudPlaceholders: includesICloudPlaceholders,
            excludedNames: excludedDirectoryNames.union(extraExcludedDirectoryNames)
        )
    }

    /// The name a directory entry stands for: an iCloud placeholder `.Name.md.icloud` stands for
    /// `Name.md`, any other dot entry for nothing, and every other entry for itself.
    public static func realName(ofEntry entry: String) -> String? {
        if entry.hasPrefix("."), entry.hasSuffix(".icloud") {
            let name = String(entry.dropFirst().dropLast(".icloud".count))
            return name.isEmpty ? nil : name
        }
        return entry.hasPrefix(".") ? nil : entry
    }

    /// The real name of an iCloud placeholder entry, or nil for any other entry.
    static func placeholderRealName(_ entry: String) -> String? {
        guard entry.hasPrefix("."), entry.hasSuffix(".icloud") else { return nil }
        return realName(ofEntry: entry)
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
        sortOrder: OutlineFileSortOrder,
        includesICloudPlaceholders: Bool = false,
        excludedNames: Set<String> = excludedDirectoryNames
    ) -> [OutlineFileTreeItem] {
        guard depth < maximumTreeDepth else {
            return []
        }

        let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isHiddenKey, .creationDateKey, .contentModificationDateKey]
        // A placeholder is a dot entry, so with placeholders included the enumerator cannot skip
        // hidden entries itself; the same items are dropped below instead.
        let options: FileManager.DirectoryEnumerationOptions =
            showsHiddenFolders || includesICloudPlaceholders ? [] : [.skipsHiddenFiles]
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

            var name = childURL.lastPathComponent
            var itemURL = childURL
            let isDirectory = values.isDirectory == true

            if includesICloudPlaceholders {
                if !isDirectory, values.isRegularFile == true, let realName = placeholderRealName(name) {
                    name = realName
                    itemURL = url.appendingPathComponent(realName)
                } else if !showsHiddenFolders, name.hasPrefix(".") || values.isHidden == true {
                    // What `.skipsHiddenFiles` would have skipped.
                    return nil
                }
            }

            // Always exclude build/vcs noise directories, regardless of the toggle.
            if isDirectory, excludedNames.contains(name) {
                return nil
            }

            // With hidden folders shown, .skipsHiddenFiles is dropped — so also drop genuinely
            // OS-hidden items that are NOT dot-prefixed (system junk), while keeping dotfiles.
            let isDotPrefixed = name.hasPrefix(".")
            let isPlaceholder = itemURL != childURL
            if showsHiddenFolders, values.isHidden == true, !isDotPrefixed, !isPlaceholder {
                return nil
            }

            let isSupportedFile = values.isRegularFile == true
                && supportedFileExtensions.contains(itemURL.pathExtension.lowercased())

            guard isDirectory || isSupportedFile else {
                return nil
            }

            return OutlineFileTreeItem(
                url: itemURL,
                name: name,
                isDirectory: isDirectory,
                children: [],
                isHidden: inheritedHidden || isDotPrefixed,
                createdAt: values.creationDate,
                modifiedAt: values.contentModificationDate,
                isICloudPlaceholder: isPlaceholder
            )
        }
        .sorted { OutlineFileSortOrder.areInIncreasingOrder($0, $1, order: sortOrder) }
        .droppingPlaceholdersOfListedFiles()

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
                sortOrder: sortOrder,
                includesICloudPlaceholders: includesICloudPlaceholders,
                excludedNames: excludedNames
            )
            if !populated.children.isEmpty {
                visible.append(populated)
            }
        }
        return visible
    }
}

private extension Array where Element == OutlineFileTreeItem {
    /// One row per file: a placeholder whose real file is listed too is dropped, keeping the order.
    func droppingPlaceholdersOfListedFiles() -> [OutlineFileTreeItem] {
        guard contains(where: \.isICloudPlaceholder) else { return self }
        let realNames = Set(filter { !$0.isICloudPlaceholder && !$0.isDirectory }.map(\.name))
        return filter { !$0.isICloudPlaceholder || !realNames.contains($0.name) }
    }
}
