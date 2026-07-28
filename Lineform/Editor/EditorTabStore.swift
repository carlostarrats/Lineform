import AppKit
import Foundation
import SwiftUI

/// What clicking a file in the sidebar (or ⌘K, or a search result) should do. Split out as a pure
/// value so all four branches are testable — `openSidebarFile` lives on a `View` and can't be
/// exercised directly, and the `revealUnavailable` branch in particular is easy to get wrong.
enum SidebarOpenRoute: Equatable {
    /// Already open in this window — just select it.
    case selectHere(UUID)
    /// Open in another window that is on screen: select it there and bring that window forward.
    case reveal(UUID)
    /// Open in another window whose window can't be resolved right now. SwiftUI tears down and
    /// rebuilds the detail hierarchy (tab bar appearing, reading inspector opening), and the
    /// window number the store reads is published a runloop late — so this is usually a transient
    /// gap for a window that is about to come back, not a dead store. Opening a second copy here
    /// is exactly the duplicate this routing exists to prevent, so try once more next tick.
    case retryReveal(UUID)
    /// Not open anywhere (or the retry already failed) — load it into this window.
    case openHere

    static func route(locatedTabID: UUID?, isOwnStore: Bool, revealWindowAvailable: Bool, canRetry: Bool) -> SidebarOpenRoute {
        guard let locatedTabID else { return .openHere }
        if isOwnStore { return .selectHere(locatedTabID) }
        if revealWindowAvailable { return .reveal(locatedTabID) }
        return canRetry ? .retryReveal(locatedTabID) : .openHere
    }
}

/// Whether a window that just opened a file is a redundant SECOND copy of a file another window
/// already has, and should hand off to that window rather than stay open.
///
/// `openSidebarFile` prevents duplicates for in-app opens, but ⌘O, Finder, the CLI and App Intents
/// all create their window through `DocumentGroup` before any of our code runs, and AppKit's own
/// dedupe misses them: a window has ONE `NSDocument`, repointed to whichever tab is ACTIVE, so a
/// file sitting in a BACKGROUND tab is invisible to it and opens as a second live copy (verified —
/// the duplicate really is a distinct NSDocument in the same process). Merging after the fact is the
/// only hook that covers those paths: SwiftUI's `PlatformDocumentController` must be the shared
/// document controller, and installing an NSDocumentController subclass crashes at launch (verified).
enum DuplicateWindowMerge {
    /// Deliberately strict, because closing a window is destructive if any of these are wrong:
    /// only a window with a SINGLE tab (nothing else would be discarded with it), holding no
    /// unsaved edits, and only when the other window's number is LOWER — an ordering tie-break, so
    /// two windows restoring the same file at launch can never close each other.
    static func shouldHandOff(
        incomingTabCount: Int,
        incomingIsEdited: Bool,
        incomingWindowNumber: Int?,
        existingWindowNumber: Int?
    ) -> Bool {
        guard incomingTabCount == 1, !incomingIsEdited else { return false }
        guard let incomingWindowNumber, let existingWindowNumber else { return false }
        return existingWindowNumber < incomingWindowNumber
    }
}

@MainActor
final class EditorTabStore: ObservableObject {
    @Published var tabs: [DocumentTab]
    @Published var selectedTabID: UUID?

    /// Every live store, so a Save As in one window can see the tabs open in the OTHER windows and
    /// refuse to overwrite one of them (`SaveAsConflict`) — the hazard is identical across windows,
    /// and the window that owns the file has no idea another window just wrote over it. Weak, so a
    /// closed window's store drops out on dealloc with no unregister bookkeeping.
    private static let liveStores = NSHashTable<EditorTabStore>.weakObjects()

    /// The tabs open across every window, in no particular order. Callers identify their own active
    /// tab by ID, which is unique app-wide.
    static var allOpenTabs: [DocumentTab] {
        liveStores.allObjects.flatMap(\.tabs)
    }

    /// Which window this store belongs to, so `locate` can bring that window forward. Kept current
    /// by `EditorContainerView` (the view is what learns its window). Not weak — it's an Int
    /// identifier, resolved against `NSApp.windows` on use, so a closed window just resolves to nil.
    var windowNumber: Int?

    var window: NSWindow? {
        guard let windowNumber else { return nil }
        return NSApp.windows.first { $0.windowNumber == windowNumber }
    }

    /// The tab already showing `url`, anywhere in the app. Opening routes through this so a file
    /// open in another window is REVEALED rather than opened a second time — two windows on one file
    /// means two in-memory snapshots autosaving over each other, which is the same data loss the
    /// Save As guard refuses, just arrived at from the other direction.
    ///
    /// Uses `FileIdentity` rather than `tabIndex(for:)`'s string compare so "already open" means
    /// exactly what the Save As guard means by it.
    /// `preferring` is searched FIRST — `NSHashTable` enumeration order is unspecified, so without
    /// it a window holding the file in one of its own tabs could non-deterministically send the user
    /// to a DIFFERENT window that also has it open (duplicates are reduced, not eliminated: see the
    /// residual note in `SaveAsConflict`). Always prefer where the user already is.
    static func locate(
        _ url: URL,
        preferring preferred: EditorTabStore? = nil,
        excluding excluded: EditorTabStore? = nil
    ) -> (store: EditorTabStore, tabID: UUID)? {
        // Resolved once, not per candidate tab: FileIdentity hits the file system.
        let target = FileIdentity.key(for: url)
        if let preferred, preferred !== excluded, let tabID = preferred.tabID(matchingKey: target) {
            return (preferred, tabID)
        }
        for store in liveStores.allObjects where store !== preferred && store !== excluded {
            if let tabID = store.tabID(matchingKey: target) {
                return (store, tabID)
            }
        }
        return nil
    }

