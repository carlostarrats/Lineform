import AppKit
import Foundation

/// File-system side of the sidebar's Rename/Delete actions, behind a protocol so unit
/// tests can observe calls without touching the real Trash. Delete is trash-only by
/// design — the app never permanently removes a user's file.
protocol SidebarFileManaging {
    func moveItem(at srcURL: URL, to dstURL: URL) throws
    func trashItem(at url: URL) throws
}

extension FileManager: SidebarFileManaging {
    func trashItem(at url: URL) throws {
        try trashItem(at: url, resultingItemURL: nil)
    }
}

enum SidebarFileRenaming {
    /// What the rename dialog's text field shows: files without their extension
    /// (the extension is preserved automatically), folders as their whole name.
    static func displayName(for url: URL, isDirectory: Bool) -> String {
        isDirectory ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
    }

    /// The rename target for a user-entered name, or nil when the name is empty,
    /// unchanged, contains a path separator ("/" or the legacy ":"), or is the reserved
    /// relative component "." / ".." (which for a folder — no extension appended — would
    /// resolve the destination to the parent directory, turning a rename into a move that
    /// the file system rejects with a confusing raw error).
    static func validatedDestination(for url: URL, isDirectory: Bool, newDisplayName: String) -> URL? {
        let trimmed = newDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains(":"),
              trimmed != ".", trimmed != ".." else {
            return nil
        }

        let ext = isDirectory ? "" : url.pathExtension
        let newName = ext.isEmpty ? trimmed : "\(trimmed).\(ext)"
        guard newName != url.lastPathComponent else {
            return nil
        }

        return url
            .deletingLastPathComponent()
            .appendingPathComponent(newName, isDirectory: isDirectory)
    }
}

/// Copy + the Show-in-Finder action for the sidebar's file dialogs. The dialogs themselves
/// are native SwiftUI `.alert`s presented from `EditorContainerView` — NOT `NSAlert`, which
/// forces the app icon and standard-alert chrome. Only the rare error path uses `NSAlert`.
enum SidebarFileActionPresenter {
    // Every one of these is a `String`, and SwiftUI's `Button(_:)` / `.alert(_:…)` pick their
    // VERBATIM overload for a `String` — being a catalog key is not enough, so the localization
    // has to happen here, at the definition site.
    static let renameFileTitle = String(localized: "Rename File")
    static let renameFolderTitle = String(localized: "Rename Folder")
    static let renameFileMessage = String(localized: "Renames the file. Its contents are kept.")
    static let renameFolderMessage = String(localized: "Renames the folder. Its files are kept.")
    static let renameButtonTitle = String(localized: "Rename")
    static let cancelButtonTitle = String(localized: "Cancel")
    static let deleteButtonTitle = String(localized: "Delete")
    static let deleteMessage = String(localized: "It will be moved to the Trash.")

    static func deleteTitle(for url: URL) -> String {
        String(localized: "Delete “\(url.lastPathComponent)”?")
    }

    static func showInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

/// Plain, deliberately UNcoordinated file operations.
///
/// No `NSFileCoordinator` here: coordinating a write on the main thread against a file the
/// same process's `NSDocument` presents (renaming/deleting the open document — the primary
/// use) can deadlock, and letting presenters observe the move makes `NSDocument` follow a
/// trashed file into the Trash, where the next autosave would resurrect it. In-app windows
/// are retargeted explicitly instead via `LineformAppNotification.sidebarItemRenamed` /
/// `sidebarFileDeleted`, and sidebars refresh via `refreshSidebarFiles`.
struct SidebarFileOperations {
    var fileManager: SidebarFileManaging = FileManager.default

    /// Errors (destination exists, no permission) surface as the system-localized
    /// `moveItem` error — no pre-flight, so case-only renames work on case-insensitive
    /// volumes ("notes.md" → "Notes.md", which a naive exists-check would reject).
    func rename(_ url: URL, to destination: URL) throws {
        try fileManager.moveItem(at: url, to: destination)
    }

    /// Never `removeItem` — always the Trash, always recoverable.
    func trash(_ url: URL) throws {
        try fileManager.trashItem(at: url)
    }
}

/// A pending rename, carried inside `SidebarFileDialog` (url + whether it's a folder, so the
/// alert can title/word itself correctly).
struct SidebarRenameRequest: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let isDirectory: Bool
}

/// The single piece of sidebar dialog state. One enum (not two optionals) so exactly one
/// `.alert` drives both cases: stacking two `.alert` modifiers on one view is unreliable in
/// SwiftUI (one can suppress the other, or both bindings can wedge true at once).
enum SidebarFileDialog: Equatable {
    case rename(SidebarRenameRequest)
    case delete(URL)
}
