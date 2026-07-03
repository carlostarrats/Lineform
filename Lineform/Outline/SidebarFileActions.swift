import AppKit
import Foundation

/// File-system side of the sidebar's Rename/Delete actions, behind a protocol so unit
/// tests can observe calls without touching the real Trash. Delete is trash-only by
/// design — the app never permanently removes a user's file.
protocol SidebarFileManaging {
    func moveItem(at srcURL: URL, to dstURL: URL) throws
    func trashItem(at url: URL) throws
    func fileExists(atPath path: String) -> Bool
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

struct SidebarFileOperations {
    var fileManager: SidebarFileManaging = FileManager.default

    /// Coordinated move so other file presenters (open documents' reload watchers,
    /// other apps) observe the rename, matching what a Finder rename does.
    func rename(_ url: URL, to destination: URL) throws {
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [
                NSLocalizedDescriptionKey: "A file named “\(destination.lastPathComponent)” already exists."
            ])
        }

        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var operationError: Error?
        coordinator.coordinate(writingItemAt: url, options: .forMoving, error: &coordinationError) { coordinatedURL in
            do {
                try fileManager.moveItem(at: coordinatedURL, to: destination)
                coordinator.item(at: coordinatedURL, didMoveTo: destination)
            } catch {
                operationError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let operationError { throw operationError }
    }

    /// Coordinated move to the Trash. Never `removeItem` — always recoverable.
    func trash(_ url: URL) throws {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var operationError: Error?
        coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { coordinatedURL in
            do {
                try fileManager.trashItem(at: coordinatedURL)
            } catch {
                operationError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let operationError { throw operationError }
    }
}
