import AppKit
import Foundation
import Sparkle

@MainActor
final class LineformUpdaterController {
    static let shared = LineformUpdaterController()

    private let standardUpdaterController: SPUStandardUpdaterController?

    init(bundle: Bundle = .main) {
        guard Self.hasConfiguredSparkleKeys(in: bundle) else {
            standardUpdaterController = nil
            return
        }

        standardUpdaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        guard let standardUpdaterController else {
            NSAlert.lineformUpdatesNotConfigured().runModal()
            return
        }

        standardUpdaterController.checkForUpdates(nil)
    }

    private static func hasConfiguredSparkleKeys(in bundle: Bundle) -> Bool {
        guard
            let feedURL = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            let publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        else {
            return false
        }

        return !feedURL.isEmpty
            && !feedURL.contains("$(")
            && !publicKey.isEmpty
            && !publicKey.contains("$(")
            && publicKey != "SPARKLE_PUBLIC_ED_KEY"
    }
}

private extension NSAlert {
    static func lineformUpdatesNotConfigured() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Updates are not configured for this build."
        alert.informativeText = "Release builds need a Sparkle EdDSA public key and a published appcast before Lineform can check for updates."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        return alert
    }
}
