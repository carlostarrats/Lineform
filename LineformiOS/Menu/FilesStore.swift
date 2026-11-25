import Foundation
import LineformCore
import Observation
import os

/// The file operations Files performs: a move (rename) and a move to the Trash. There is
/// deliberately no delete: a refused Trash is an error, never a fallback to removing the file.
/// Tests inject a recording or refusing double.
protocol FilesFileOperating: Sendable {
    func moveItem(at source: URL, to destination: URL) throws
    func trashItem(at url: URL) throws
    /// Whether `url` is in iCloud (an item in the container, or the container's own folder).
    func isUbiquitous(_ url: URL) -> Bool
    /// `FileManager.setUbiquitous(_:itemAt:destinationURL:)`: moves an item into iCloud (`true`,
    /// `destination` inside the container) or out of it (`false`). It coordinates the move itself,
    /// so it is never wrapped in another coordinator, and it must never run on the main thread.
    func setUbiquitous(_ flag: Bool, itemAt url: URL, destinationURL destination: URL) throws
}

extension FilesFileOperating {
    /// Doubles see no iCloud: a move between the roots is the coordinated move.
    func isUbiquitous(_ url: URL) -> Bool { false }
    func setUbiquitous(_ flag: Bool, itemAt url: URL, destinationURL destination: URL) throws {
        try moveItem(at: url, to: destination)
    }
}

struct LiveFilesFileOperations: FilesFileOperating {
    func moveItem(at source: URL, to destination: URL) throws {
        try FileManager.default.moveItem(at: source, to: destination)
    }

    func isUbiquitous(_ url: URL) -> Bool {
        FileManager.default.isUbiquitousItem(at: url)
    }

    func setUbiquitous(_ flag: Bool, itemAt url: URL, destinationURL destination: URL) throws {
        try FileManager.default.setUbiquitous(flag, itemAt: url, destinationURL: destination)
    }

    /// `FileManager.trashItem(at:resultingItemURL:)`. Some providers refuse it; the error goes to
    /// the caller as it is.
    func trashItem(at url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}

/// The Workspace folder's bookmark and its security scope. Tests inject a double, so no test
/// needs a real picked folder.
protocol WorkspaceBookmarking: Sendable {
    func bookmarkData(for url: URL) throws -> Data
    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool)
    func startAccess(_ url: URL) -> Bool
    func stopAccess(_ url: URL)
}

/// Plain bookmarks: `.withSecurityScope` is macOS only. On iOS a bookmark made from a picked
/// folder's URL while its scope is held carries that grant across launches by itself.
struct LiveWorkspaceBookmarks: WorkspaceBookmarking {
    func bookmarkData(for url: URL) throws -> Data {
        try url.bookmarkData()
    }

    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        let url = try URL(resolvingBookmarkData: data, bookmarkDataIsStale: &isStale)
        return (url, isStale)
    }

    func startAccess(_ url: URL) -> Bool { url.startAccessingSecurityScopedResource() }
    func stopAccess(_ url: URL) { url.stopAccessingSecurityScopedResource() }
}

enum FilesStoreError: Error, Equatable {
    /// Empty, unchanged, holding a path separator ("/" or ":"), or "." / "..".
    case invalidName
    /// Folders are never deleted from Files.
    case folderCannotBeDeleted
    /// An iCloud placeholder (a file not downloaded yet) is never renamed or trashed: on disk it is
    /// only the `.Name.md.icloud` stub. It can be once it has downloaded.
    case notDownloaded
    /// The item cannot move there (a Workspace item, iCloud not available, already there).
    case cannotMove
}

/// Who has the Files store on screen. Each one shows and hides it on its own, so one going away
/// never hides the store from the other (SwiftUI may run a section switch in either order).
enum FilesVisibilityClient: Hashable {
    /// The Files section (its pushed folders included).
    case files
    /// A search across all files.
    case search
}

/// A Files root's identity. The raw value is never shown.
enum FilesRootID: String, CaseIterable {
    /// Lineform's iCloud Documents folder, when the container resolves.
    case icloud
    /// The on-device save folder (On My iPhone › Lineform). Shown in iCloud's place when the
    /// container does not resolve, because that is where new documents save then, and beside
    /// iCloud whenever it holds documents (saved before iCloud came on), so they never vanish.
    case device
    /// The folder the writer chose.
    case workspace
}

struct FilesRoot: Identifiable, Equatable {
    var id: FilesRootID
    var title: String
    var systemImage: String
    /// `.available` (scanned, or about to be), `.unassigned` (no Workspace chosen yet) or
    /// `.unavailable` (a Workspace whose bookmark or folder is gone).
    var state: OutlineFileRootState
    /// The folder this root scans, when it has one.
    var folderURL: URL?
    /// The root's top level. Each folder's contents come from `FilesStore.children(of:)`.
    var items: [OutlineFileTreeItem]
    /// False until the first scan lands, so the empty state never flashes before it.
    var hasScanned: Bool
}

