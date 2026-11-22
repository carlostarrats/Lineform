import Foundation

/// Watches a folder for files being added, removed, renamed or rewritten, and calls back once a
/// burst of changes settles.
///
/// It is an `NSFilePresenter` on the folder, so it hears every coordinated change: the app's own
/// saves, the Files app, iCloud downloads and other apps. On iPhone it is the file list's change
/// source (the Mac sidebar uses FSEvents instead; iOS has no FSEvents).
///
/// The callback runs on the main actor, `debounceInterval` after the LAST change of a burst, so an
/// autosave or an iCloud sync of many files costs one refresh.
public final class DocumentFolderMonitor: NSObject, NSFilePresenter, @unchecked Sendable {
    /// The trailing debounce, the same as live reload's (`DocumentReloadPolicy.debounceInterval`).
    public static let debounceInterval: TimeInterval = 0.3

    public let presentedItemURL: URL?
    public let presentedItemOperationQueue: OperationQueue

    private let onChange: @MainActor () -> Void
    /// Guards `isRunning` and `generation`, which the presenter queue and the main queue share.
    private let lock = NSLock()
    private var isRunning = false
    /// Bumped by every change; a scheduled callback fires only if no later change superseded it.
    private var generation = 0

    public init(folderURL: URL, onChange: @escaping @MainActor () -> Void) {
        self.presentedItemURL = folderURL
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        self.presentedItemOperationQueue = queue
        self.onChange = onChange
    }

    /// Registers the presenter. Calling it again while running does nothing.
    public func start() {
        lock.lock()
        let wasRunning = isRunning
        isRunning = true
        lock.unlock()
        if !wasRunning { NSFileCoordinator.addFilePresenter(self) }
    }

    /// Unregisters the presenter and drops any callback still waiting on the debounce.
    public func stop() {
        lock.lock()
        let wasRunning = isRunning
        isRunning = false
        generation += 1
        lock.unlock()
        if wasRunning { NSFileCoordinator.removeFilePresenter(self) }
    }

    // MARK: - NSFilePresenter

    public func presentedSubitemDidAppear(at url: URL) { noteChange() }

    public func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) { noteChange() }

    public func presentedSubitemDidChange(at url: URL) { noteChange() }

    public func presentedItemDidChange() { noteChange() }

    public func accommodatePresentedSubitemDeletion(at url: URL, completionHandler: @escaping @Sendable (Error?) -> Void) {
        noteChange()
        completionHandler(nil)
    }

    // MARK: - Debounce

    private func noteChange() {
        lock.lock()
        guard isRunning else {
            lock.unlock()
            return
        }
        generation += 1
        let scheduled = generation
        lock.unlock()

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceInterval) { [weak self] in
            guard let self, self.isCurrent(scheduled) else { return }
            MainActor.assumeIsolated { self.onChange() }
        }
    }

    private func isCurrent(_ scheduled: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isRunning && generation == scheduled
    }
}
