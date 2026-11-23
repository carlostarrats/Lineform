import Foundation

/// What a Check for Updates run concluded.
///
/// `failed` is deliberately distinct from `upToDate`: a lookup that learned nothing
/// (offline, captive portal, app missing from the listing) must say "couldn't check",
/// never claim the writer is current.
public enum AppUpdateCheckResult: Equatable, Sendable {
    case upToDate(current: String)
    case updateAvailable(current: String, latest: String, storeURL: URL)
    case failed
}

/// Which App Store catalog a Check for Updates reads. The Mac and the iPhone share ONE listing
/// (the same bundle id, `com.lineform.app`), but the iTunes lookup answers per platform: the
/// Mac's entry has `kind` "mac-software", the iPhone's `kind` "software".
public enum AppStorePlatform: Equatable, Sendable {
    case mac
    case iPhone

    /// The platform this build runs on.
    public static var current: AppStorePlatform {
        #if os(iOS)
        .iPhone
        #else
        .mac
        #endif
    }

    /// The lookup's `entity`: `macSoftware` for the Mac catalog, `software` for the iOS one.
    var lookupEntity: String {
        switch self {
        case .mac: "macSoftware"
        case .iPhone: "software"
        }
    }

    /// Whether an entry with this `kind` is this platform's. The Mac also reads an entry with no
    /// `kind` (what it always read). The iPhone reads only "software": before an iPhone build is
    /// listed, the store answers the iOS lookup with the Mac entry (seen by hand on 2026-11-23),
    /// and reading that would offer a Mac-only version and open the Mac page.
    func accepts(kind: String?) -> Bool {
        switch self {
        case .mac: kind == nil || kind == "mac-software"
        case .iPhone: kind == "software"
        }
    }
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
            let kind: String?
            let version: String?
            let trackViewUrl: String?
        }
    }

    /// Decode and validate raw response bytes. Reads only the first result that is
    /// `platform`'s (`AppStorePlatform.accepts(kind:)`); for the Mac's lookup that is the first
    /// result, as it always was.
    ///
    /// Returns nil when the payload is unusable — too large, not JSON (an HTML sign-in
    /// page with status 200), no result for `platform`, or a version or store link that
    /// breaks a rule. Never throws: the caller reports nil as "couldn't check".
    static func decode(_ data: Data, platform: AppStorePlatform) -> AppStoreListing? {
        guard data.count <= maximumPayloadBytes else { return nil }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let entry = payload.results.first(where: { platform.accepts(kind: $0.kind) }),
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
              url.host == allowedStoreHost,
              url.port == nil,
              url.user == nil,
              url.password == nil
        else { return nil }
        return url
    }
}

/// Runs one Check for Updates lookup. Behind a protocol so the command is testable
/// without touching the network — no test may make a real request.
public protocol AppUpdateChecking: Sendable {
    /// Never throws: every failure (offline, timeout, bad status, captive portal, unusable
    /// payload, app missing from the listing) is `.failed`, reported as "couldn't check".
    func check(currentVersion: String) async -> AppUpdateCheckResult
}

/// Asks Apple's public lookup for this app's current App Store version. Runs only when
/// the writer chooses Check for Updates — never at launch, never on a timer.
///
/// Privacy shape, the same as `AnnouncementFetcher`: a plain GET with no body, no
/// cookies, no credentials, and no identifiers. The only query is the app's own public
/// bundle id (and the platform's catalog). The request adds no locale or country parameter of
/// its own (URLSession still sends its standard User-Agent and Accept-Language headers,
/// as for the announcement check).
public struct AppStoreUpdateChecker: AppUpdateChecking {
    /// The Release bundle id, fixed. Never `Bundle.main.bundleIdentifier`: Debug builds
    /// are `com.lineform.app.debug`, which has no store listing.
    static let storeBundleID = "com.lineform.app"

    static let timeout: TimeInterval = 10

    /// The lookup for `platform`'s catalog. Checked by hand on 2026-11-18: the Mac's form
    /// (`entity=macSoftware`) returns `resultCount` 1, `kind` "mac-software", version 1.8.0, and
    /// a `trackViewUrl` on apps.apple.com — the Mac listing. The iPhone's form is
    /// `entity=software`, the iOS catalog; on 2026-11-23, before any iPhone build was listed, it
    /// still answered with the Mac entry, which the iPhone refuses (`AppStorePlatform.accepts`).
    public static func lookupURL(for platform: AppStorePlatform) -> URL {
        URL(string: "https://itunes.apple.com/lookup?bundleId=\(storeBundleID)&entity=\(platform.lookupEntity)")!
    }

    /// The lookup for the platform this build runs on.
    public static var lookupURL: URL { lookupURL(for: .current) }

    private let platform: AppStorePlatform
    private let session: URLSession

    public init(platform: AppStorePlatform = .current, session: URLSession? = nil) {
        self.platform = platform
        self.session = session ?? URLSession(configuration: Self.makeConfiguration())
    }

    /// The configuration actually in use, for tests.
    var sessionConfiguration: URLSessionConfiguration { session.configuration }

    /// Ephemeral configuration: no cookie storage survives, cookies are neither sent nor
    /// accepted, no on-disk cache. Exposed so tests can run the shipping configuration
    /// over a stub transport.
    static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.allowsCellularAccess = true
        return configuration
    }

    public func check(currentVersion: String) async -> AppUpdateCheckResult {
        let listing = await fetchBody().flatMap { AppStoreLookup.decode($0, platform: platform) }
        return AppStoreLookup.result(listing: listing, currentVersion: currentVersion)
    }

    /// Stream the response and abort the moment it exceeds the payload ceiling. The size
    /// is counted as bytes arrive, never taken from `expectedContentLength`, which is
    /// server-supplied and untrusted.
    private func fetchBody() async -> Data? {
        var request = URLRequest(url: Self.lookupURL(for: platform))
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (stream, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }

            // Apple serves this endpoint as `text/javascript; charset=utf-8` (seen by hand
            // on 2026-11-18), so accept JSON or JavaScript. Anything else — a captive
            // portal's HTML page with status 200 — is refused before it is buffered.
            let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            guard contentType.contains("json") || contentType.contains("javascript") else { return nil }

            var data = Data()
            data.reserveCapacity(min(AppStoreLookup.maximumPayloadBytes, 16 * 1024))
            for try await byte in stream {
                data.append(byte)
                if data.count > AppStoreLookup.maximumPayloadBytes { return nil }
            }
            return data
        } catch {
            // Offline, DNS failure, timeout, TLS failure, cancellation: all "couldn't check".
            return nil
        }
    }
}
