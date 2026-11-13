import Foundation

protocol AIHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

enum AIURLErrorMapping {
    static func map(_ error: URLError) -> AIClientError {
        switch error.code {
        case .timedOut: return .timedOut
        case .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost:
            return .offline
        case .cancelled: return .cancelled
        // TLS failures, App Transport Security blocks, bad URLs and the like: the network may
        // be fine, so "check your connection" would mislead.
        default: return .connectionFailed
        }
    }
}

/// Refuses every redirect. A redirect could carry the API key (a custom header such as
/// `x-api-key` is not guaranteed to be dropped) to another host, or downgrade https to http.
private final class RefuseRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// The only code that talks to the network for AI. Ephemeral session: no cookies, no cache, no
/// credential storage. Reads the body as it arrives and stops the moment it passes the limit;
/// `expectedContentLength` is never trusted.
final class URLSessionAITransport: AIHTTPTransport, @unchecked Sendable {
    let sessionConfiguration: URLSessionConfiguration
    private let session: URLSession
    private let byteLimit: Int

    init(byteLimit: Int = AILimits.maxResponseBytes,
         configuration: URLSessionConfiguration = .ephemeral) {
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = AILimits.requestTimeout
        configuration.timeoutIntervalForResource = AILimits.resourceTimeout
        self.sessionConfiguration = configuration
        self.session = URLSession(configuration: configuration, delegate: RefuseRedirectDelegate(),
                                  delegateQueue: nil)
        self.byteLimit = byteLimit
    }

    deinit { session.finishTasksAndInvalidate() }

    /// Bytes read from an error reply. Enough for any status line or JSON error; a huge 401 body
    /// must not turn into `.responseTooLarge`.
    private static let errorBodyLimit = 4_096

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw AIClientError.unusableResponse }
            // A refused redirect arrives as the 3xx itself; never follow, never trust it.
            if (300..<400).contains(http.statusCode) { throw AIClientError.unusableResponse }
            let succeeded = (200..<300).contains(http.statusCode)
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if succeeded {
                    if data.count > byteLimit { throw AIClientError.responseTooLarge }
                } else if data.count >= Self.errorBodyLimit {
                    break
                }
            }
            return (data, http)
        } catch let error as AIClientError {
            throw error
        } catch is CancellationError {
            throw AIClientError.cancelled
        } catch let error as URLError {
            throw AIURLErrorMapping.map(error)
        }
    }
}
