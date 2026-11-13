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
        default: return .offline
        }
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
        self.session = URLSession(configuration: configuration)
        self.byteLimit = byteLimit
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw AIClientError.unusableResponse }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > byteLimit { throw AIClientError.responseTooLarge }
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
