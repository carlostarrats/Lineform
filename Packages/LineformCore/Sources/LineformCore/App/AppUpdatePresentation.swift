import Foundation

/// The alert Check for Updates shows for one `AppUpdateCheckResult`, kept out of the
/// AppKit code so it can be tested without a window. Every string is chrome and
/// localizes; "Lineform" and "App Store" stay as they are in every language.
/// Foundation-only so it can move to a shared package.
public struct AppUpdatePresentation: Equatable {
    public let title: String
    public let message: String
    public let primaryButton: String
    /// Nil when the alert has a single button.
    public let secondaryButton: String?
    /// Non-nil only for `updateAvailable`: the page the primary button opens.
    public let storeURL: URL?

    /// `bundle` selects the `.lproj` (tests pass one per language); the app uses the default, `.lineformCore`.
    public init(result: AppUpdateCheckResult, bundle: Bundle = .lineformCore) {
        switch result {
        case .upToDate(let current):
            title = String(localized: "Lineform is up to date", bundle: bundle)
            message = String(localized: "Version \(current) is the latest version.", bundle: bundle)
            primaryButton = String(localized: "OK", bundle: bundle)
            secondaryButton = nil
            storeURL = nil
        case .updateAvailable(let current, let latest, let url):
            title = String(localized: "A new version of Lineform is available", bundle: bundle)
            // Not interpolated: Swift interpolation would extract the key with bare `%@`
            // specifiers, and the catalog key is the positional form so a translation can
            // put the two versions in either order.
            message = String(
                format: String(localized: "Version %1$@ is on the App Store. You have version %2$@.", bundle: bundle),
                latest, current)
            primaryButton = String(localized: "Open App Store", bundle: bundle)
            secondaryButton = String(localized: "Not Now", bundle: bundle)
            storeURL = url
        case .failed:
            title = String(localized: "Couldn't check for updates", bundle: bundle)
            message = String(localized: "Check your internet connection and try again.", bundle: bundle)
            primaryButton = String(localized: "OK", bundle: bundle)
            secondaryButton = nil
            storeURL = nil
        }
    }
}
