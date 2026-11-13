import Foundation

/// Claude over the Anthropic Messages API. Plain HTTP: there is no Swift SDK. Deliberately sends
/// no `thinking` and no sampling parameters (Sonnet 5.5 rejects `temperature`; thinking defaults
/// to adaptive and `effort: low` keeps edits quick).
struct AnthropicMessagesClient: AIClient {
    let connection: AIConnection
    let transport: AIHTTPTransport

    init(connection: AIConnection, transport: AIHTTPTransport) {
        self.connection = connection
        self.transport = transport
    }

    private struct Body: Encodable {
        struct Message: Encodable { let role: String; let content: String }
        struct OutputConfig: Encodable { let effort: String }
        let model: String
        let max_tokens: Int
        let system: String
        let messages: [Message]
        let output_config: OutputConfig
    }

    private struct Reply: Decodable {
        struct Block: Decodable { let type: String; let text: String? }
        let stop_reason: String?
        let content: [Block]
    }

    func makeRequest(_ prompt: AIPrompt) throws -> URLRequest {
        var request = URLRequest(url: connection.endpoint)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(AIProvider.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        if let key = connection.apiKey, !key.isEmpty {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
        }
        request.httpBody = try JSONEncoder().encode(Body(
            model: connection.model,
            max_tokens: AILimits.anthropicMaxTokens,
            system: prompt.system,
            messages: [.init(role: "user", content: prompt.user)],
            output_config: .init(effort: "low")))
        return request
    }

    func complete(_ prompt: AIPrompt) async throws -> String {
        let request: URLRequest
        do { request = try makeRequest(prompt) } catch { throw AIClientError.unusableResponse }
        let data = try await aiSend(request, via: transport)
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            throw AIClientError.unusableResponse
        }
        switch reply.stop_reason {
        case "refusal": throw AIClientError.refused
        case "max_tokens": throw AIClientError.unusableResponse
        default: break
        }
        let text = reply.content.filter { $0.type == "text" }.compactMap(\.text).joined()
        guard !text.isEmpty else { throw AIClientError.unusableResponse }
        return text
    }
}
