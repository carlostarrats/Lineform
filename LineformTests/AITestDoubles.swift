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

/// Scripted AI. Records every prompt; `.suspend` waits until its task is cancelled.
final class FakeAIClient: AIClient, @unchecked Sendable {
    enum Behavior {
        case reply(String)
        case respond(@Sendable (AIPrompt) -> String)
        case fail(AIClientError)
        case suspend
    }

    private let lock = NSLock()
    private let behavior: Behavior
    private var recordedPrompts: [AIPrompt] = []
    private var cancellationSeen = false

    init(_ behavior: Behavior) {
        self.behavior = behavior
    }

    var prompts: [AIPrompt] { lock.withLock { recordedPrompts } }
    var observedCancellation: Bool { lock.withLock { cancellationSeen } }

    func complete(_ prompt: AIPrompt) async throws -> String {
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
    static func segments(in prompt: AIPrompt) -> [String] {
        let object = (try? JSONSerialization.jsonObject(with: Data(prompt.user.utf8))) as? [String: Any]
        return object?["segments"] as? [String] ?? []
    }

    /// A reply that revises every segment with `transform(index, segment)`.
    static func revising(_ transform: @escaping @Sendable (Int, String) -> String) -> Behavior {
        .respond { prompt in
            let revised = segments(in: prompt).enumerated().map { transform($0.offset, $0.element) }
            let data = try! JSONSerialization.data(withJSONObject: ["segments": revised])
            return String(decoding: data, as: UTF8.self)
        }
    }
}

/// The editor as the AI controller sees it. Applies edits the way the text view does: each edit
/// is reported to History in pre-change coordinates (`shouldChangeText`), then lands.
@MainActor
final class FakeAIEditorSurface: AIEditorSurface {
    var string: String
    weak var history: DocumentHistoryController?
    private(set) var editCalls: [(edits: [AIReviewEdit], actionName: String)] = []
    private(set) var typed: [String] = []
    private(set) var announcements: [String] = []
    /// Every `collapseSelectionAfterAIReview` location, in order.
    private(set) var collapsedSelections: [Int] = []
    /// When set, edits whose index in a call is listed are skipped (as the text view skips an
    /// edit that would split a character or touch structure), and the call reports false.
    var skippedEditIndices: Set<Int> = []

    init(_ string: String) {
        self.string = string
    }

    @discardableResult
    func applyAIEdits(_ edits: [AIReviewEdit], actionName: String) -> Bool {
        editCalls.append((edits, actionName))
        let text = NSMutableString(string: string)
        var appliedAll = true
        for (index, edit) in edits.enumerated() {
            guard !skippedEditIndices.contains(index) else {
                appliedAll = false
                continue
            }
            history?.noteUserEdit(edit.range, replacement: edit.replacement)
            text.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        string = text as String
        return appliedAll
    }

    func collapseSelectionAfterAIReview(at location: Int) {
        collapsedSelections.append(location)
    }

    func insertTypedText(_ text: String) {
        typed.append(text)
    }

    func announceAI(_ message: String) {
        announcements.append(message)
    }
}

/// A seeded generator, so a randomized search is the same search on every run.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