/// The Files section's model: the iCloud (or on-device) root and the Workspace root, their scans,
/// the sort, hidden folders, and coordinated rename and Trash.
///
/// The rules, carried over from the Mac's `OutlineFileBrowserStore`:
/// - Nothing scans until Files is on screen (`setVisible(true)`), and the iCloud container is not
///   even looked up before then. Scans run off the main thread with `OutlineFileScanner`, and the
///   latest one wins.
/// - A sort change and a Show Hidden Folders change both re-scan. One sort serves every root and
///   is kept under both of the Mac's keys.
/// - The iCloud root is hidden when the container does not resolve (always, in Debug).
/// - The Workspace is never scanned before a folder is accepted. Its bookmark is re-resolved (and
///   refreshed when stale), and its security scope is held for the store's lifetime. That is the
///   app's lifetime (`shared`), so a document opened from it stays readable after the sheet closes.
/// - Each visible root is watched with a `DocumentFolderMonitor` while Files is on screen.
///
/// Unlike the Mac, rename and Trash are coordinated (`NSFileCoordinator`, `.forMoving`): the open
/// document's presenter follows a rename and detaches on a Trash. See files-sidebar.md.
@MainActor
@Observable
final class FilesStore {
    typealias Scanner = @Sendable (URL, Bool, OutlineFileSortOrder) -> [OutlineFileTreeItem]

    /// Directory names never listed on iPhone, whatever Show Hidden Folders says: `.Trash` is
    /// where Files' Delete moves documents.
    nonisolated static let excludedDirectoryNames: Set<String> = [".Trash"]

    /// The scan the app uses: the shared tree scan, with iCloud placeholders under their real
    /// names (one row when the real file is there too), and never the Trash.
    nonisolated static let liveScanner: Scanner = { url, showsHidden, sortOrder in
        OutlineFileScanner.items(
            in: url, showsHidden: showsHidden, sortOrder: sortOrder,
            includesICloudPlaceholders: true, alsoExcluding: excludedDirectoryNames, keepsEmptyFolders: true
        )
    }

    /// The app's one store, for the app's lifetime.
    static let shared = FilesStore(
        defaults: .standard,
        iCloudFolder: { DocumentFolderResolver.live().iCloudFolder() },
        deviceFolder: DocumentFolderResolver.live().deviceFolder,
        bookmarks: LiveWorkspaceBookmarks(),
        fileOperations: LiveFilesFileOperations()
    )

    /// The document on screen, so a rename follows it and a Trash detaches it.
    @ObservationIgnored weak var openDocument: OpenDocument?

    private(set) var sortOrder: OutlineFileSortOrder
    private(set) var showsHidden: Bool
    /// True while Files or a search across files is on screen.
    var isVisible: Bool { !visibleClients.isEmpty }
    private var visibleClients: Set<FilesVisibilityClient> = []
    /// Settings › Show iCloud in Files, kept current as the setting changes.
    private(set) var showsICloud: Bool
    /// A failed rename or Trash, for the section's alert.
    private(set) var notice: String?
    /// The chosen Workspace folder, once accepted.
    private(set) var workspaceURL: URL?
    private var workspaceState: OutlineFileRootState = .unassigned
    /// The iCloud Documents folder as of the last look, or nil. Looked up only while visible.
    private var iCloudURL: URL?
    private var hasLookedUpICloud = false
    /// Whether Lineform's iCloud container resolves on this device: nil until looked up (Files'
    /// scan, or Settings asking with `lookUpICloudAvailability`). Never true in Debug (no iCloud
    /// entitlement).
    private(set) var isICloudAvailable: Bool?
    private var itemsByRoot: [FilesRootID: [OutlineFileTreeItem]] = [:]
    private var scannedRoots: Set<FilesRootID> = []
    /// Every scanned folder's contents, keyed by `key(_:)`.
    private var childrenByFolder: [String: [OutlineFileTreeItem]] = [:]

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let iCloudFolder: @Sendable () -> URL?
    @ObservationIgnored private let deviceFolder: URL
    @ObservationIgnored private let bookmarks: any WorkspaceBookmarking
    @ObservationIgnored private let fileOperations: any FilesFileOperating
    /// Whether an iCloud item is downloaded and current, and starting its download (the
    /// document's `LiveUbiquitousItems`; tests inject a fake).
    @ObservationIgnored private let ubiquitousItems: any UbiquitousItemAccessing
    @ObservationIgnored private let scanner: Scanner
    @ObservationIgnored private var heldScopeURL: URL?
    @ObservationIgnored private var scanGenerations: [FilesRootID: Int] = [:]
    @ObservationIgnored private var monitors: [FilesRootID: (url: URL, monitor: DocumentFolderMonitor)] = [:]
    @ObservationIgnored private let log = Logger(subsystem: "com.lineform.app", category: "files")
    @ObservationIgnored private var settingsObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var identityObserver: (any NSObjectProtocol)?

