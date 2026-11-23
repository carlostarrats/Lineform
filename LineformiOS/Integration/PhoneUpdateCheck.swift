import LineformCore
import UIKit

/// Menu ▸ Settings ▸ Check for Updates…: one App Store lookup, then one alert. The Mac's
/// `AppUpdateCommand` on iPhone. It runs ONLY when the writer taps the row — nothing calls it at
/// launch or on a timer.
///
/// An App Store app cannot update itself, so the alert only says whether a newer version is on
/// the App Store and, when there is one, offers to open its page. The lookup and the alert's text
/// are the package's (`AppStoreUpdateChecker`, `AppUpdatePresentation`); the checker asks for the
/// iPhone's listing (`AppStorePlatform.current`), never the Mac's. The checker, the alert and the
/// URL opener are injected so tests never touch the network or present an alert.
@MainActor
final class PhoneUpdateCommand: ObservableObject {
    /// One checker for the app's lifetime; the Settings row routes here.
    static let shared = PhoneUpdateCommand()

    private let checker: AppUpdateChecking
    private let currentVersion: () -> String
    /// Shows the alert and returns, once it is dismissed, whether its FIRST button was chosen.
    private let present: @MainActor (AppUpdatePresentation) async -> Bool
    private let open: @MainActor (URL) -> Void

    /// True from the moment a run starts until its alert is dismissed, so a second tap — while the
    /// lookup runs or while the alert is up — is ignored: one alert at a time. The row shows a
    /// spinner meanwhile.
    @Published private(set) var isChecking = false

    init(
        checker: AppUpdateChecking = AppStoreUpdateChecker(),
        currentVersion: @escaping () -> String = { PhoneUpdateCommand.bundleShortVersion() },
        present: @escaping @MainActor (AppUpdatePresentation) async -> Bool = { await PhoneUpdateCommand.presentAlert($0) },
        open: @escaping @MainActor (URL) -> Void = { UIApplication.shared.open($0) }
    ) {
        self.checker = checker
        self.currentVersion = currentVersion
        self.present = present
        self.open = open
    }

    nonisolated static func bundleShortVersion(bundle: Bundle = .main) -> String {
        bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// No-op while a run is already in progress.
    func run() async {
        guard !isChecking else { return }
        isChecking = true
        // Reset on every path, `.failed` included, or the row would go dead for the session.
        defer { isChecking = false }

        let result = await checker.check(currentVersion: currentVersion())
        let presentation = AppUpdatePresentation(result: result)
        let choseFirstButton = await present(presentation)
        // `storeURL` is non-nil only for `updateAvailable`, where the first button is "Open App
        // Store". OK on the other two alerts opens nothing.
        if choseFirstButton, let storeURL = presentation.storeURL {
            open(storeURL)
        }
    }

    /// The alert for `presentation`: the primary button (Open App Store, or OK) and, for an
    /// update, Not Now in Cancel's role. `completion` gets whether the primary button was chosen.
    static func makeAlert(_ presentation: AppUpdatePresentation, completion: @escaping (Bool) -> Void) -> UIAlertController {
        let alert = UIAlertController(title: presentation.title, message: presentation.message, preferredStyle: .alert)
        if let secondary = presentation.secondaryButton {
            let primary = UIAlertAction(title: presentation.primaryButton, style: .default) { _ in completion(true) }
            alert.addAction(primary)
            alert.addAction(UIAlertAction(title: secondary, style: .cancel) { _ in completion(false) })
            alert.preferredAction = primary
        } else {
            // A single OK: Cancel's role, so a hardware keyboard's Esc dismisses it too.
            alert.addAction(UIAlertAction(title: presentation.primaryButton, style: .cancel) { _ in completion(true) })
        }
        return alert
    }

    /// Presents the alert over whatever is on top (the Menu sheet) and waits for a button.
    /// Returns false at once when nothing can present it (no window, or the top controller is
    /// busy presenting or dismissing); opening the store is `run()`'s job, never this method's.
    static func presentAlert(_ presentation: AppUpdatePresentation) async -> Bool {
        guard let presenter = ActivityShareSheet.topPresenter(),
              ActivityShareSheet.canPresent(on: presenter)
        else { return false }
        return await withCheckedContinuation { continuation in
            let alert = makeAlert(presentation) { continuation.resume(returning: $0) }
            presenter.present(alert, animated: true)
        }
    }
}
