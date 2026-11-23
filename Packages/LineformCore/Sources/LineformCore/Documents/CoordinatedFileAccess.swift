import Foundation

/// Every History file read, write, move, delete and folder listing goes through here, so a sync
/// daemon (iCloud) or another process never sees a half-written file and never has a file
/// replaced underneath it while it reads. Each call makes its own `NSFileCoordinator` with no
/// file presenter. Failure-tolerant like the stores: nothing throws; a failure is `nil`/`false`.
enum CoordinatedFileAccess {
    /// The file's bytes, or nil when it is missing, unreadable or coordination failed.
    static func read(_ url: URL) -> Data? {
        var result: Data?
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &error) { url in
            result = try? Data(contentsOf: url)
        }
        return result
    }

    /// Replaces the file atomically, creating its parent folder first. True when written.
    @discardableResult
    static func write(_ data: Data, to url: URL) -> Bool {
        var written = false
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &error) { url in
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                written = true
            } catch {}
        }
        return written
    }

    /// Deletes a file or a folder with everything in it. False when nothing was there or the
    /// delete failed.
    @discardableResult
    static func remove(_ url: URL) -> Bool {
        var removed = false
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forDeleting, error: &error) { url in
            removed = (try? FileManager.default.removeItem(at: url)) != nil
        }
        return removed
    }

    /// Moves `from` to `to`, replacing whatever is at `to` (without ever leaving `to` empty if the
    /// move fails), and creating `to`'s parent folder. True when moved.
    @discardableResult
    static func move(_ from: URL, to: URL) -> Bool {
        var moved = false
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: from, options: .forMoving,
                                                         writingItemAt: to, options: .forReplacing,
                                                         error: &error) { from, to in
            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: from.path) else { return }
            do {
                if fileManager.fileExists(atPath: to.path) {
                    _ = try fileManager.replaceItemAt(to, withItemAt: from)
                } else {
                    try fileManager.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fileManager.moveItem(at: from, to: to)
                }
                moved = true
            } catch {}
        }
        return moved
    }

    /// Every item in the folder (hidden ones included, not recursive), or nil when the folder
    /// cannot be listed — missing, unreadable, or coordination failed.
    static func contents(of directory: URL) -> [URL]? {
        var result: [URL]?
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: directory, options: [], error: &error) { directory in
            result = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [])
        }
        return result
    }

    /// The bytes of every unresolved iCloud conflict version of the file (`NSFileVersion`), each
    /// read coordinated. Empty when there are none, or outside iCloud.
    static func conflictVersionData(of url: URL) -> [Data] {
        var result: [Data] = []
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &error) { url in
            for version in NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? [] {
                if let data = try? Data(contentsOf: version.url) { result.append(data) }
            }
        }
        return result
    }

    /// Marks the file's conflict versions resolved and removes them: call it only after their
    /// contents were merged into the file.
    static func resolveConflictVersions(of url: URL) {
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: [], error: &error) { url in
            let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
            guard !versions.isEmpty else { return }
            for version in versions { version.isResolved = true }
            try? NSFileVersion.removeOtherVersionsOfItem(at: url)
        }
    }
}
