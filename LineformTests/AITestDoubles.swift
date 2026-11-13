import Foundation
@testable import Lineform

/// Keychain stand-in. Counts reads so tests can prove nothing touches secrets early.
final class InMemoryAIKeychain: AIKeychain {
    private var keys: [AIProvider: String] = [:]
    private(set) var readCount = 0
    var failWrites = false

    func readKey(for provider: AIProvider) -> String? {
        readCount += 1
        return keys[provider]
    }

    /// A presence check, not a read: it never counts toward `readCount`.
    func hasKey(for provider: AIProvider) -> Bool {
        keys[provider] != nil
    }

    @discardableResult
    func writeKey(_ key: String, for provider: AIProvider) -> Bool {
        guard !failWrites else { return false }
        keys[provider] = key
        return true
    }

    func deleteKey(for provider: AIProvider) {
        keys[provider] = nil
    }
}

/// Scripted transport for client tests. Records every request it is handed.
final class FakeAITransport: AIHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private let status: Int
    private let body: Data
    private let error: Error?

    init(status: Int = 200, body: String = "{}", error: Error? = nil) {
        self.status = status
        self.body = Data(body.utf8)
        self.error = error
    }

    var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { recorded.append(request) }
        if let error { throw error }
        let response = HTTPURLResponse(url: request.url ?? URL(string: "http://127.0.0.1")!,
                                       statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (body, response)
    }
}

/// Serves a scripted body to a URLSession built with `protocolClasses = [StubURLProtocol.self]`.
/// Tests run serially (`-parallel-testing-enabled NO`), so the static script is safe.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var declaredLength: Int?
    /// When set, the stub answers with a 302 to this URL. Every request URL is recorded.
    nonisolated(unsafe) static var redirectTo: URL?
    nonisolated(unsafe) static var requestedURLs: [URL] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestedURLs.append(request.url!)
        if let target = Self.redirectTo, request.url != target {
            let redirect = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: redirect)
            // Like a real server, the 302 is also the reply if the client declines to follow it.
            client?.urlProtocol(self, didReceive: redirect, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        var headers = ["Content-Type": "application/json"]
        if let declared = Self.declaredLength { headers["Content-Length"] = String(declared) }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