    /// - Parameters:
    ///   - iCloudFolder: Lineform's iCloud Documents folder, or nil. Called off the main thread,
    ///     and only while Files is visible.
    ///   - deviceFolder: the on-device save folder.
    ///   - scanner: the tree scan, run off the main thread. Tests count its calls.
    init(
        defaults: UserDefaults,
        iCloudFolder: @escaping @Sendable () -> URL?,
        deviceFolder: URL,
        bookmarks: any WorkspaceBookmarking,
        fileOperations: any FilesFileOperating,
        ubiquitousItems: any UbiquitousItemAccessing = LiveUbiquitousItems(),
        scanner: @escaping Scanner = FilesStore.liveScanner
    ) {
        self.defaults = defaults
        self.iCloudFolder = iCloudFolder
        self.deviceFolder = deviceFolder
        self.bookmarks = bookmarks
        self.fileOperations = fileOperations
        self.ubiquitousItems = ubiquitousItems
        self.scanner = scanner
        showsHidden = defaults.bool(forKey: LineformSettingKeys.showsHiddenFolders)
        // The Mac reconciles its two keys the same way, preferring the Workspace value.
        let workspaceSort = OutlineFileSortOrder(rawValue: defaults.string(forKey: LineformSettingKeys.workspaceSortOrder) ?? "")
        let iCloudSort = OutlineFileSortOrder(rawValue: defaults.string(forKey: LineformSettingKeys.iCloudSortOrder) ?? "")
        sortOrder = workspaceSort ?? iCloudSort ?? .name
        showsICloud = Self.readShowsICloud(from: defaults)
        loadWorkspaceBookmark()
        // Settings writes the switch to the same defaults; follow it at once.
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: nil
        ) { [weak self] _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.settingsChanged() }
            } else {
                Task { @MainActor in self?.settingsChanged() }
            }
        }
        // iCloud signed in or out, or the container came late: look it up again (only while
        // Files is on screen, or when Settings next asks). Observing looks nothing up.
        identityObserver = NotificationCenter.default.addObserver(
            forName: .NSUbiquityIdentityDidChange, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in await self?.iCloudIdentityDidChange() }
        }
    }

    isolated deinit {
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
        if let identityObserver { NotificationCenter.default.removeObserver(identityObserver) }
    }

    /// iCloud was signed into or out of, or the container became available: what Files knows
    /// about iCloud is forgotten, and looked up again at once when Files is on screen (a rescan),
    /// otherwise when Files or Settings next appears.
    func iCloudIdentityDidChange() async {
        isICloudAvailable = nil
        if isVisible {
            await scanIfVisible()
        } else {
            hasLookedUpICloud = false
            iCloudURL = nil
            itemsByRoot[.icloud] = nil
            scannedRoots.remove(.icloud)
            rebuildIndex()
        }
    }

    // MARK: - Roots

    /// The roots Files shows, in order: iCloud (or the on-device folder when iCloud does not
    /// resolve), then the Workspace. Empty until the first look while visible.
    var roots: [FilesRoot] {
        guard hasLookedUpICloud else { return [] }
        var roots: [FilesRoot] = []
        if let iCloudURL, showsICloud {
            roots.append(makeRoot(.icloud, title: Self.iCloudTitle, systemImage: "icloud", folder: iCloudURL))
        }
        if showsDeviceRoot {
            roots.append(makeRoot(.device, title: Self.deviceTitle, systemImage: "iphone", folder: deviceFolder))
        }
        var workspace = makeRoot(
            .workspace, title: workspaceURL?.lastPathComponent ?? Self.workspaceTitle, systemImage: "folder", folder: workspaceURL
        )
        workspace.state = workspaceState
        if workspaceState != .available { workspace.items = [] }
        roots.append(workspace)
        return roots
    }

    func root(_ id: FilesRootID) -> FilesRoot? {
        roots.first { $0.id == id }
    }

    /// A scanned folder's contents, or nil for a folder the last scan did not see.
    func children(of folder: URL) -> [OutlineFileTreeItem]? {
        childrenByFolder[Self.key(folder)]
    }

    /// The file at `url` as Files would list it: the last scan's row (with its real iCloud
    /// placeholder flag) when it saw one, otherwise a row made now, flagged a placeholder when
    /// only its `.Name.icloud` stub is there. Search results use it, so their actions know.
    func listedItem(at url: URL) -> OutlineFileTreeItem {
        let key = Self.key(url)
        if let row = children(of: url.deletingLastPathComponent())?.first(where: { Self.key($0.url) == key }) {
            return row.withoutChildren
        }
        var item = OutlineFileTreeItem(url: url, name: url.lastPathComponent, isDirectory: false, children: [])
        item.isICloudPlaceholder = Self.isPlaceholder(item)
        return item
    }

    static var workspaceTitle: String { String(localized: "Workspace") }
    static var deviceTitle: String { String(localized: "On My iPhone") }
    /// The iCloud root reads as the app's own folder, as on the Mac. A name, never translated.
    static let iCloudTitle = "Lineform"

    private static func readShowsICloud(from defaults: UserDefaults) -> Bool {
        LineformSettingKeys.bool(
            LineformSettingKeys.showICloudInSidebar, default: LineformSettingKeys.Defaults.showICloudInSidebar, in: defaults
        )
    }

    /// On My iPhone always shows, beside iCloud too (even empty), so a writer can choose to keep
    /// documents on the device. Only when iCloud resolves to the very same folder is it one root.
    private var showsDeviceRoot: Bool {
        iCloudURL.map { Self.key($0) != Self.key(deviceFolder) } ?? true
    }

    /// The defaults changed: pick up Show iCloud in Files. Turning it off drops the iCloud list
    /// at once, so turning it back on never shows a stale one; the next scan lists it afresh.
    private func settingsChanged() {
        let shows = Self.readShowsICloud(from: defaults)
        guard shows != showsICloud else { return }
        showsICloud = shows
        itemsByRoot[.icloud] = nil
        scannedRoots.remove(.icloud)
        rebuildIndex()
        updateMonitors()
        if shows, isVisible {
            Task { await self.scanIfVisible() }
        }
    }

    private func makeRoot(_ id: FilesRootID, title: String, systemImage: String, folder: URL?) -> FilesRoot {
        FilesRoot(
            id: id, title: title, systemImage: systemImage, state: .available, folderURL: folder,
            items: itemsByRoot[id] ?? [], hasScanned: scannedRoots.contains(id)
        )
    }

    /// The folders scanned right now, per root.
    private var scanTargets: [(id: FilesRootID, url: URL)] {
        guard hasLookedUpICloud else { return [] }
        var targets: [(id: FilesRootID, url: URL)] = []
        if let iCloudURL, showsICloud { targets.append((.icloud, iCloudURL)) }
        // Scanned even beside iCloud: that scan is how Files learns whether it holds documents.
        if iCloudURL.map({ Self.key($0) != Self.key(deviceFolder) }) ?? true {
            targets.append((.device, deviceFolder))
        }
        if workspaceState == .available, let workspaceURL { targets.append((.workspace, workspaceURL)) }
        return targets
    }

    // MARK: - Visibility and scanning

    /// Files (or a search across files) came on screen or went away. The store is visible while
    /// any client has it on screen. The last one going away stops the watchers; coming back
    /// watches and scans again on the next `scanIfVisible()`.
    func setVisible(_ visible: Bool, for client: FilesVisibilityClient = .files) {
        let wasVisible = isVisible
        if visible {
            visibleClients.insert(client)
        } else {
            visibleClients.remove(client)
        }
        if wasVisible, !isVisible { stopMonitors() }
    }

    /// Looks up the iCloud folder off the main thread: the container's Documents folder, made if
    /// missing, or nil when the container does not resolve.
    private func lookUpICloudFolder() async -> URL? {
        let lookup = iCloudFolder
        let found = await Task.detached { () -> URL? in
            guard let url = lookup() else { return nil }
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue
            else { return nil }
            return url
        }.value
        let available = found != nil
        if isICloudAvailable != available { isICloudAvailable = available }
        return found
    }

    /// Settings › Show iCloud in Files shows only when the container resolves: looked up off the
    /// main thread, and again each time Settings appears while it did not resolve (iCloud may have
    /// come on since, or the container arrived late). A yes is remembered until the iCloud
    /// account changes (`iCloudIdentityDidChange`).
    func lookUpICloudAvailability() async {
        guard isICloudAvailable != true else { return }
        _ = await lookUpICloudFolder()
    }

    /// Looks up the iCloud folder, then watches and scans every root, only while Files is visible.
    func scanIfVisible() async {
        guard isVisible else { return }
        let found = await lookUpICloudFolder()
        guard isVisible else { return }
        if iCloudURL != found { iCloudURL = found }
        if !hasLookedUpICloud { hasLookedUpICloud = true }
        checkWorkspaceFolder()
        updateMonitors()
        for target in scanTargets {
            await scan(target.id, at: target.url)
        }
    }

    private func scan(_ id: FilesRootID, at url: URL) async {
        let generation = (scanGenerations[id] ?? 0) + 1
        scanGenerations[id] = generation
        let scanner = self.scanner
        let showsHidden = self.showsHidden
        let sortOrder = self.sortOrder
        let items = await Task.detached { scanner(url, showsHidden, sortOrder) }.value
        // Latest wins, and a root that changed meanwhile (a new Workspace) drops the old scan.
        guard scanGenerations[id] == generation, isVisible,
              scanTargets.contains(where: { $0.id == id && Self.key($0.url) == Self.key(url) })
        else { return }
        if itemsByRoot[id] != items { itemsByRoot[id] = items }
        scannedRoots.insert(id)
        rebuildIndex()
    }

    private func rescan(_ id: FilesRootID) async {
        guard isVisible, let target = scanTargets.first(where: { $0.id == id }) else { return }
        await scan(id, at: target.url)
    }

    private func rebuildIndex() {
        var index: [String: [OutlineFileTreeItem]] = [:]
        func add(_ items: [OutlineFileTreeItem], under folder: URL) {
            index[Self.key(folder)] = items
            for item in items where item.isDirectory {
                add(item.children, under: item.url)
            }
        }
        for target in scanTargets {
            add(itemsByRoot[target.id] ?? [], under: target.url)
        }
        if index != childrenByFolder { childrenByFolder = index }
    }

    /// One sort for every root, stored under both of the Mac's keys (raw values, never localized).
    func setSort(_ order: OutlineFileSortOrder) async {
        guard order != sortOrder else { return }
        sortOrder = order
        defaults.set(order.rawValue, forKey: LineformSettingKeys.workspaceSortOrder)
        defaults.set(order.rawValue, forKey: LineformSettingKeys.iCloudSortOrder)
        // A re-scan, not a re-sort, as on the Mac: the scan is the source of truth.
        await scanIfVisible()
    }

    /// Showing hidden folders needs a scan (they were never enumerated); hiding them re-scans too,
    /// so the tree and the scan always agree.
    func setShowsHidden(_ shows: Bool) async {
        guard shows != showsHidden else { return }
        showsHidden = shows
        defaults.set(shows, forKey: LineformSettingKeys.showsHiddenFolders)
        await scanIfVisible()
    }

    // MARK: - Watching

    /// Watches each visible root while Files is on screen. A folder's presenter hears coordinated
    /// changes anywhere below it, so one monitor per root also covers every subfolder
    /// (`testSubfolderChangeRefreshes`).
    private func updateMonitors() {
        guard isVisible else { return stopMonitors() }
        let targets = scanTargets
        for (id, entry) in monitors where !targets.contains(where: { $0.id == id && Self.key($0.url) == Self.key(entry.url) }) {
            entry.monitor.stop()
            monitors[id] = nil
        }
        for target in targets where monitors[target.id] == nil {
            let id = target.id
            let monitor = DocumentFolderMonitor(folderURL: target.url) { [weak self] in
                Task { await self?.rescan(id) }
            }
            monitor.start()
            monitors[id] = (target.url, monitor)
        }
    }

    private func stopMonitors() {
        for entry in monitors.values { entry.monitor.stop() }
        monitors = [:]
    }

    // MARK: - Workspace

    /// Re-resolves the stored bookmark. A stale one is refreshed under the same key. One that
    /// cannot be resolved or refreshed leaves the root unavailable (Change and Choose), and
    /// nothing is scanned without access. The scope, once started, is held for the store's
    /// lifetime.
    private func loadWorkspaceBookmark() {
        guard let data = defaults.data(forKey: LineformSettingKeys.workspaceBookmark) else {
            workspaceState = .unassigned
            return
        }
        guard let (url, isStale) = try? bookmarks.resolve(data) else {
            log.error("The Workspace bookmark no longer resolves")
            workspaceState = .unavailable
            return
        }
        workspaceURL = url
        holdScope(for: url)
        if isStale {
            guard let fresh = try? bookmarks.bookmarkData(for: url) else {
                log.error("The stale Workspace bookmark could not be refreshed")
                releaseScope()
                workspaceState = .unavailable
                return
            }
            defaults.set(fresh, forKey: LineformSettingKeys.workspaceBookmark)
        }
        workspaceState = .available
    }

    /// A Workspace whose folder is gone, or is no longer a folder, reads as unavailable.
    private func checkWorkspaceFolder() {
        guard workspaceState == .available, let workspaceURL else { return }
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: workspaceURL.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
            workspaceState = .unavailable
        }
    }

    /// The writer accepted a folder in the folder picker: hold its scope, keep a plain bookmark
    /// under the Mac's key name (per device), and scan it while Files is visible.
    func chooseWorkspace(_ url: URL) {
        holdScope(for: url)
        guard let data = try? bookmarks.bookmarkData(for: url) else {
            log.error("Could not make a bookmark for the chosen Workspace")
            releaseScope()
            notice = Self.unavailableNotice
            return
        }
        defaults.set(data, forKey: LineformSettingKeys.workspaceBookmark)
        workspaceURL = url
        workspaceState = .available
        itemsByRoot[.workspace] = nil
        scannedRoots.remove(.workspace)
        rebuildIndex()
        updateMonitors()
        Task { await self.rescan(.workspace) }
    }

    private func holdScope(for url: URL) {
        guard heldScopeURL.map(Self.key) != Self.key(url) else { return }
        releaseScope()
        // False for a folder that needs no scope (inside the app's container): nothing to hold.
        if bookmarks.startAccess(url) { heldScopeURL = url }
    }

    private func releaseScope() {
        if let heldScopeURL { bookmarks.stopAccess(heldScopeURL) }
        heldScopeURL = nil
    }

    // MARK: - Rename and Trash

    /// Renames a file (keeping its extension) or a folder, through a coordinated move. When that
    /// moves the open document, the document follows at once and stops renaming itself from its
    /// first line (`OpenDocument.userRenamed(to:)`).
    ///
    /// Throws `FilesStoreError.invalidName` for a name the shared rule refuses (nothing touches
    /// the disk), or the move's own error, which also sets `notice`.
    func rename(_ item: OutlineFileTreeItem, to newName: String) async throws {
        guard !Self.isPlaceholder(item) else { throw refuseStillDownloading(item) }
        guard var destination = FileRenaming.validatedDestination(
            for: item.url, isDirectory: item.isDirectory, newDisplayName: newName
        ) else { throw FilesStoreError.invalidName }

        var source = item.url
        if let document = openDocument, let before = document.url,
           Self.relocated(before, from: item.url, to: destination) != nil {
            // Disk has everything before the file moves.
            await document.flush()
            // That save may itself have renamed the open file from its new first line: move the
            // file where it is now, not where the scan saw it.
            if !item.isDirectory, Self.key(before) == Self.key(item.url),
               let now = document.url, Self.key(now) != Self.key(before) {
                source = now
                guard let moved = FileRenaming.validatedDestination(
                    for: now, isDirectory: false, newDisplayName: newName
                ) else {
                    // The first line already gave the file the chosen name: keep it, as the
                    // writer's choice.
                    document.userRenamed(to: now)
                    await scanIfVisible()
                    return
                }
                destination = moved
            }
        }
        let target = destination
        do {
            // On the main actor, as OpenDocument's own coordinated writes are: every presenter
            // here runs on its own queue, so nothing waits on the main thread, and no autosave can
            // land between the move and the document following it.
            try Self.coordinatedMove(from: source, to: target, using: fileOperations)
        } catch {
            log.error("Rename failed: \(error.localizedDescription, privacy: .public)")
            notice = String(localized: "Couldn’t rename “\(item.name)”.")
            throw error
        }
        if let document = openDocument, let url = document.url,
           let followed = Self.relocated(url, from: source, to: destination) {
            document.userRenamed(to: followed)
        }
        await scanIfVisible()
    }

    /// Moves a file to the Trash through a coordinated move. Folders are never deleted. A location
    /// whose provider refuses the Trash sets `notice` and throws: the file stays where it is, and
    /// nothing ever removes it outright. When the file is the open document, the document keeps
    /// its text on screen and lets go of the path (`OpenDocument.fileWasTrashed(at:)`).
    func trash(_ item: OutlineFileTreeItem) async throws {
        guard Self.canTrash(item) else { throw FilesStoreError.folderCannotBeDeleted }
        guard !Self.isPlaceholder(item) else { throw refuseStillDownloading(item) }
        let source = item.url
        do {
            // On the main actor, for the same reason as `rename`: no autosave can write the file
            // back between the Trash and the document letting go.
            try Self.coordinatedTrash(source, using: fileOperations)
        } catch {
            log.error("Trash failed: \(error.localizedDescription, privacy: .public)")
            notice = String(localized: "Couldn’t move “\(item.name)” to the Trash.")
            throw error
        }
        openDocument?.fileWasTrashed(at: item.url)
        await scanIfVisible()
    }

    // MARK: - Moving between iCloud and On My iPhone

    /// The root `url` is in: iCloud, On My iPhone or the Workspace (nil when none).
    func rootID(containing url: URL) -> FilesRootID? {
        let path = Self.key(url)
        let folders: [(FilesRootID, URL?)] = [(.icloud, iCloudURL), (.device, deviceFolder), (.workspace, workspaceURL)]
        for (id, folder) in folders {
            guard let folder else { continue }
            let folderPath = Self.key(folder)
            if path.hasPrefix(folderPath + "/") { return id }
        }
        return nil
    }

    /// Where `item` can move: a document or folder On My iPhone to iCloud (only while the iCloud
    /// container resolves and Files shows it), one in iCloud to On My iPhone. A Workspace item, or
    /// a file not downloaded yet, has nowhere to go. (A folder holding one, or a file whose local
    /// copy is not current, is refused by `move` itself, which reads the disk.)
    func moveTargets(for item: OutlineFileTreeItem) -> [FilesRootID] {
        guard !Self.isPlaceholder(item) else { return [] }
        switch rootID(containing: item.url) {
        case .device:
            return iCloudURL != nil && showsICloud && showsDeviceRoot ? [.icloud] : []
        case .icloud:
            return showsDeviceRoot ? [.device] : []
        case .workspace, nil:
            return []
        }
    }

    /// The top folder of a movable root.
    private func folder(of root: FilesRootID) -> URL? {
        switch root {
        case .icloud: iCloudURL
        case .device: deviceFolder
        case .workspace: workspaceURL
        }
    }

    /// Moves `item` to the top of `target` with a coordinated move that never replaces: a name
    /// already taken there gets a number ("Notes 2.md"). When it is (or holds) the open document,
    /// the document follows it, so typing goes on into the moved file. Returns where it went.
    ///
    /// Nothing iCloud has not fully brought here moves (a stranded placeholder, or an older local
    /// copy replacing a newer iCloud version): a folder holding any item that is not downloaded
    /// and current, or a file that is not, is refused with a notice (`.notDownloaded`); a file's
    /// download is started. Into or out of iCloud the move is `FileManager.setUbiquitous`, off the
    /// main thread, the API for that direction.
    @discardableResult
    func move(_ item: OutlineFileTreeItem, to target: FilesRootID) async throws -> URL {
        guard Self.isPlaceholder(item) == false else { throw refuseStillDownloading(item) }
        guard moveTargets(for: item).contains(target), let destinationFolder = folder(of: target) else {
            throw FilesStoreError.cannotMove
        }
        try await refuseUnlessDownloaded(item)
        if let document = openDocument, let before = document.url,
           Self.relocated(before, from: item.url, to: item.url) != nil {
            // Disk has everything before the file moves.
            await document.flush()
        }
        // The open file may have been renamed by that save (its first line): move it where it is now.
        var source = item.url
        if !item.isDirectory, let document = openDocument, let now = document.url,
           Self.key(now) != Self.key(item.url),
           Self.key(now.deletingLastPathComponent()) == Self.key(item.url.deletingLastPathComponent()),
           !FileManager.default.fileExists(atPath: item.url.path) {
            source = now
        }
        let destination = destinationFolder.appendingPathComponent(
            Self.freeName(for: source.lastPathComponent, isDirectory: item.isDirectory, in: destinationFolder),
            isDirectory: item.isDirectory
        )
        do {
            let operations = fileOperations
            let intoICloud = target == .icloud
            let from = source, to = destination
            let probe = intoICloud ? destinationFolder : source
            let crossesICloud = await Task.detached { operations.isUbiquitous(probe) }.value
            if crossesICloud {
                // It coordinates itself, and must never run on the main thread. Every keystroke is
                // on disk (the flush above) and the menu covers the page, so no autosave runs meanwhile.
                try await Task.detached {
                    try operations.setUbiquitous(intoICloud, itemAt: from, destinationURL: to)
                }.value
            } else {
                try Self.coordinatedMove(from: source, to: destination, using: fileOperations)
            }
        } catch {
            log.error("Move failed: \(error.localizedDescription, privacy: .public)")
            notice = String(localized: "Couldn’t move “\(item.name)”.")
            throw error
        }
        if let document = openDocument, let url = document.url,
           let followed = Self.relocated(url, from: source, to: destination) {
            document.userRenamed(to: followed)
        }
        await scanIfVisible()
        return destination
    }

    /// `.notDownloaded`, with its notice: a file still downloading (its download is started).
    private func refuseStillDownloading(_ item: OutlineFileTreeItem) -> FilesStoreError {
        let items = ubiquitousItems
        let url = OpenDocument.realURL(for: item.url)
        Task.detached { try? items.startDownloading(url) }
        notice = Self.stillDownloadingNotice(for: item.name)
        return .notDownloaded
    }

    /// Throws `.notDownloaded` (with its notice) unless everything `item` holds is downloaded and
    /// current. Asked fresh, off the main thread: resource values are never read from a cached URL.
    private func refuseUnlessDownloaded(_ item: OutlineFileTreeItem) async throws {
        let items = ubiquitousItems
        let url = item.url
        if item.isDirectory {
            let blocked = await Task.detached { Self.holdsItemNotDownloaded(url, items: items) }.value
            guard blocked else { return }
            notice = Self.folderNotDownloadedNotice(for: item.name)
            throw FilesStoreError.notDownloaded
        }
        let state = await Task.detached { items.downloadState(url) }.value
        guard state != .current else { return }
        throw refuseStillDownloading(item)
    }

    /// Whether anything under `folder` is not downloaded and current: a `.Name.icloud` stub (iOS
    /// before dataless files), or a file whose `ubiquitousItemDownloadingStatus` is not current
    /// (a dataless file, or an older local copy). Reads the disk: never on the main thread.
    nonisolated static func holdsItemNotDownloaded(_ folder: URL, items: any UbiquitousItemAccessing) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: []
        ) else { return false }
        for case let entry as URL in enumerator {
            let name = entry.lastPathComponent
            if name.hasPrefix("."), name.hasSuffix(".icloud") { return true }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDirectory) else { continue }
            if !isDirectory.boolValue, items.downloadState(entry) != .current { return true }
        }
        return false
    }

    static func stillDownloadingNotice(for name: String) -> String {
        String(localized: "“\(name)” is still downloading. Try again in a moment.")
    }

    static func folderNotDownloadedNotice(for name: String) -> String {
        String(localized: "Some files in “\(name)” aren’t downloaded yet. Open them first, then try again.")
    }

    /// `name`, or "Name 2.ext", "Name 3.ext"… — the first not taken in `folder` (case- and
    /// normalisation-blind, as the volume is).
    nonisolated static func freeName(for name: String, isDirectory: Bool, in folder: URL) -> String {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let taken = Set(entries.compactMap(OutlineFileScanner.realName(ofEntry:)).map {
            $0.precomposedStringWithCanonicalMapping.lowercased()
        })
        let ext = isDirectory ? "" : (name as NSString).pathExtension
        let base = isDirectory || ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var candidate = name
        var number = 2
        while taken.contains(candidate.precomposedStringWithCanonicalMapping.lowercased()) {
            candidate = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            number += 1
        }
        return candidate
    }

    /// New Folder: creates `name` inside `parent` with a coordinated, non-replacing create (a
    /// folder or file already there by that name is never touched), then scans so it shows.
    /// Returns the new folder. Throws `FilesStoreError.invalidName` for a name the shared rule
    /// refuses (nothing touches the disk), or the create's own error, which also sets `notice`.
    @discardableResult
    func createFolder(named name: String, in parent: URL) async throws -> URL {
        guard let folder = Self.newFolderDestination(named: name, in: parent) else {
            throw FilesStoreError.invalidName
        }
        do {
            try Self.coordinatedCreateFolder(at: folder)
        } catch {
            log.error("New Folder failed: \(error.localizedDescription, privacy: .public)")
            notice = String(localized: "Couldn’t create “\(folder.lastPathComponent)”.")
            throw error
        }
        await scanIfVisible()
        return folder
    }

    /// Where New Folder would create `name` in `parent`: the shared rename rule's name check
    /// (no "/", no ":", not empty, not "." or ".."). Nil when the name is refused.
    nonisolated static func newFolderDestination(named name: String, in parent: URL) -> URL? {
        // The rule compares against an existing name; a placeholder child stands in for it.
        let placeholder = parent.appendingPathComponent(".lineform-new-folder", isDirectory: true)
        return FileRenaming.validatedDestination(for: placeholder, isDirectory: true, newDisplayName: name)
    }

    /// A folder create, coordinated as a write of the new path. Never replaces: the create fails
    /// when anything already exists there.
    nonisolated static func coordinatedCreateFolder(at folder: URL) throws {
        var coordinationError: NSError?
        var createError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: folder, options: [], error: &coordinationError
        ) { url in
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            } catch {
                createError = error
            }
        }
        if let error = coordinationError ?? createError { throw error }
    }

    /// Only files can be deleted, and only to the Trash.
    nonisolated static func canTrash(_ item: OutlineFileTreeItem) -> Bool { !item.isDirectory }

    /// An iCloud placeholder: flagged by the scan, or (for an item from before it was flagged)
    /// a real file that is missing beside its `.Name.md.icloud` stub. Rename and Delete wait until
    /// it has downloaded; how real providers treat a stub moved or trashed is to be verified on a
    /// device first (files-sidebar.md).
    nonisolated static func isPlaceholder(_ item: OutlineFileTreeItem) -> Bool {
        if item.isICloudPlaceholder { return true }
        guard !item.isDirectory, !FileManager.default.fileExists(atPath: item.url.path) else { return false }
        let stub = item.url.deletingLastPathComponent().appendingPathComponent(".\(item.url.lastPathComponent).icloud")
        return FileManager.default.fileExists(atPath: stub.path)
    }

    func dismissNotice() { notice = nil }

    static var unavailableNotice: String { String(localized: "Workspace folder unavailable") }

    // MARK: - Coordination

    /// A rename, announced to other presenters with `item(at:willMoveTo:)` and
    /// `item(at:didMoveTo:)`, so the open document's presenter follows it.
    nonisolated static func coordinatedMove(from source: URL, to destination: URL, using operations: any FilesFileOperating) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var moveError: Error?
        coordinator.coordinate(
            writingItemAt: source, options: .forMoving,
            writingItemAt: destination, options: .forReplacing,
            error: &coordinationError
        ) { from, to in
            coordinator.item(at: from, willMoveTo: to)
            do {
                try operations.moveItem(at: from, to: to)
                coordinator.item(at: from, didMoveTo: to)
            } catch {
                moveError = error
            }
        }
        if let error = coordinationError ?? moveError { throw error }
    }

    /// A move to the Trash, coordinated `.forMoving`. The open document's presenter relinquishes
    /// the file, finds it gone, and detaches (its delete rule) rather than following it into the
    /// Trash, so no move is announced.
    nonisolated static func coordinatedTrash(_ url: URL, using operations: any FilesFileOperating) throws {
        var coordinationError: NSError?
        var trashError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url, options: .forMoving, error: &coordinationError
        ) { trashURL in
            do {
                try operations.trashItem(at: trashURL)
            } catch {
                trashError = error
            }
        }
        if let error = coordinationError ?? trashError { throw error }
    }

    // MARK: - Paths

    /// Where `url` ends up when `source` moves to `destination`: the destination itself, or a file
    /// inside a renamed folder. Nil when the move does not touch it.
    nonisolated static func relocated(_ url: URL, from source: URL, to destination: URL) -> URL? {
        let path = key(url), sourcePath = key(source)
        if path == sourcePath { return destination }
        guard path.hasPrefix(sourcePath + "/") else { return nil }
        return destination.appendingPathComponent(String(path.dropFirst(sourcePath.count + 1)))
    }

    /// One spelling per folder or file, for comparing and indexing.
    nonisolated static func key(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
