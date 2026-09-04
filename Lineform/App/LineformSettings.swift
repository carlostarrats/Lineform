import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// App-wide user preferences surfaced in the Settings window. Mirrors the
/// `HiddenFoldersMenuState` pattern: a shared `ObservableObject`, `UserDefaults`
/// keys, and `@Published didSet` write-through. No `@AppStorage`, to match the
/// rest of the app. `UserDefaults` is injectable for tests.
@MainActor
final class LineformSettingsStore: ObservableObject {
    static let shared = LineformSettingsStore()

    static let showSidebarOnLaunchKey = "Lineform.settings.showSidebarOnLaunch"
    static let allowRootFolderCollapseKey = "Lineform.settings.allowRootFolderCollapse"
    static let showICloudInSidebarKey = "Lineform.settings.showICloudInSidebar"
    static let checksSpellingWhileTypingKey = "Lineform.settings.checksSpellingWhileTyping"
    static let checksForAnnouncementsKey = "Lineform.settings.checksForAnnouncements"

    @Published var showSidebarOnLaunch: Bool {
        didSet {
            guard oldValue != showSidebarOnLaunch else { return }
            defaults.set(showSidebarOnLaunch, forKey: Self.showSidebarOnLaunchKey)
        }
    }
    /// The user's EXPLICIT choice for root-folder collapsing, or nil if they have
    /// never touched the toggle. Kept tri-state so the effective behavior can adapt:
    /// with no explicit choice, collapsing is on only while BOTH roots are visible —
    /// a lone Workspace root has nothing to collapse against, so it auto-locks open
    /// (and reclaims the chevron column). The moment the user sets the toggle, their
    /// choice is persisted and always wins.
    @Published private(set) var allowRootFolderCollapseChoice: Bool? {
        didSet {
            guard oldValue != allowRootFolderCollapseChoice else { return }
            if let choice = allowRootFolderCollapseChoice {
                defaults.set(choice, forKey: Self.allowRootFolderCollapseKey)
            } else {
                // nil = back to adaptive: the key must actually clear, or the old
                // explicit choice silently resurrects from defaults on next launch.
                defaults.removeObject(forKey: Self.allowRootFolderCollapseKey)
            }
        }
    }

    func setAllowRootFolderCollapse(_ allow: Bool) {
        allowRootFolderCollapseChoice = allow
    }

    /// The behavior the sidebar actually applies: the user's saved choice if they
    /// made one, otherwise collapsible only when the iCloud root is visible alongside
    /// the workspace (two sections are worth collapsing; one is not).
    static func effectiveAllowRootFolderCollapse(choice: Bool?, iCloudRootVisible: Bool) -> Bool {
        choice ?? iCloudRootVisible
    }
    @Published var showICloudInSidebar: Bool {
        didSet {
            guard oldValue != showICloudInSidebar else { return }
            defaults.set(showICloudInSidebar, forKey: Self.showICloudInSidebarKey)
        }
    }

    /// Live (as-you-type) spell checking. Driven solely by the standard
    /// Edit ▸ Spelling and Grammar ▸ Check Spelling While Typing menu item — there is
    /// deliberately no Settings row, so there is only ever one control for one Bool.
    /// `LineformTextView` reads this at construction, which is what makes newly opened
    /// tabs and windows inherit the choice.
    @Published var checksSpellingWhileTyping: Bool {
        didSet {
            guard oldValue != checksSpellingWhileTyping else { return }
            defaults.set(checksSpellingWhileTyping, forKey: Self.checksSpellingWhileTypingKey)
        }
    }

    /// Gates the announcement check. This controls the REQUEST, not just the display:
    /// with it off the app makes no outbound call at all, which is what keeps the
    /// local-first promise literally true for anyone who wants it — and is the honest
    /// answer to what the network entitlement is for.
    @Published var checksForAnnouncements: Bool {
        didSet {
            guard oldValue != checksForAnnouncements else { return }
            defaults.set(checksForAnnouncements, forKey: Self.checksForAnnouncementsKey)
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
        // Tri-state: absent key = the user never chose (nil), so the effective
        // behavior can adapt to root visibility.
        _allowRootFolderCollapseChoice = Published(initialValue: defaults.object(forKey: Self.allowRootFolderCollapseKey) as? Bool)
        _showICloudInSidebar = Published(initialValue: boolOrDefault(Self.showICloudInSidebarKey, true))
        _checksSpellingWhileTyping = Published(initialValue: boolOrDefault(Self.checksSpellingWhileTypingKey, true))
        _checksForAnnouncements = Published(initialValue: boolOrDefault(Self.checksForAnnouncementsKey, true))
    }
}

enum DefaultMarkdownAppStatus: Equatable {
    case unknown
    case notDefault
    case isDefault
    case requesting
    case failed
}

/// The Launch Services seam for Lineform's explicit "Make Default" action. The app declares
/// Markdown as an editable document type in Info.plist; this is only the user's preferred-handler
/// choice, made through AppKit's public API. No helper, installer, or extra entitlement is involved.
@MainActor
protocol MarkdownDefaultApplicationHandling {
    func isLineformDefault() -> Bool
    func makeLineformDefault() async throws
}

@MainActor
struct SystemMarkdownDefaultApplicationHandler: MarkdownDefaultApplicationHandling {
    static let markdownType = UTType(
        importedAs: "net.daringfireball.markdown",
        conformingTo: .plainText
    )

    private let workspace: NSWorkspace
    private let applicationURL: URL
    private let applicationBundleIdentifier: String?

    init(
        workspace: NSWorkspace = .shared,
        applicationURL: URL = Bundle.main.bundleURL,
        applicationBundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) {
        self.workspace = workspace
        self.applicationURL = applicationURL
        self.applicationBundleIdentifier = applicationBundleIdentifier
    }

