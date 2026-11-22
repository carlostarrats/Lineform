import Foundation

/// The rename rule both apps use for a file or folder in the Files tree. The Mac keeps its old
/// name, `SidebarFileRenaming`, as a forwarder.
public enum FileRenaming {
    /// What the rename field shows: files without their extension (the extension is preserved
    /// automatically), folders as their whole name.
    public static func displayName(for url: URL, isDirectory: Bool) -> String {
        isDirectory ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
    }

    /// The rename target for a user-entered name, or nil when the name is empty, unchanged,
    /// contains a path separator ("/" or the legacy ":"), or is the reserved relative component
    /// "." / ".." (which for a folder — no extension appended — would resolve the destination to
    /// the parent directory, turning a rename into a move that the file system rejects with a
    /// confusing raw error). A file keeps its extension.
    public static func validatedDestination(for url: URL, isDirectory: Bool, newDisplayName: String) -> URL? {
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

    /// The file form of `validatedDestination(for:isDirectory:newDisplayName:)`.
    public static func validatedDestination(for url: URL, newName: String) -> URL? {
        validatedDestination(for: url, isDirectory: false, newDisplayName: newName)
    }
}
