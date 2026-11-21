import Foundation

/// The text + modification date to apply when a live reload fires.
public struct ReloadResult: Equatable, Sendable {
    public let text: String
    public let modificationDate: Date?

    public init(text: String, modificationDate: Date?) {
        self.text = text
        self.modificationDate = modificationDate
    }
}

/// Abstracts the coordinated disk read so a reload controller is testable without real files.
/// `Sendable` so the reader can be handed to the background read queue.
public protocol DocumentDiskReading: Sendable {
    func readText(at url: URL) -> String?
    func modificationDate(at url: URL) -> Date?
}

/// Real disk reader: sandbox-safe coordinated read + UTF-8 decode.
public struct FileSystemDiskReader: DocumentDiskReading {
    public init() {}

    public func readText(at url: URL) -> String? {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

        var coordinationError: NSError?
        var text: String?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            if let data = try? Data(contentsOf: readURL) {
                // Same decode as the document loader (`MarkdownFileCodec`). If the two disagreed,
                // a BOM'd file would compare unequal to its own in-memory text and reload on
                // every save.
                text = MarkdownFileCodec.decode(data)
            }
        }
        return text
    }

    /// Stat through `FileManager`, never `url.resourceValues(forKeys:)`.
    ///
    /// `URL` caches resource values on the instance, and a reload controller re-uses one stored
    /// `URL` for the life of the watch. With the caching read, the modification date froze at
    /// whatever the first stat saw, so the reload's `modificationDate == lastSeen` pre-check
    /// short-circuited forever: live reload fired at most once per file, and every later external
    /// rewrite produced no reload while the editor kept showing — and kept autosaving — the stale
    /// snapshot.
    public func modificationDate(at url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

/// A minimal NSFilePresenter that forwards content changes and moves to its owner.
/// Deletes are left to the owner's document layer (on the Mac, the framework NSDocument).
/// Callbacks are assigned after init so they can capture the watcher itself for identity checks.
public final class DocumentFileWatcher: NSObject, NSFilePresenter {
    public let presentedItemURL: URL?
    public let presentedItemOperationQueue: OperationQueue
    public var onChange: (() -> Void)?
    public var onMove: ((URL) -> Void)?

    public init(url: URL) {
        self.presentedItemURL = url
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        self.presentedItemOperationQueue = queue
    }

    public func presentedItemDidChange() { onChange?() }

    public func presentedItemDidMove(to newURL: URL) { onMove?(newURL) }
}