    func isLineformDefault() -> Bool {
        guard let defaultURL = workspace.urlForApplication(toOpen: Self.markdownType) else {
            return false
        }

        if defaultURL.standardizedFileURL == applicationURL.standardizedFileURL {
            return true
        }

        guard let applicationBundleIdentifier else { return false }
        return Bundle(url: defaultURL)?.bundleIdentifier == applicationBundleIdentifier
    }

    func makeLineformDefault() async throws {
        try await workspace.setDefaultApplication(
            at: applicationURL,
            toOpen: Self.markdownType
        )
    }
}

/// Owns the one-time default-Markdown suggestion and the live status shown in Settings.
///
/// The first real Markdown open/save only records eligibility. `wasEligibleAtLaunch` is captured
/// before that can happen, so the suggestion cannot pile onto the welcome screen or appear midway
/// through someone's first document. It becomes eligible on the NEXT launch, is offered once, and
/// remains available as an explicit Settings action after either choice.
@MainActor
final class DefaultMarkdownAppStore: ObservableObject {
    static let shared = DefaultMarkdownAppStore()

    static let hasUsedMarkdownDocumentKey = "Lineform.defaultMarkdown.hasUsedDocument"
    static let hasResolvedPromptKey = "Lineform.defaultMarkdown.hasResolvedPrompt"
    static let markdownExtensions: Set<String> = ["md", "markdown"]

    @Published private(set) var status: DefaultMarkdownAppStatus = .unknown
    @Published private(set) var isPromptVisible = false

    private let defaults: UserDefaults
    private let handler: any MarkdownDefaultApplicationHandling
    private let wasEligibleAtLaunch: Bool

    init(
        defaults: UserDefaults = .standard,
        handler: any MarkdownDefaultApplicationHandling = SystemMarkdownDefaultApplicationHandler()
    ) {
        self.defaults = defaults
        self.handler = handler
        self.wasEligibleAtLaunch = defaults.bool(forKey: Self.hasUsedMarkdownDocumentKey)
    }

    func recordMarkdownUse(fileURL: URL?) {
        guard
            let fileURL,
            Self.markdownExtensions.contains(fileURL.pathExtension.lowercased())
        else {
            return
        }
        defaults.set(true, forKey: Self.hasUsedMarkdownDocumentKey)
    }

    /// Re-read Launch Services rather than persisting handler status: another app or Finder can
    /// change the default while Lineform is not active. `allowsPrompt` lets Settings refresh its
    /// status without causing the editor card to appear as a side effect.
    func refresh(allowsPrompt: Bool = true) {
        if handler.isLineformDefault() {
            status = .isDefault
            isPromptVisible = false
            defaults.set(true, forKey: Self.hasResolvedPromptKey)
            return
        }

        status = .notDefault
        if allowsPrompt,
           wasEligibleAtLaunch,
           !defaults.bool(forKey: Self.hasResolvedPromptKey) {
            isPromptVisible = true
        }
    }

    func dismissPrompt() {
        defaults.set(true, forKey: Self.hasResolvedPromptKey)
        isPromptVisible = false
    }

    func makeLineformDefault() async {
        guard status != .requesting else { return }
        status = .requesting
        do {
            try await handler.makeLineformDefault()
            status = .isDefault
            isPromptVisible = false
            defaults.set(true, forKey: Self.hasResolvedPromptKey)
        } catch {
            status = .failed
        }
    }
}

/// Availability of the app's iCloud folder, for the Settings iCloud toggle.
enum ICloudFolderStatus: Equatable {
    case unavailable   // no iCloud / not signed in / Debug (no entitlement)
    case empty         // container resolves, no display content
    case notEmpty      // container resolves and has content
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

    init(probe: ICloudFolderProbing = ICloudFolderProbe(), defaults: UserDefaults = .standard) {
        self.probe = probe
        // Seed from the process cache first; failing that, from the PERSISTED
        // last-known container availability the sidebar's scans record — so a Mac
        // known to lack iCloud renders the row disabled on the very first Settings
        // open of a session (no Checking… flash, and the collapse toggle agrees
        // with the sidebar's auto-lock from frame one).
        let persistedUnavailable = (defaults.object(forKey: OutlineFileBrowserStore.lastKnownICloudAvailableDefaultsKey) as? Bool) == false
        _status = Published(initialValue: Self.lastKnownStatus ?? (persistedUnavailable ? .unavailable : nil))
    }

    /// Test-only seeding: bypasses the process-wide cache so tests are order-independent.
    init(probe: ICloudFolderProbing, seededStatus: ICloudFolderStatus?) {
        self.probe = probe
        _status = Published(initialValue: seededStatus)
    }

    /// Test-only: clears the process-wide cache so tests of the designated init's
    /// seeding behavior don't depend on which test ran (and refreshed) first.
    static func resetProcessCacheForTesting() {
        lastKnownStatus = nil
    }

    var isChecking: Bool { status == nil }

    /// iCloud can't resolve on this Mac (Debug build, or not signed in). The row
    /// stays visible but disabled with an explanatory note — hiding it entirely
    /// made the setting look missing.
    var isUnavailable: Bool { status == .unavailable }

    /// Exposed for the status probe tests and for callers that need to distinguish an empty root.
    var canHideICloud: Bool { status == .empty }

    /// A visible iCloud folder may always be hidden: this is a display/default-save preference,
    /// never a destructive operation. Only an unresolved or unavailable container disables the
    /// control, because in that state there is no meaningful iCloud destination to configure.
    func isToggleDisabled(currentlyShown: Bool) -> Bool {
        switch status {
        case nil, .unavailable:
            return true
        case .empty, .notEmpty:
            return false
        }
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
