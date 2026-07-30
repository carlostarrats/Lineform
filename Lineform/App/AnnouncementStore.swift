import Foundation
import SwiftUI

/// Owns the announcement lifecycle: when to check, what to show, what's been dismissed.
///
/// Mirrors the `LineformSettingsStore` pattern — shared `ObservableObject`,
/// `UserDefaults` keys, injectable defaults for tests, `Published(initialValue:)`
/// backing storage in `init` (a plain assignment fires `didSet`, which would write
/// back the value it just read).
@MainActor
final class AnnouncementStore: ObservableObject {
    static let shared = AnnouncementStore()

    static let dismissedIDsKey = "Lineform.announcements.dismissedIDs"
    static let lastCheckDateKey = "Lineform.announcements.lastCheckDate"

    /// One check per day. The feed changes a few times a year; anything more frequent
    /// is a request the user pays for and never benefits from.
    static let checkInterval: TimeInterval = 24 * 60 * 60

    /// The announcement currently on screen, or nil. The card observes this.
    @Published private(set) var visible: Announcement?

    private let defaults: UserDefaults
    private let fetcher: AnnouncementFetching
    private let appVersion: String
    private let now: () -> Date

    /// Dismissed ids are kept FOREVER and never pruned against the live feed. An id
    /// that has fallen out of the feed costs a few bytes; re-showing an announcement
    /// the user already dismissed — which is what pruning against the feed would
    /// eventually cause — is the one behaviour this feature must never have.
    private var dismissedIDs: Set<String> {
        didSet {
            guard oldValue != dismissedIDs else { return }
            defaults.set(Array(dismissedIDs).sorted(), forKey: Self.dismissedIDsKey)
        }
    }

    init(
        defaults: UserDefaults = .standard,
        fetcher: AnnouncementFetching = AnnouncementFetcher(),
        appVersion: String = AnnouncementStore.bundleShortVersion(),
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.fetcher = fetcher
        self.appVersion = appVersion
        self.now = now
        self.dismissedIDs = Set(defaults.stringArray(forKey: Self.dismissedIDsKey) ?? [])
    }

    /// `nonisolated` so it can serve as a default argument to `init` — a main-actor
    /// static can't be called from the nonisolated context a default argument runs in.
    nonisolated static func bundleShortVersion(bundle: Bundle = .main) -> String {
        bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Whether enough time has passed to check again. A `lastCheck` in the FUTURE
    /// (clock moved backwards, or a restored-from-backup defaults plist) also counts
    /// as due — otherwise a bad clock could suppress checks indefinitely.
    func isCheckDue() -> Bool {
        guard let last = defaults.object(forKey: Self.lastCheckDateKey) as? Date else { return true }
        let elapsed = now().timeIntervalSince(last)
        return elapsed >= Self.checkInterval || elapsed < 0
    }

    /// Launch entry point. Returns without touching the network when the user has the
    /// setting off or a check isn't due — the toggle gates the REQUEST, not just the
    /// display, so "off" means the app makes no outbound call at all.
    func checkIfNeeded(isEnabled: Bool) async {
        guard isEnabled, isCheckDue() else { return }

        // Stamp BEFORE fetching. A failed check still consumes the day's slot, so a
        // machine that is offline at every launch doesn't retry on a hot loop.
        defaults.set(now(), forKey: Self.lastCheckDateKey)

        let announcements = await fetcher.fetch()
        visible = Self.firstShowable(
            in: announcements,
            dismissedIDs: dismissedIDs,
            appVersion: appVersion
        )
    }

    /// The first entry that is neither dismissed nor aimed at a newer build. Feed
    /// order is authoring order, so the file's own ordering decides precedence —
    /// there is deliberately no priority field.
    static func firstShowable(
        in announcements: [Announcement],
        dismissedIDs: Set<String>,
        appVersion: String
    ) -> Announcement? {
        announcements.first { announcement in
            !dismissedIDs.contains(announcement.id) && announcement.appliesTo(appVersion: appVersion)
        }
    }

    /// Dismiss the visible announcement permanently. Idempotent.
    func dismiss(_ announcement: Announcement) {
        dismissedIDs.insert(announcement.id)
        if visible?.id == announcement.id { visible = nil }
    }

    /// Open the announcement's link in the user's browser and dismiss it — acting on
    /// an announcement is a stronger "I've seen this" than closing it, so it should
    /// never come back either.
    func performAction(for announcement: Announcement) {
        if let url = announcement.actionURL {
            NSWorkspace.shared.open(url)
        }
        dismiss(announcement)
    }

    /// Test seam: clears persisted state so tests are order-independent.
    func resetForTesting() {
        dismissedIDs = []
        defaults.removeObject(forKey: Self.lastCheckDateKey)
        visible = nil
    }
}
