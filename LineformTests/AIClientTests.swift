import XCTest
@testable import Lineform

final class AIClientTests: XCTestCase {
    private let prompt = AIPrompt(system: "be brief", user: "hello")

    private func connection(_ provider: AIProvider, key: String? = "k",
                            endpoint: URL? = nil, model: String? = nil) -> AIConnection {
        AIConnection(provider: provider,
                     endpoint: endpoint ?? provider.endpoint ?? URL(string: "http://127.0.0.1:8765/v1/chat/completions")!,
                     model: model ?? provider.defaultModel ?? "default", apiKey: key)
    }

    private func json(_ request: URLRequest) throws -> [String: Any] {
        let body = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    func testAnthropicRequestShape() async throws {
        let transport = FakeAITransport(body: #"{"stop_reason":"end_turn","content":[{"type":"text","text":"hi"}]}"#)
        let client = AnthropicMessagesClient(connection: connection(.claude), transport: transport)
        let text = try await client.complete(prompt)
        XCTAssertEqual(text, "hi")
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "k")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2026-10-21")
        XCTAssertEqual(request.value(forHTTPHeaderField: "content-type"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try json(request)
        XCTAssertEqual(body["model"] as? String, "claude-sonnet-5-5")
        XCTAssertEqual(body["max_tokens"] as? Int, 16_000)
        XCTAssertEqual(body["system"] as? String, "be brief")
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        XCTAssertEqual(messages[0]["content"] as? String, "hello")
        XCTAssertEqual((body["output_config"] as? [String: Any])?["effort"] as? String, "low")
        XCTAssertNil(body["thinking"])
        XCTAssertNil(body["temperature"])
    }

    func testAnthropicJoinsTextBlocksAndIgnoresThinking() async throws {
        let transport = FakeAITransport(body: #"{"stop_reason":"end_turn","content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"a"},{"type":"text","text":"b"}]}"#)
        let client = AnthropicMessagesClient(connection: connection(.claude), transport: transport)
        let text = try await client.complete(prompt)
        XCTAssertEqual(text, "ab")
    }

    func testAnthropicRefusalStopReason() async {
        let transport = FakeAITransport(body: #"{"stop_reason":"refusal","content":[]}"#)
        let client = AnthropicMessagesClient(connection: connection(.claude), transport: transport)
        do {
            _ = try await client.complete(prompt)
            XCTFail("expected refusal")
        } catch {
            XCTAssertEqual(error as? AIClientError, .refused)
        }
        let truncated = FakeAITransport(body: #"{"stop_reason":"max_tokens","content":[{"type":"text","text":"cut"}]}"#)
        do {
            _ = try await AnthropicMessagesClient(connection: connection(.claude), transport: truncated).complete(prompt)
            XCTFail("expected unusable")
        } catch {
            XCTAssertEqual(error as? AIClientError, .unusableResponse)
        }
    }

    func testOpenAICompatibleRequestShapeForEachProvider() async throws {
        for provider in [AIProvider.chatGPT, .google] {
            let transport = FakeAITransport(body: #"{"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}]}"#)
            _ = try await OpenAICompatibleClient(connection: connection(provider), transport: transport).complete(prompt)
            let request = try XCTUnwrap(transport.requests.first)
            XCTAssertEqual(request.url, provider.endpoint)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer k")
            XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
            let body = try json(request)
            XCTAssertEqual(body["model"] as? String, provider.defaultModel)
            let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
            XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "user"])
            XCTAssertEqual(messages.map { $0["content"] as? String }, ["be brief", "hello"])
        }
        let transport = FakeAITransport(body: #"{"choices":[{"message":{"content":"ok"}}]}"#)
        _ = try await OpenAICompatibleClient(connection: connection(.other, key: nil), transport: transport).complete(prompt)
        XCTAssertNil(transport.requests.first?.value(forHTTPHeaderField: "Authorization"))
        let empty = FakeAITransport(body: #"{"choices":[{"message":{"content":"ok"}}]}"#)
        _ = try await OpenAICompatibleClient(connection: connection(.other, key: ""), transport: empty).complete(prompt)
        XCTAssertNil(empty.requests.first?.value(forHTTPHeaderField: "Authorization"))
    }

    func testOpenAICompatibleParsesFirstChoice() async throws {
        let transport = FakeAITransport(body: #"{"choices":[{"message":{"content":"first"},"finish_reason":"stop"},{"message":{"content":"second"}}]}"#)
        let text = try await OpenAICompatibleClient(connection: connection(.chatGPT), transport: transport).complete(prompt)
        XCTAssertEqual(text, "first")
        let length = FakeAITransport(body: #"{"choices":[{"message":{"content":"cut"},"finish_reason":"length"}]}"#)
        do {
            _ = try await OpenAICompatibleClient(connection: connection(.chatGPT), transport: length).complete(prompt)
            XCTFail("expected unusable")
        } catch { XCTAssertEqual(error as? AIClientError, .unusableResponse) }
        let filtered = FakeAITransport(body: #"{"choices":[{"message":{"content":""},"finish_reason":"content_filter"}]}"#)
        do {
            _ = try await OpenAICompatibleClient(connection: connection(.chatGPT), transport: filtered).complete(prompt)
            XCTFail("expected refusal")
        } catch { XCTAssertEqual(error as? AIClientError, .refused) }
        let junk = FakeAITransport(body: "not json")
        do {
            _ = try await OpenAICompatibleClient(connection: connection(.chatGPT), transport: junk).complete(prompt)
            XCTFail("expected unusable")
        } catch { XCTAssertEqual(error as? AIClientError, .unusableResponse) }
    }

    func testStatusCodesMapToErrors() async {
        let expectations: [(Int, AIClientError)] = [
            (401, .unauthorized), (403, .unauthorized), (404, .modelNotFound),
            (429, .rateLimited), (500, .server(status: 500)),
        ]
        for (status, expected) in expectations {
            for provider in [AIProvider.claude, .chatGPT] {
                let transport = FakeAITransport(status: status, body: #"{"error":"x"}"#)
                let client = AIClientFactory.client(for: connection(provider), transport: transport)
                do {
                    _ = try await client.complete(prompt)
                    XCTFail("expected \(expected)")
                } catch {
                    XCTAssertEqual(error as? AIClientError, expected, "\(provider) \(status)")
                }
            }
        }
    }

    func testFactoryPicksClientByWireProtocol() {
        XCTAssertTrue(AIClientFactory.client(for: connection(.claude), transport: FakeAITransport()) is AnthropicMessagesClient)
        for provider in [AIProvider.chatGPT, .google, .other] {
            XCTAssertTrue(AIClientFactory.client(for: connection(provider), transport: FakeAITransport()) is OpenAICompatibleClient)
        }
    }

    private func stubbedTransport(byteLimit: Int) -> URLSessionAITransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSessionAITransport(byteLimit: byteLimit, configuration: configuration)
    }

    func testTransportAbortsPastByteLimit() async throws {
        StubURLProtocol.status = 200
        StubURLProtocol.declaredLength = 10   // a lying Content-Length must not be trusted
        StubURLProtocol.body = Data(repeating: 0x61, count: 1025)
        defer { StubURLProtocol.declaredLength = nil }
        let transport = stubbedTransport(byteLimit: 1024)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:1/x")!)
        request.httpMethod = "POST"
        do {
            _ = try await transport.send(request)
            XCTFail("expected responseTooLarge")
        } catch {
            XCTAssertEqual(error as? AIClientError, .responseTooLarge)
        }
        StubURLProtocol.body = Data(repeating: 0x61, count: 1024)
        let (data, response) = try await transport.send(request)
        XCTAssertEqual(data.count, 1024)
        XCTAssertEqual(response.statusCode, 200)
    }

    func testTransportSendsNoCookies() throws {
        let transport = URLSessionAITransport()
        let configuration = transport.sessionConfiguration
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCache)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, AILimits.requestTimeout)
        XCTAssertEqual(configuration.timeoutIntervalForResource, AILimits.resourceTimeout)
        let fake = FakeAITransport(body: #"{"choices":[{"message":{"content":"ok"}}]}"#)
        let request = try OpenAICompatibleClient(connection: connection(.chatGPT), transport: fake).makeRequest(prompt)
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertFalse(request.httpShouldHandleCookies)
    }

    func testErrorMessagesAreNonEmptyExceptCancelled() {
        let all: [AIClientError] = [.unauthorized, .rateLimited, .modelNotFound, .server(status: 502),
                                    .timedOut, .offline, .connectionFailed, .responseTooLarge, .unusableResponse, .refused]
        for error in all { XCTAssertFalse(error.message.isEmpty) }
        XCTAssertTrue(AIClientError.server(status: 502).message.contains("502"))
        XCTAssertEqual(AIClientError.cancelled.message, "")
    }

    func testTransportRefusesRedirects() async {
        StubURLProtocol.status = 200
        StubURLProtocol.body = Data("{}".utf8)
        let target = URL(string: "http://127.0.0.1:2/elsewhere")!
        StubURLProtocol.redirectTo = target
        StubURLProtocol.requestedURLs = []
        defer { StubURLProtocol.redirectTo = nil }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:1/x")!)
        request.httpMethod = "POST"
        request.setValue("secret", forHTTPHeaderField: "x-api-key")
        do {
            _ = try await stubbedTransport(byteLimit: 1024).send(request)
            XCTFail("expected the redirect to be refused")
        } catch {
            XCTAssertEqual(error as? AIClientError, .unusableResponse)
        }
        XCTAssertFalse(StubURLProtocol.requestedURLs.contains(target), "the redirect target was requested")
    }

    func testLargeErrorBodyStillMapsByStatus() async throws {
        StubURLProtocol.status = 401
        StubURLProtocol.body = Data(repeating: 0x61, count: 5_000)
        let transport = stubbedTransport(byteLimit: 1024)
        let client = OpenAICompatibleClient(connection: connection(.chatGPT), transport: transport)
        do {
            _ = try await client.complete(prompt)
            XCTFail("expected unauthorized")
        } catch {
            XCTAssertEqual(error as? AIClientError, .unauthorized)
        }
        StubURLProtocol.status = 200
    }

    func testURLErrorsMapToAccurateCases() async {
        XCTAssertEqual(AIURLErrorMapping.map(URLError(.timedOut)), .timedOut)
        for code in [URLError.Code.notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost] {
            XCTAssertEqual(AIURLErrorMapping.map(URLError(code)), .offline, "\(code)")
        }
        XCTAssertEqual(AIURLErrorMapping.map(URLError(.cancelled)), .cancelled)
        for code in [URLError.Code.secureConnectionFailed, .serverCertificateUntrusted, .appTransportSecurityRequiresSecureConnection, .badURL] {
            XCTAssertEqual(AIURLErrorMapping.map(URLError(code)), .connectionFailed, "\(code)")
        }
        // The same mapping applies to errors thrown by any transport, through the client.
        let cases: [(Error, AIClientError)] = [
            (URLError(.timedOut), .timedOut), (URLError(.notConnectedToInternet), .offline),
            (URLError(.secureConnectionFailed), .connectionFailed), (CancellationError(), .cancelled),
            (AIClientError.responseTooLarge, .responseTooLarge),
        ]
        for (thrown, expected) in cases {
            let client = OpenAICompatibleClient(connection: connection(.chatGPT), transport: FakeAITransport(error: thrown))
            do {
                _ = try await client.complete(prompt)
                XCTFail("expected \(expected)")
            } catch {
                XCTAssertEqual(error as? AIClientError, expected)
            }
        }
    }

    func testOpenAICompatibleMessageRefusalIsRefused() async {
        let transport = FakeAITransport(body: #"{"choices":[{"message":{"content":null,"refusal":"I can't help with that."},"finish_reason":"stop"}]}"#)
        do {
            _ = try await OpenAICompatibleClient(connection: connection(.chatGPT), transport: transport).complete(prompt)
            XCTFail("expected refusal")
        } catch { XCTAssertEqual(error as? AIClientError, .refused) }
    }

    func testAnthropicOptsIntoServerSideFallback() async throws {
        let transport = FakeAITransport(body: #"{"stop_reason":"end_turn","content":[{"type":"fallback","model":"claude-sonnet-5"},{"type":"text","text":"ok"}]}"#)
        let text = try await AnthropicMessagesClient(connection: connection(.claude), transport: transport).complete(prompt)
        XCTAssertEqual(text, "ok")
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "server-side-fallback-2026-07-01")
        XCTAssertEqual(try json(request)["fallbacks"] as? String, "default")
    }
}
