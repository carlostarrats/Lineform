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
    /// unchanged, or contains a path separator ("/" or the legacy ":").
    static func validatedDestination(for url: URL, isDirectory: Bool, newDisplayName: String) -> URL? {
        let trimmed = newDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains(":") else {
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

/// Native alert-style dialogs for the sidebar's Rename/Delete actions (the Muse-style
/// look is exactly an `NSAlert` with an accessory text field). App-modal by design:
/// these are short, focused decisions about one file.
@MainActor
enum SidebarFileActionPresenter {
    static let renameFileTitle = "Rename File"
    static let renameFolderTitle = "Rename Folder"
    static let renameFileMessage = "Renames the file. Its contents are kept."
    static let renameFolderMessage = "Renames the folder. Its files are kept."
    static let renameButtonTitle = "Rename"
    static let cancelButtonTitle = "Cancel"
    static let deleteButtonTitle = "Delete"
    static let deleteMessage = "It will be moved to the Trash."
    static let renameFieldWidth: CGFloat = 230

    static func deleteTitle(for url: URL) -> String {
        "Delete “\(url.lastPathComponent)”?"
    }

    /// Muse-style rename dialog: pre-selected name field, Cancel/Rename. Returns the new
    /// URL on success (operation already performed), nil on cancel or invalid/unchanged
    /// name. Failures present a standard error alert and return nil.
    static func promptRename(
        of url: URL,
        isDirectory: Bool,
        operations: SidebarFileOperations = SidebarFileOperations()
    ) -> URL? {
        let alert = NSAlert()
        alert.messageText = isDirectory ? renameFolderTitle : renameFileTitle
        alert.informativeText = isDirectory ? renameFolderMessage : renameFileMessage
        alert.addButton(withTitle: renameButtonTitle)
        alert.addButton(withTitle: cancelButtonTitle)

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: renameFieldWidth, height: 24))
        field.stringValue = SidebarFileRenaming.displayName(for: url, isDirectory: isDirectory)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }
        guard let destination = SidebarFileRenaming.validatedDestination(
            for: url,
            isDirectory: isDirectory,
            newDisplayName: field.stringValue
        ) else {
            return nil
        }

        do {
            try operations.rename(url, to: destination)
            return destination
        } catch {
            NSAlert(error: error).runModal()
            return nil
        }
    }

    /// Delete confirmation: Cancel is the Return-key default; Delete is destructive and
    /// never the default. Returns true when the file was moved to the Trash.
    static func promptDelete(
        of url: URL,
        operations: SidebarFileOperations = SidebarFileOperations()
    ) -> Bool {
        let alert = NSAlert()
        alert.messageText = deleteTitle(for: url)
        alert.informativeText = deleteMessage
        let deleteButton = alert.addButton(withTitle: deleteButtonTitle)
        let cancelButton = alert.addButton(withTitle: cancelButtonTitle)
        deleteButton.hasDestructiveAction = true
        deleteButton.keyEquivalent = ""
        cancelButton.keyEquivalent = "\r"

        guard alert.runModal() == .alertFirstButtonReturn else {
            return false
        }

        do {
            try operations.trash(url)
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
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
