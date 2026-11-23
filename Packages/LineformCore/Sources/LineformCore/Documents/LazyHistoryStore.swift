import Foundation

/// A store made on first use: holding one costs nothing, so each app can build its first window
/// or document at launch without anything History-related running (no router, no device name, no
/// file). Every call forwards to the store `make` returns, made once, under a lock (prune calls in
/// from its background queue). Both apps' `sharedStore` is one of these.
public final class LazyHistoryStore: PassageHistoryPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private let make: () -> PassageHistoryPersisting
    private var made: PassageHistoryPersisting?

    public init(_ make: @escaping () -> PassageHistoryPersisting) {
        self.make = make
    }

    /// Whether the real store exists yet (tests).
    public var isMade: Bool { lock.withLock { made != nil } }

    /// The real store, made now if it was not yet (tests).
    public func resolvedStore() -> PassageHistoryPersisting { store }

    private var store: PassageHistoryPersisting {
        lock.withLock {
            if let made { return made }
            let store = make()
            made = store
            return store
        }
    }

    public func load(for url: URL) -> DocumentHistory { store.load(for: url) }
    public func save(_ history: DocumentHistory, for url: URL) { store.save(history, for: url) }
    public func retarget(from old: URL, to new: URL) { store.retarget(from: old, to: new) }
    public func retargetDirectory(from oldDir: URL, to newDir: URL) { store.retargetDirectory(from: oldDir, to: newDir) }
    public func prune(now: Date) { store.prune(now: now) }
    public func clearAll() { store.clearAll() }
    public func noteVersionDeleted(passage: UUID, at index: Int, in history: DocumentHistory, for url: URL) {
        store.noteVersionDeleted(passage: passage, at: index, in: history, for: url)
    }
}
