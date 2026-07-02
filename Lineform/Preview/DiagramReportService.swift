import Foundation

/// URL scheme for the "Report this" link embedded in a mermaid fallback block.
enum DiagramReportLink {
    static let scheme = "lineform-report"
    static func url(hash: String) -> URL? { URL(string: "\(scheme):\(hash)") }
    static func hash(from url: URL) -> String? {
        guard url.scheme == scheme else { return nil }
        let full = url.absoluteString
        guard let colon = full.firstIndex(of: ":") else { return nil }
        return String(full[full.index(after: colon)...])
    }
}

/// Maps a fallback block's source hash to the data needed to report it, so a "Report this" click
/// can recover the exact source + error without embedding them in the link.
final class DiagramReportRegistry {
    private var pending: [String: (source: String, error: String)] = [:]
    func register(hash: String, source: String, error: String) { pending[hash] = (source, error) }
    func report(for hash: String) -> (source: String, error: String)? { pending[hash] }
    func reset() { pending.removeAll() }
}

/// Builds and sends the user-initiated diagram failure report. The payload is EXACTLY three
/// fields — `source`, `error`, `appVersion` — nothing else (no identifiers, file names, or paths).
enum DiagramReportService {
    /// The Cloudflare Worker endpoint.
    ///
    /// NOTE (maintainer): set this to the deployed Worker URL once a workers.dev subdomain is
    /// registered — e.g. `https://lineform-diagram-report.<subdomain>.workers.dev`. Until it is a
    /// reachable endpoint, reports fail closed and the app shows "Couldn't send. Saved locally."
    static let endpoint = "https://lineform-diagram-report.lineform.workers.dev"

    /// The exact wire payload. Kept a pure function so a test can assert the field set.
    static func payload(source: String, error: String, appVersion: String) -> [String: String] {
        ["source": source, "error": error, "appVersion": appVersion]
    }

    enum SendResult {
        case sent
        case failed
    }

    /// POST the report. Returns `.sent` on a 2xx response, `.failed` otherwise (including any
    /// networking error) — the caller then reassures the user the report is still in the local log.
    static func send(source: String, error: String, appVersion: String) async -> SendResult {
        guard let url = URL(string: endpoint) else { return .failed }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload(source: source, error: error, appVersion: appVersion))

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                return .sent
            }
            return .failed
        } catch {
            return .failed
        }
    }
}
