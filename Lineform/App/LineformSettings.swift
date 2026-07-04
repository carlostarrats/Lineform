import SwiftUI

/// App-wide user preferences surfaced in the Settings window. Mirrors the
/// `HiddenFoldersMenuState` pattern: a shared `ObservableObject`, `UserDefaults`
/// keys, and `@Published didSet` write-through. No `@AppStorage`, to match the
/// rest of the app. `UserDefaults` is injectable for tests.
@MainActor
final class LineformSettingsStore: ObservableObject {
    static let shared = LineformSettingsStore()

    static let showSidebarOnLaunchKey = "Lineform.settings.showSidebarOnLaunch"
    static let keepRootFoldersExpandedKey = "Lineform.settings.keepRootFoldersExpanded"
    static let showICloudInSidebarKey = "Lineform.settings.showICloudInSidebar"

    @Published var showSidebarOnLaunch: Bool {
        didSet {
            guard oldValue != showSidebarOnLaunch else { return }
            defaults.set(showSidebarOnLaunch, forKey: Self.showSidebarOnLaunchKey)
        }
    }
    @Published var keepRootFoldersExpanded: Bool {
        didSet {
            guard oldValue != keepRootFoldersExpanded else { return }
            defaults.set(keepRootFoldersExpanded, forKey: Self.keepRootFoldersExpandedKey)
        }
    }
    @Published var showICloudInSidebar: Bool {
        didSet {
            guard oldValue != showICloudInSidebar else { return }
            defaults.set(showICloudInSidebar, forKey: Self.showICloudInSidebarKey)
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Defaults that are `true` when the key is absent can't rely on
        // `bool(forKey:)` returning false, so read via `object(forKey:)` with an
        // explicit fallback. Assign backing storage directly (didSet fires on
        // init assignments — see OutlineFileBrowserStore.init).
        func boolOrDefault(_ key: String, _ fallback: Bool) -> Bool {
            defaults.object(forKey: key) as? Bool ?? fallback
        }
        _showSidebarOnLaunch = Published(initialValue: boolOrDefault(Self.showSidebarOnLaunchKey, true))
        _keepRootFoldersExpanded = Published(initialValue: boolOrDefault(Self.keepRootFoldersExpandedKey, false))
        _showICloudInSidebar = Published(initialValue: boolOrDefault(Self.showICloudInSidebarKey, true))
    }
}

/// Availability + emptiness of the app's iCloud folder, for the Settings iCloud toggle.
enum ICloudFolderStatus: Equatable {
    case unavailable   // no iCloud / not signed in / Debug (no entitlement)
    case empty         // container resolves, no display content — may hide the root
    case notEmpty      // container resolves and has content — hiding is disallowed
}

/// Read-only probe of the iCloud folder. Behind a protocol so the Settings
/// view-model is testable without a real iCloud container.
protocol ICloudFolderProbing: Sendable {
    func status() async -> ICloudFolderStatus
}

struct ICloudFolderProbe: ICloudFolderProbing {
    /// Returns the app's iCloud Documents URL, or nil when unavailable. Resolving
    /// the ubiquity container + enumerating it is the expensive call, so `status()`
    /// runs it on a detached (off-main) task. Defaults to the same resolution the
    /// sidebar uses.
    private let documentsURLProvider: @Sendable () -> URL?

    init(documentsURLProvider: @escaping @Sendable () -> URL? = ICloudFolderProbe.defaultDocumentsURL) {
        self.documentsURLProvider = documentsURLProvider
    }

    /// Resolves via the SAME helper the sidebar uses, so the probe and the rendered
    /// iCloud root can never drift to different folders.
    static let defaultDocumentsURL: @Sendable () -> URL? = {
        OutlineFileBrowserStore.lineformICloudDocumentsURL(fileManager: FileManager.default)
    }

    func status() async -> ICloudFolderStatus {
        // Capture only the @Sendable provider — never `self` or a FileManager — so
        // the detached task stays Sendable-clean. The scan uses a fresh FileManager
        // off the main thread, preserving the iCloud-laziness invariant.
        let provider = documentsURLProvider
        return await Task.detached(priority: .utility) {
            guard let url = provider() else { return ICloudFolderStatus.unavailable }
            return OutlineFileBrowserStore.documentsFolderIsEmpty(at: url, fileManager: FileManager())
                ? .empty
                : .notEmpty
        }.value
    }
}

/// Drives the "Show iCloud in sidebar" control's enabled/visible/checking state
/// from an async probe. `status == nil` means no probe has EVER finished (inline
/// "Checking…"). The Settings pane owns one of these and calls `refresh()` from
/// `.task` when the window appears — never at app launch.
@MainActor
final class ICloudSettingViewModel: ObservableObject {
    @Published private(set) var status: ICloudFolderStatus?

    /// Last completed probe result, shared across Settings opens. Without it, a
    /// machine where iCloud never resolves (Debug, not signed in) would flash the
    /// row in as "Checking…" and pop it back out on EVERY ⌘, open. Seeding from the
    /// cache renders the last-known truth immediately; refresh() then revalidates
    /// quietly and updates in place.
    private static var lastKnownStatus: ICloudFolderStatus?

    private let probe: ICloudFolderProbing
    /// Latest-wins guard: a slow, stale probe completion must not overwrite the
    /// result of a newer refresh.
    private var refreshGeneration = 0

    init(probe: ICloudFolderProbing = ICloudFolderProbe()) {
        self.probe = probe
        _status = Published(initialValue: Self.lastKnownStatus)
    }

    /// Test-only seeding: bypasses the process-wide cache so tests are order-independent.
    init(probe: ICloudFolderProbing, seededStatus: ICloudFolderStatus?) {
        self.probe = probe
        _status = Published(initialValue: seededStatus)
    }

    var isChecking: Bool { status == nil }

    /// Hidden only once we KNOW iCloud is unavailable. While checking we keep the
    /// row visible (showing "Checking…") so it doesn't flicker in/out.
    var isControlVisible: Bool { status != .unavailable }

    /// The folder is confirmed empty, so turning the toggle OFF is allowed.
    var canHideICloud: Bool { status == .empty }

    /// The emptiness guard only blocks turning iCloud OFF. Re-showing a hidden root
    /// is always safe, so when the setting is already off the toggle stays operable
    /// even if the folder has since gained content (otherwise the user could get
    /// stuck unable to bring iCloud back).
    func isToggleDisabled(currentlyShown: Bool) -> Bool {
        currentlyShown && !canHideICloud
    }

    func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        let result = await probe.status()
        guard generation == refreshGeneration else { return }
        status = result
        Self.lastKnownStatus = result
    }
}
