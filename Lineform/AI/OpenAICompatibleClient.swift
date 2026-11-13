import Foundation

/// ChatGPT, Google (OpenAI-compatible endpoint) and any "Other" chat-completions server.
struct OpenAICompatibleClient: AIClient {
    let connection: AIConnection
    let transport: AIHTTPTransport

    init(connection: AIConnection, transport: AIHTTPTransport) {
        self.connection = connection
        self.transport = transport
    }

    private struct Body: Encodable {
        struct Message: Encodable { let role: String; let content: String }
        let model: String
        let messages: [Message]
    }

    private struct Reply: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message?
            let finish_reason: String?
        }
        let choices: [Choice]
    }

    func makeRequest(_ prompt: AIPrompt) throws -> URLRequest {
        var request = URLRequest(url: connection.endpoint)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if let key = connection.apiKey, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(Body(
            model: connection.model,
            messages: [.init(role: "system", content: prompt.system),
                       .init(role: "user", content: prompt.user)]))
        return request
    }

    func complete(_ prompt: AIPrompt) async throws -> String {
        let request: URLRequest
        do { request = try makeRequest(prompt) } catch { throw AIClientError.unusableResponse }
        let data = try await aiSend(request, via: transport)
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data),
              let choice = reply.choices.first else {
            throw AIClientError.unusableResponse
        }
        switch choice.finish_reason {
        case "length": throw AIClientError.unusableResponse
        case "content_filter": throw AIClientError.refused
        default: break
        }
        guard let text = choice.message?.content, !text.isEmpty else {
            throw AIClientError.unusableResponse
        }
        return text
    }
}
