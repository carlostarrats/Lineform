import AppKit
import LineformCore

/// Lineform ▸ Check for Updates…: one App Store lookup, then one alert. Runs ONLY when the
/// user chooses the command — nothing calls it at launch or on a timer.
///
/// The AppKit half of the feature, kept in its own file so `AppUpdateCheck.swift` and
/// `AppUpdatePresentation.swift` stay Foundation-only. The alert and the hand-off to
/// NSWorkspace are injected so tests never build an `NSAlert` (a window) in the default plan.
@MainActor
final class AppUpdateCommand {
    /// One checker for the app's lifetime; the menu item routes here.
    static let shared = AppUpdateCommand()

    private let checker: AppUpdateChecking
    private let currentVersion: () -> String
    /// Shows the alert and returns whether its FIRST button was chosen.
    private let present: @MainActor (AppUpdatePresentation) -> Bool
    private let open: (URL) -> Void

    /// True from the moment a run starts until its alert is dismissed, so a second choice of
    /// the command — while the request is in flight or while the alert is up (`runModal()`
    /// spins a nested run loop the menu can still reach) — is ignored: one alert at a time.
    private(set) var isChecking = false

    init(
        checker: AppUpdateChecking = AppStoreUpdateChecker(),
        currentVersion: @escaping () -> String = { AnnouncementStore.bundleShortVersion() },
        present: @escaping @MainActor (AppUpdatePresentation) -> Bool = AppUpdateCommand.presentAlert,
        open: @escaping (URL) -> Void = { _ = NSWorkspace.shared.open($0) }
    ) {
        self.checker = checker
        self.currentVersion = currentVersion
        self.present = present
        self.open = open
    }

    /// No-op while a run is already in progress.
    func run() async {
        guard !isChecking else { return }
        isChecking = true
        // Reset on every path, `.failed` included, or the command would go dead for the session.
        defer { isChecking = false }

        let result = await checker.check(currentVersion: currentVersion())
        let presentation = AppUpdatePresentation(result: result)
        let choseFirstButton = present(presentation)
        // `storeURL` is non-nil only for `updateAvailable`, where the first button is
        // "Open App Store". OK on the other two alerts opens nothing.
        if choseFirstButton, let storeURL = presentation.storeURL {
            open(storeURL)
        }
    }

    /// Runs the alert app-modal, so it works with no document window open. Returns whether
    /// the first button was chosen; opening the store is `run()`'s job, never this method's.
    static func presentAlert(_ presentation: AppUpdatePresentation) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = presentation.title
        alert.informativeText = presentation.message
        alert.addButton(withTitle: presentation.primaryButton)
        if let secondaryButton = presentation.secondaryButton {
            // NSAlert only binds Escape to a button titled "Cancel"; give "Not Now" the same key.
            alert.addButton(withTitle: secondaryButton).keyEquivalent = "\u{1b}"
        }
        return alert.runModal() == .alertFirstButtonReturn
    }
}
