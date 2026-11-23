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
/// How the update alert ended.
enum PhoneUpdateAlertOutcome: Equatable {
    /// Its first button: Open App Store, or the single OK.
    case primary
    /// Not Now, or the alert was taken down without a button (its presenter went away).
    case dismissed
    /// It never came up: nothing could present it, or UIKit refused it. `run()` then shows the
    /// result as the app's quiet notice instead.
    case notShown
}

@MainActor
final class PhoneUpdateCommand: ObservableObject {
    /// One checker for the app's lifetime; the Settings row routes here.
    static let shared = PhoneUpdateCommand()

    private let checker: AppUpdateChecking
    private let currentVersion: () -> String
    /// Shows the alert and returns, once it is gone, how it ended. It always returns: a refused or
    /// vanished alert ends the wait too (`presentAlert`).
    private let present: @MainActor (AppUpdatePresentation) async -> PhoneUpdateAlertOutcome
    private let open: @MainActor (URL) -> Void
    private let noticeDuration: Duration
    private var noticeTask: Task<Void, Never>?

    /// True from the moment a run starts until its alert is dismissed, so a second tap — while the
    /// lookup runs or while the alert is up — is ignored: one alert at a time. The row shows a
    /// spinner meanwhile.
    @Published private(set) var isChecking = false

    /// The result's title, shown as the screen's quiet notice when no alert could come up, so a
    /// check the writer asked for always answers. Clears itself after `noticeDuration`.
    @Published private(set) var notice: String?

    init(
        checker: AppUpdateChecking = AppStoreUpdateChecker(),
        currentVersion: @escaping () -> String = { PhoneUpdateCommand.bundleShortVersion() },
        present: @escaping @MainActor (AppUpdatePresentation) async -> PhoneUpdateAlertOutcome = { await PhoneUpdateCommand.presentAlert($0) },
        open: @escaping @MainActor (URL) -> Void = { UIApplication.shared.open($0) },
        noticeDuration: Duration = OpenDocument.imageNoticeDuration
    ) {
        self.checker = checker
        self.currentVersion = currentVersion
        self.present = present
        self.open = open
        self.noticeDuration = noticeDuration
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
        switch await present(presentation) {
        case .primary:
            // `storeURL` is non-nil only for `updateAvailable`, where the first button is "Open
            // App Store". OK on the other two alerts opens nothing.
            if let storeURL = presentation.storeURL { open(storeURL) }
        case .dismissed:
            break
        case .notShown:
            showNotice(presentation.title)
        }
    }

    private func showNotice(_ message: String) {
        noticeTask?.cancel()
        notice = message
        let duration = noticeDuration
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    /// The alert for `presentation`: the primary button (Open App Store, or OK) and, for an
    /// update, Not Now in Cancel's role. `completion` gets whether the primary button was chosen.
    static func makeAlert(_ presentation: AppUpdatePresentation, completion: @escaping (Bool) -> Void) -> PhoneUpdateAlertController {
        let alert = PhoneUpdateAlertController(title: presentation.title, message: presentation.message, preferredStyle: .alert)
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

    /// Presents the alert over whatever is on top (the Menu sheet) and waits until it is gone.
    /// Opening the store is `run()`'s job, never this method's. It ALWAYS returns:
    ///
    /// - No presenter, or one busy presenting or dismissing (the Menu sheet mid-animation): it
    ///   asks again `attempts` times, `retryInterval` apart, then returns `.notShown`.
    /// - UIKit refuses the presentation (the presenter left the window meanwhile): the watchdog
    ///   sees it never came up and returns `.notShown`.
    /// - The alert is taken down without a button (its presenter was dismissed): its
    ///   `viewDidDisappear`, or the watchdog, returns `.dismissed`.
    ///
    /// A button's handler runs as the alert finishes dismissing, so both disappearance paths wait
    /// `dismissalGrace` first and let a button that was chosen win.
    static func presentAlert(
        _ presentation: AppUpdatePresentation,
        findPresenter: @MainActor () -> UIViewController? = { ActivityShareSheet.topPresenter() },
        attempts: Int = 8,
        retryInterval: Duration = .milliseconds(150),
        watchdogInterval: Duration = .milliseconds(500),
        dismissalGrace: Duration = .milliseconds(500)
    ) async -> PhoneUpdateAlertOutcome {
        var presenter: UIViewController?
        for attempt in 0..<max(attempts, 1) {
            if let candidate = findPresenter(), ActivityShareSheet.canPresent(on: candidate) {
                presenter = candidate
                break
            }
            if attempt < attempts - 1 { try? await Task.sleep(for: retryInterval) }
        }
        guard let presenter else { return .notShown }

        let gate = PhoneUpdateAlertGate()
        let alert = makeAlert(presentation) { choseFirst in gate.finish(choseFirst ? .primary : .dismissed) }
        /// Gone from the screen: no longer presented, and not on its way in or out.
        let isGone = { [weak alert] in
            guard let alert else { return true }
            return alert.presentingViewController == nil && !alert.isBeingPresented && !alert.isBeingDismissed
        }
        alert.onAppear = { gate.markAppeared() }
        alert.onDisappear = {
            Task { @MainActor in
                try? await Task.sleep(for: dismissalGrace)
                if isGone() { gate.finish(.dismissed) }
            }
        }
        presenter.present(alert, animated: true)

        let watchdog = Task { @MainActor in
            while !gate.isFinished {
                try? await Task.sleep(for: watchdogInterval)
                guard !Task.isCancelled, !gate.isFinished else { return }
                if isGone() {
                    try? await Task.sleep(for: dismissalGrace)
                    guard isGone() else { continue }
                    gate.finish(gate.hasAppeared ? .dismissed : .notShown)
                }
            }
        }
        let outcome = await gate.wait()
        watchdog.cancel()
        return outcome
    }
}

/// The update alert, reporting when it appears and disappears so `presentAlert` can end its wait
/// even when no button is chosen. No stored property has a default (the UIKit-subclass rule).
final class PhoneUpdateAlertController: UIAlertController {
    var onAppear: (() -> Void)?
    var onDisappear: (() -> Void)?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        onAppear?()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        onDisappear?()
    }
}

/// Resumes `presentAlert`'s wait exactly once, with whichever ending came first.
@MainActor
private final class PhoneUpdateAlertGate {
    private var outcome: PhoneUpdateAlertOutcome?
    private var continuation: CheckedContinuation<PhoneUpdateAlertOutcome, Never>?
    private(set) var hasAppeared = false

    var isFinished: Bool { outcome != nil }

    func markAppeared() { hasAppeared = true }

    func finish(_ outcome: PhoneUpdateAlertOutcome) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        continuation?.resume(returning: outcome)
        continuation = nil
    }

    func wait() async -> PhoneUpdateAlertOutcome {
        if let outcome { return outcome }
        return await withCheckedContinuation { continuation = $0 }
    }
}
