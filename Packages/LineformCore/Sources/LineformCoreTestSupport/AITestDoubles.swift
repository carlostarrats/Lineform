import Foundation
import LineformCore

/// Keychain stand-in. Counts reads so tests can prove nothing touches secrets early.
public final class InMemoryAIKeychain: AIKeychain {
    private var keys: [AIProvider: String] = [:]
    public private(set) var readCount = 0
    public var failWrites = false

    public init() {}

    public func readKey(for provider: AIProvider) -> String? {
        readCount += 1
        return keys[provider]
    }

    /// A presence check, not a read: it never counts toward `readCount`.
    public func hasKey(for provider: AIProvider) -> Bool {
        keys[provider] != nil
    }

    @discardableResult
    public func writeKey(_ key: String, for provider: AIProvider) -> Bool {
        guard !failWrites else { return false }
        keys[provider] = key
        return true
    }

    public func deleteKey(for provider: AIProvider) {
        keys[provider] = nil
    }
}

/// Scripted transport for client tests. Records every request it is handed.
public final class FakeAITransport: AIHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private let status: Int
    private let body: Data
    private let error: Error?

    public init(status: Int = 200, body: String = "{}", error: Error? = nil) {
        self.status = status
        self.body = Data(body.utf8)
        self.error = error
    }

    public var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { recorded.append(request) }
        if let error { throw error }
        let response = HTTPURLResponse(url: request.url ?? URL(string: "http://127.0.0.1")!,
                                       statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (body, response)
    }
}

/// Serves a scripted body to a URLSession built with `protocolClasses = [StubURLProtocol.self]`.
/// Tests run serially (`-parallel-testing-enabled NO`), so the static script is safe.
public final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) public static var status = 200
    nonisolated(unsafe) public static var body = Data()
    nonisolated(unsafe) public static var declaredLength: Int?
    /// When set, the stub answers with a 302 to this URL. Every request URL is recorded.
    nonisolated(unsafe) public static var redirectTo: URL?
    nonisolated(unsafe) public static var requestedURLs: [URL] = []
    /// Every request in full (headers, method, body or body stream), alongside `requestedURLs`.
    nonisolated(unsafe) public static var requestedRequests: [URLRequest] = []
    /// The Content-Type of the scripted reply.
    nonisolated(unsafe) public static var contentType = "application/json"

    override public class func canInit(with request: URLRequest) -> Bool { true }
    override public class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override public func startLoading() {
        Self.requestedURLs.append(request.url!)
        Self.requestedRequests.append(request)
        if let target = Self.redirectTo, request.url != target {
            let redirect = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: redirect)
            // Like a real server, the 302 is also the reply if the client declines to follow it.
            client?.urlProtocol(self, didReceive: redirect, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        var headers = ["Content-Type": Self.contentType]
        if let declared = Self.declaredLength { headers["Content-Length"] = String(declared) }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override public func stopLoading() {}
}

/// Scripted AI. Records every prompt; `.suspend` waits until its task is cancelled.
public final class FakeAIClient: AIClient, @unchecked Sendable {
    public enum Behavior {
        case reply(String)
        case respond(@Sendable (AIPrompt) -> String)
        case fail(AIClientError)
        case suspend
    }

    private let lock = NSLock()
    private let behavior: Behavior
    private var recordedPrompts: [AIPrompt] = []
    private var cancellationSeen = false

    public init(_ behavior: Behavior) {
        self.behavior = behavior
    }

    public var prompts: [AIPrompt] { lock.withLock { recordedPrompts } }
    public var observedCancellation: Bool { lock.withLock { cancellationSeen } }

    public func complete(_ prompt: AIPrompt) async throws -> String {
        lock.withLock { recordedPrompts.append(prompt) }
        switch behavior {
        case .reply(let text):
            return text
        case .respond(let body):
            return body(prompt)
        case .fail(let error):
            throw error
        case .suspend:
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            } catch {
                lock.withLock { cancellationSeen = true }
                throw AIClientError.cancelled
            }
            return "{}"
        }
    }

    /// The segments the prompt carried (edit actions).
    public static func segments(in prompt: AIPrompt) -> [String] {
        let object = (try? JSONSerialization.jsonObject(with: Data(prompt.user.utf8))) as? [String: Any]
        return object?["segments"] as? [String] ?? []
    }

    /// A reply that revises every segment with `transform(index, segment)`.
    public static func revising(_ transform: @escaping @Sendable (Int, String) -> String) -> Behavior {
        .respond { prompt in
            let revised = segments(in: prompt).enumerated().map { transform($0.offset, $0.element) }
            let data = try! JSONSerialization.data(withJSONObject: ["segments": revised])
            return String(decoding: data, as: UTF8.self)
        }
    }
}

/// A seeded generator, so a randomized search is the same search on every run.
public struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
