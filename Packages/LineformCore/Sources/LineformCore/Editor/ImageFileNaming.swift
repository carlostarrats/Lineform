import Foundation

/// Where a pasted or dropped image is written and what it is called. Moved from the Mac app's
/// `LineformTextView+ImageInsertion.swift` (`destination`, `uniqueName`, `sanitizedFileBase`),
/// so the iPhone names images exactly as the Mac does.
public enum ImageFileNaming {
    /// Reduce a filename base to clean ASCII: letters, digits, `.`, `-`, `_` only; every run of any
    /// other character (spaces, incl. the U+202F narrow no-break space macOS puts in screenshot
    /// names, punctuation, unicode) collapses to a single `-`. Keeps written image filenames tidy
    /// and — critically — free of characters that can break the `![](path)` link's resolution after
    /// a save/reload round-trip through the `.md`.
    public static func sanitizedFileBase(_ base: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        var result = ""
        var lastWasDash = false
        for character in base {
            if allowed.contains(character) {
                result.append(character)
                lastWasDash = false
            } else if !lastWasDash {
                result.append("-")
                lastWasDash = true
            }
        }
        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "image" : trimmed
    }

    /// `<sanitized base>.<ext>` in `folder`, or `<base>-2.<ext>`, `<base>-3.<ext>`… when that name
    /// is taken.
    public static func uniqueURL(in folder: URL, base: String, ext: String, fileManager: FileManager) -> URL {
        folder.appendingPathComponent(uniqueName(in: folder, base: base, ext: ext, fileManager: fileManager))
    }

    static func uniqueName(in directory: URL, base: String, ext: String, fileManager: FileManager) -> String {
        let safeBase = sanitizedFileBase(base)
        var candidate = "\(safeBase).\(ext)"
        var counter = 1
        while fileManager.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            counter += 1
            candidate = "\(safeBase)-\(counter).\(ext)"
        }
        return candidate
    }

    /// `images/<name>` next to the document (relative, portable): the file URL to write and the
    /// link text to insert. Creates `images/`; nil when it cannot be created or written to.
    public static func imagesFolderDestination(
        nextTo documentDirectory: URL,
        preferredName: String,
        ext: String,
        fileManager: FileManager
    ) -> (url: URL, link: String)? {
        let imagesDirectory = documentDirectory.appendingPathComponent("images", isDirectory: true)
        guard (try? fileManager.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)) != nil,
              fileManager.isWritableFile(atPath: imagesDirectory.path) else {
            return nil
        }
        let name = uniqueName(in: imagesDirectory, base: preferredName, ext: ext, fileManager: fileManager)
        return (imagesDirectory.appendingPathComponent(name), "images/\(name)")
    }

    /// Where to write the image and the link text to insert. Prefers `images/<name>` next to the
    /// document (relative, portable); falls back to the app container with an absolute path when
    /// there is no document folder or it can't be written to.
    public static func destination(
        documentDirectory: URL?,
        preferredName: String,
        ext: String,
        fileManager: FileManager
    ) -> (url: URL, link: String)? {
        if let directory = documentDirectory,
           let destination = imagesFolderDestination(nextTo: directory, preferredName: preferredName, ext: ext, fileManager: fileManager) {
            return destination
        }

        if let support = try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
            let directory = support.appendingPathComponent("Lineform/InsertedImages", isDirectory: true)
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = uniqueName(in: directory, base: preferredName, ext: ext, fileManager: fileManager)
            let url = directory.appendingPathComponent(name)
            // Escaped like every other destination the app writes: the container path runs
            // through the user's home directory, which it does not get to assume is free of a
            // character that would close the `![](…)` early.
            return (url, ImageLinkRewrite.markdownDestination(for: url.path))
        }
        return nil
    }
}
