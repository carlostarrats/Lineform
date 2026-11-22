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
///
/// Deletes go to `onDelete` when the owner sets it. A coordinated writer that leaves the file gone
/// (a delete from Files or iCloud, announced with `accommodatePresentedItemDeletion`) and a change
/// notice for a file that is no longer there both count. The file's absence is checked after the
/// writer finishes, because the coordinator also announces a deletion for a `.forReplacing` write
/// that puts the file straight back.
///
/// A rename is never a delete: once the watcher has seen `presentedItemDidMove`, the old path
/// being empty is not reported through `onDelete`. The owner follows the move and watches the new
/// path with a new watcher, so this one's `presentedItemURL` is stale from then on.
///
/// When `onDelete` is nil (the Mac, where the framework NSDocument handles deletes), the watcher
/// behaves exactly as before: it does not answer the delete and relinquish callbacks at all, and
/// a change notice is always `onChange`.
/// Callbacks are assigned after init so they can capture the watcher itself for identity checks.
public final class DocumentFileWatcher: NSObject, NSFilePresenter {
    public let presentedItemURL: URL?
    public let presentedItemOperationQueue: OperationQueue
    public var onChange: (() -> Void)?
    public var onMove: ((URL) -> Void)?
    /// Called when the presented file is deleted. Optional; nil keeps the watcher as it was.
    public var onDelete: (() -> Void)?
    /// Set once the presented file has moved. Only touched on `presentedItemOperationQueue`
    /// (or by a caller driving the presenter methods directly, as tests do).
    private var hasMoved = false

    public init(url: URL) {
        self.presentedItemURL = url
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        self.presentedItemOperationQueue = queue
    }

    public func presentedItemDidChange() {
        if onDelete != nil, !hasMoved, isPresentedItemMissing {
            onDelete?()
            return
        }
        onChange?()
    }

    public func presentedItemDidMove(to newURL: URL) {
        hasMoved = true
        onMove?(newURL)
    }

    /// Only answered when `onDelete` is set (see `responds(to:)`). The file still exists here; the
    /// check runs when the writer hands the file back.
    public func accommodatePresentedItemDeletion(completionHandler: @escaping @Sendable ((any Error)?) -> Void) {
        completionHandler(nil)
    }

    /// Only answered when `onDelete` is set (see `responds(to:)`). After any coordinated writer
    /// finishes, a file that is gone is reported as deleted.
    public func relinquishPresentedItem(toWriter writer: @escaping @Sendable ((@Sendable () -> Void)?) -> Void) {
        // The callbacks are only touched on the presenter queue, which runs one operation at a time.
        nonisolated(unsafe) let watcher = self
        writer {
            watcher.presentedItemOperationQueue.addOperation {
                guard watcher.onDelete != nil, !watcher.hasMoved, watcher.isPresentedItemMissing else { return }
                watcher.onDelete?()
            }
        }
    }

    override public func responds(to selector: Selector!) -> Bool {
        if selector == #selector(NSFilePresenter.accommodatePresentedItemDeletion(completionHandler:))
            || selector == #selector(NSFilePresenter.relinquishPresentedItem(toWriter:)) {
            return onDelete != nil && super.responds(to: selector)
        }
        return super.responds(to: selector)
    }

    private var isPresentedItemMissing: Bool {
        guard let url = presentedItemURL else { return false }
        return !FileManager.default.fileExists(atPath: url.path)
    }
}