    private func tabID(matchingKey key: String) -> UUID? {
        tabs.first { tab in
            guard let url = tab.fileURL else { return false }
            return FileIdentity.key(for: url) == key
        }?.id
    }

    #if DEBUG
    /// Test-only. `locate` is process-global; a test asserting a file is NOT open would otherwise
    /// depend on whether an earlier test's store had deallocated yet.
    static func resetRegistryForTesting() {
        liveStores.removeAllObjects()
    }
    #endif

    init(initialDocument: LineformDocument, fileURL: URL? = nil) {
        let tab = DocumentTab(document: initialDocument, fileURL: fileURL)
        tabs = [tab]
        selectedTabID = tab.id
        Self.liveStores.add(self)
    }

    var selectedTabIndex: Int? {
        guard let selectedTabID else { return nil }
        return tabs.firstIndex { $0.id == selectedTabID }
    }

    var selectedTab: DocumentTab? {
        guard let index = selectedTabIndex else { return nil }
        return tabs[index]
    }

    var tabCount: Int { tabs.count }

    var shouldShowTabBar: Bool { tabs.count > 1 }

    /// Uses `FileIdentity`, so the three places that decide "is this file already open" — this,
    /// `locate`, and the Save As guard — apply one test. A plain path compare here would let a
    /// symlink alias (or a case-only spelling on a case-insensitive volume) open a second tab on a
    /// file already showing.
    ///
    /// `retargetFileURL`/`markFileDeleted` deliberately still compare raw paths: they answer a
    /// different question ("which tabs does this rename/trash broadcast name"), their prefix match
    /// is inherently path-shaped, and by the time they run the source file is gone — so there is
    /// nothing left on disk for `FileIdentity` to resolve. Known consequence: a tab opened via a
    /// symlink is not retargeted when its TARGET is renamed in the sidebar.
    func tabIndex(for url: URL) -> Int? {
        let target = FileIdentity.key(for: url)
        return tabs.firstIndex { tab in
            guard let tabURL = tab.fileURL else { return false }
            return FileIdentity.key(for: tabURL) == target
        }
    }

    @discardableResult
    func openTab(document: LineformDocument, fileURL: URL? = nil, displayMode: EditorDisplayMode = .write) -> UUID {
        if let existingIndex = fileURL.flatMap({ tabIndex(for: $0) }) {
            selectedTabID = tabs[existingIndex].id
            return tabs[existingIndex].id
        }
        let tab = DocumentTab(document: document, fileURL: fileURL, displayMode: displayMode)
        tabs.append(tab)
        selectedTabID = tab.id
        return tab.id
    }

    func selectTab(id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        selectedTabID = id
    }

    func selectNextTab() {
        guard let index = selectedTabIndex, !tabs.isEmpty else { return }
        let nextIndex = (index + 1) % tabs.count
        selectedTabID = tabs[nextIndex].id
    }

    func selectPreviousTab() {
        guard let index = selectedTabIndex, !tabs.isEmpty else { return }
        let prevIndex = (index - 1 + tabs.count) % tabs.count
        selectedTabID = tabs[prevIndex].id
    }

    @discardableResult
    func closeTab(id: UUID) -> DocumentTab? {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = tabs.remove(at: index)

        if tabs.isEmpty {
            selectedTabID = nil
        } else if id == selectedTabID {
            let newIndex = min(index, tabs.count - 1)
            selectedTabID = tabs[newIndex].id
        }

        return removed
    }

    func updateActiveTab(document: LineformDocument) {
        guard let index = selectedTabIndex else { return }
        tabs[index].document = document
    }

    func updateActiveTabFileURL(_ url: URL?) {
        guard let index = selectedTabIndex else { return }
        tabs[index].fileURL = url
    }

    /// Sets a specific tab's file URL. Unlike `updateActiveTabFileURL`, this does not assume the
    /// tab is selected: the Save-All-before-close chain saves each tab in turn and has already
    /// activated the NEXT one by the time it can record where the previous one landed.
    func updateFileURL(_ url: URL?, forTabID id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].fileURL = url
    }

    func updateActiveTabDisplayMode(_ mode: EditorDisplayMode) {
        guard let index = selectedTabIndex else { return }
        tabs[index].displayMode = mode
    }

    /// Updates the file URL for every tab whose URL matches (or lives under) the rename.
    func retargetFileURL(from source: URL, to destination: URL, isDirectory: Bool) {
        let sourcePath = source.standardizedFileURL.path
        let destPath = destination.standardizedFileURL.path
        for index in tabs.indices {
            guard let url = tabs[index].fileURL else { continue }
            let targetPath = url.standardizedFileURL.path
            if targetPath == sourcePath {
                tabs[index].fileURL = destination
            } else if isDirectory, targetPath.hasPrefix(sourcePath + "/") {
                let suffix = String(targetPath.dropFirst(sourcePath.count))
                tabs[index].fileURL = URL(fileURLWithPath: destPath + suffix)
            }
        }
    }

    /// Clears the file URL for every tab pointing at the deleted file.
    func markFileDeleted(_ url: URL) {
        let deletedPath = url.standardizedFileURL.path
        for index in tabs.indices {
            guard let tabURL = tabs[index].fileURL else { continue }
            if tabURL.standardizedFileURL.path == deletedPath {
                tabs[index].fileURL = nil
            }
        }
    }
}

