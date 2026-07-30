import Foundation

/// Fetches the raw announcement feed. Behind a protocol so `AnnouncementStore` is
/// testable without touching the network — no test in either plan may make a real
/// request.
protocol AnnouncementFetching: Sendable {
    /// Returns validated announcements, or **nil** when nothing could be learned —
    /// offline, timeout, bad status, unusable payload. An empty ARRAY is different: it
    /// means the feed was read successfully and the publisher is showing nothing.
    /// The caller must not treat a failed check as a retraction.
    ///
    /// Never throws: the caller has no failure UI, by design. Offline is the common
    /// case, not an error.
    func fetch() async -> [Announcement]?
}

/// The one network call in the app that isn't Sparkle.
///
/// Privacy shape, which is the point of the feature: a plain GET of a static file.
/// No request body, no query string, no custom headers, no cookies, no credentials,
/// no identifiers of any kind. Nothing distinguishes one user's request from another's
/// beyond what any web request unavoidably carries. Because there is nothing to
/// collect, the App Privacy label stays "Data Not Collected".
struct AnnouncementFetcher: AnnouncementFetching {
    /// The static feed, served next to the marketing site's `index.html`.
    static let defaultFeedURL = URL(string: "https://lineform-site.vercel.app/announcements.json")!

    /// Short enough that a hung or throttled server never keeps a background task
    /// alive behind the user; there is no retry, the next launch is the retry.
    static let timeout: TimeInterval = 10

    private let feedURL: URL
    private let session: URLSession

    init(feedURL: URL = AnnouncementFetcher.defaultFeedURL, session: URLSession? = nil) {
        self.feedURL = feedURL
        self.session = session ?? Self.makeSession()
    }

    /// Ephemeral configuration: no cookie storage, no credential storage, no on-disk
    /// cache. Nothing about this request survives the process, so there is no local
    /// artifact tying the user to a check.
    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.allowsCellularAccess = true
        return URLSession(configuration: configuration)
    }

    func fetch() async -> [Announcement]? {
        #if DEBUG
        // QA seam (Debug only, same family as LINEFORM_DUMP_MAIN_MENU): inject feed JSON
        // straight from the environment so the card can be exercised in a real window
        // without a deployed feed or any network access. Compiled out of Release, so it
        // cannot become a way to put arbitrary content in a shipping build.
        if let injected = ProcessInfo.processInfo.environment["LINEFORM_ANNOUNCEMENT_FEED_JSON"] {
            return AnnouncementFeed.decode(Data(injected.utf8))
        }
        #endif

        guard let data = await fetchBody() else { return nil }
        return AnnouncementFeed.decode(data)
    }

    /// Stream the response and abort the moment it exceeds the payload ceiling, rather
    /// than buffering whatever arrives and checking the size afterwards. `expectedContentLength`
    /// is server-supplied and therefore untrusted — a hostile or misconfigured host can
    /// understate it — so the real defence is counting the bytes as they land.
    private func fetchBody() async -> Data? {
        var request = URLRequest(url: feedURL)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (stream, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }

            // A feed that isn't JSON is a misconfigured host or a captive portal's
            // interception page — decode would fail anyway, but refusing early means
            // an HTML login page never gets buffered at all.
            let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            guard contentType.contains("application/json") else { return nil }

            var data = Data()
            data.reserveCapacity(min(AnnouncementFeed.maximumPayloadBytes, 4096))
            for try await byte in stream {
                data.append(byte)
                if data.count > AnnouncementFeed.maximumPayloadBytes { return nil }
            }
            return data
        } catch {
            // Offline, DNS failure, timeout, TLS failure, cancellation. All the same
            // outcome: no announcement this launch, nothing surfaced to the user.
            return nil
        }
    }
}
