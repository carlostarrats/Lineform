import Foundation

/// One request to the connected AI: a system instruction and one user message.
struct AIPrompt: Equatable {
    let system: String
    let user: String
}

/// Hard limits for everything sent to or read from an AI.
enum AILimits {
    static let maxResponseBytes = 262_144
    static let maxProseUTF16 = 24_000
    static let maxSegments = 400
    static let requestTimeout: TimeInterval = 60
    static let resourceTimeout: TimeInterval = 120
    static let anthropicMaxTokens = 16_000
}

enum AIClientError: Error, Equatable {
    case unauthorized
    case rateLimited
    case modelNotFound
    case server(status: Int)
    case timedOut
    case offline
    case connectionFailed
    case responseTooLarge
    case unusableResponse
    case refused
    case cancelled

    /// Chrome text for the failure card. Empty for `.cancelled`: the writer asked for it.
    var message: String {
        switch self {
        case .unauthorized:
            return String(localized: "The key wasn't accepted. It may have expired. Check it in Connect Your AI.")
        case .modelNotFound:
            return String(localized: "The server didn't recognise the model. Enter a model name in Connect Your AI.")
        case .refused:
            return String(localized: "The AI declined this request.")
        case .unusableResponse:
            return String(localized: "The AI's reply couldn't be used. Nothing was changed.")
        case .offline:
            return String(localized: "Couldn't reach the AI. Check your connection.")
        case .connectionFailed:
            return String(localized: "Couldn't make a secure connection to the AI. Check the address in Connect Your AI.")
        case .timedOut:
            return String(localized: "The AI took too long to answer.")
        case .rateLimited:
            return String(localized: "The AI is busy or your usage limit was reached. Try again later.")
        case .server(let status):
            return String(localized: "The AI service returned an error (\(status)).")
        case .responseTooLarge:
            return String(localized: "The AI's reply was too large to use.")
        case .cancelled:
            return ""
        }
    }

    /// Shared status mapping for both wire protocols. nil means success (2xx).
    static func forStatus(_ status: Int) -> AIClientError? {
        switch status {
        case 200..<300: return nil
        case 401, 403: return .unauthorized
        case 404: return .modelNotFound
        case 429: return .rateLimited
        default: return .server(status: status)
        }
    }
}

protocol AIClient: Sendable {
    /// Returns the model's plain text reply. Never rendered as Markdown or HTML.
    func complete(_ prompt: AIPrompt) async throws -> String
}

enum AIClientFactory {
    static func client(for connection: AIConnection,
                       transport: AIHTTPTransport = URLSessionAITransport()) -> AIClient {
        switch connection.provider.wireProtocol {
        case .anthropicMessages:
            return AnthropicMessagesClient(connection: connection, transport: transport)
        case .openAIChatCompletions:
            return OpenAICompatibleClient(connection: connection, transport: transport)
        }
    }
}

/// Sends a built request through a transport and applies the status mapping. Shared by both clients.
func aiSend(_ request: URLRequest, via transport: AIHTTPTransport) async throws -> Data {
    let data: Data
    let response: HTTPURLResponse
    do {
        (data, response) = try await transport.send(request)
    } catch let error as AIClientError {
        throw error
    } catch is CancellationError {
        throw AIClientError.cancelled
    } catch let error as URLError {
        throw AIURLErrorMapping.map(error)
    } catch {
        throw AIClientError.unusableResponse
    }
    if let failure = AIClientError.forStatus(response.statusCode) { throw failure }
    return data
}
