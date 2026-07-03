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

    static let defaultDocumentsURL: @Sendable () -> URL? = {
        FileManager.default
            .url(forUbiquityContainerIdentifier: OutlineFileBrowserStore.iCloudContainerIdentifier)?
            .appendingPathComponent("Documents", isDirectory: true)
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
/// from an async probe. `status == nil` means the probe hasn't finished (inline
/// "Checking…"). The Settings pane owns one of these and calls `refresh()` from
/// `.task` when the window appears — never at app launch.
@MainActor
final class ICloudSettingViewModel: ObservableObject {
    @Published private(set) var status: ICloudFolderStatus?

    private let probe: ICloudFolderProbing

    init(probe: ICloudFolderProbing = ICloudFolderProbe()) {
        self.probe = probe
    }

    var isChecking: Bool { status == nil }

    /// Hidden only once we KNOW iCloud is unavailable. While checking we keep the
    /// row visible (showing "Checking…") so it doesn't flicker in/out.
    var isControlVisible: Bool { status != .unavailable }

    /// The toggle may be operated only when we've confirmed the folder is empty.
    var isToggleEnabled: Bool { status == .empty }

    func refresh() async {
        status = nil
        status = await probe.status()
    }
}
