import Foundation

/// One request to the connected AI: a system instruction and one user message.
public struct AIPrompt: Equatable, Sendable {
    let system: String
    public let user: String
}

/// Hard limits for everything sent to or read from an AI.
public enum AILimits {
    public static let maxResponseBytes = 262_144
    public static let maxProseUTF16 = 24_000
    public static let maxSegments = 400
    static let requestTimeout: TimeInterval = 60
    static let resourceTimeout: TimeInterval = 120
    static let anthropicMaxTokens = 16_000
}

public enum AIClientError: Error, Equatable {
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
    public var message: String {
        switch self {
        case .unauthorized:
            return String(localized: "The key wasn't accepted. It may have expired. Check it in Connect Your AI.", bundle: .module)
        case .modelNotFound:
            return String(localized: "The server didn't recognise the model. Enter a model name in Connect Your AI.", bundle: .module)
        case .refused:
            return String(localized: "The AI declined this request.", bundle: .module)
        case .unusableResponse:
            return String(localized: "The AI's reply couldn't be used. Nothing was changed.", bundle: .module)
        case .offline:
            return String(localized: "Couldn't reach the AI. Check your connection.", bundle: .module)
        case .connectionFailed:
            return String(localized: "Couldn't make a secure connection to the AI. Check the address in Connect Your AI.", bundle: .module)
        case .timedOut:
            return String(localized: "The AI took too long to answer.", bundle: .module)
        case .rateLimited:
            return String(localized: "The AI is busy or your usage limit was reached. Try again later.", bundle: .module)
        case .server(let status):
            return String(localized: "The AI service returned an error (\(status)).", bundle: .module)
        case .responseTooLarge:
            return String(localized: "The AI's reply was too large to use.", bundle: .module)
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

public protocol AIClient: Sendable {
    /// Returns the model's plain text reply. Never rendered as Markdown or HTML.
    func complete(_ prompt: AIPrompt) async throws -> String
}

public enum AIClientFactory {
    public static func client(for connection: AIConnection,
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
