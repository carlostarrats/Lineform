import Foundation

/// What a Check for Updates run concluded.
///
/// `failed` is deliberately distinct from `upToDate`: a lookup that learned nothing
/// (offline, captive portal, app missing from the listing) must say "couldn't check",
/// never claim the writer is current.
enum AppUpdateCheckResult: Equatable {
    case upToDate(current: String)
    case updateAvailable(current: String, latest: String, storeURL: URL)
    case failed
}

/// The store's answer for this app, after validation. `AppStoreLookup.decode` is the
/// only way to build one from bytes, so `storeURL` is always an `https` link on
/// `AppStoreLookup.allowedStoreHost` and `version` is always dotted-numeric.
struct AppStoreListing: Equatable {
    let version: String
    let storeURL: URL
}

/// Decoding + validation for the App Store lookup response, and the version decision.
///
/// The response is remote input and is treated as hostile, the same way
/// `AnnouncementFeed` treats its feed: anything too large, malformed, or carrying a
/// destination other than the App Store page produces NOTHING rather than a partial
/// answer. Foundation-only so it can move to a shared package.
enum AppStoreLookup {
    /// Hard ceiling on the response body. A one-app lookup is a few kilobytes; this is
    /// generous enough never to bite and small enough that a captive portal or a
    /// redirect to something huge can't be parsed.
    static let maximumPayloadBytes = 512 * 1024

    /// The only host the store link may point at. Compared exactly, so a look-alike
    /// such as `apps.apple.com.evil.example` is refused.
    static let allowedStoreHost = "apps.apple.com"

    static let allowedStoreScheme = "https"
    static let maximumStoreURLLength = 512

    /// Up to four dotted components of one to four ASCII digits each. Bounded before
    /// `compareVersions` converts components to `Int`. `[0-9]` rather than `\d`
    /// because ICU's `\d` also matches non-ASCII digits, and `\A`/`\z` rather than
    /// `^`/`$` because `$` also matches before a trailing newline.
    private static let versionPattern = #"\A[0-9]{1,4}(\.[0-9]{1,4}){0,3}\z"#

    private struct Payload: Decodable {
        let results: [Entry]

        struct Entry: Decodable {
            let version: String?
            let trackViewUrl: String?
        }
    }

    /// Decode and validate raw response bytes. Reads only the first result.
    ///
    /// Returns nil when the payload is unusable — too large, not JSON (an HTML sign-in
    /// page with status 200), no results, or a version or store link that breaks a rule.
    /// Never throws: the caller reports nil as "couldn't check".
    static func decode(_ data: Data) -> AppStoreListing? {
        guard data.count <= maximumPayloadBytes else { return nil }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let entry = payload.results.first,
              let version = entry.version.flatMap(validatedVersion(_:)),
              let storeURL = entry.trackViewUrl.flatMap(validatedStoreURL(_:))
        else { return nil }
        return AppStoreListing(version: version, storeURL: storeURL)
    }

    /// Decide what to tell the writer. Only a store version strictly NEWER than the
    /// running one is an update; the same or an older one (a TestFlight or freshly
    /// approved build ahead of the listing) is up to date, so a downgrade is never
    /// offered. No listing is a failure, never "up to date".
    static func result(listing: AppStoreListing?, currentVersion: String) -> AppUpdateCheckResult {
        guard let listing else { return .failed }
        if AnnouncementFeed.compareVersions(listing.version, currentVersion) == .orderedDescending {
            return .updateAvailable(current: currentVersion, latest: listing.version, storeURL: listing.storeURL)
        }
        return .upToDate(current: currentVersion)
    }

    private static func validatedVersion(_ raw: String) -> String? {
        raw.range(of: versionPattern, options: .regularExpression) != nil ? raw : nil
    }

    private static func validatedStoreURL(_ raw: String) -> URL? {
        guard raw.count <= maximumStoreURLLength,
              let url = URL(string: raw),
              url.scheme?.lowercased() == allowedStoreScheme,
              url.host == allowedStoreHost
        else { return nil }
        return url
    }
}
