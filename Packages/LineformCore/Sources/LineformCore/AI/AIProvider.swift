import Foundation

/// How a provider's request and response are shaped on the wire.
enum AIWireProtocol: Equatable {
    case anthropicMessages
    case openAIChatCompletions
}

/// The four ways a writer can connect an AI. The raw values are persisted identity
/// (UserDefaults, Keychain account names) and are never localized.
public enum AIProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case claude
    case chatGPT = "chatgpt"
    case google
    case other

    public var id: String { rawValue }

    /// Brand names are not translated; only "Other" is.
    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .chatGPT: return "ChatGPT"
        case .google: return "Google"
        case .other: return String(localized: "Other", bundle: .module)
        }
    }

    var companyName: String? {
        switch self {
        case .claude: return "Anthropic"
        case .chatGPT: return "OpenAI"
        case .google: return "Google"
        case .other: return nil
        }
    }

    public var createKeyURL: URL? {
        switch self {
        case .claude: return URL(string: "https://platform.claude.com/settings/keys")
        case .chatGPT: return URL(string: "https://platform.openai.com/api-keys")
        case .google: return URL(string: "https://aistudio.google.com/apikey")
        case .other: return nil
        }
    }

    /// `anthropic-version` header value sent with every Claude request (claude-api skill,
    /// API version 2026-10-21).
    static let anthropicVersion = "2026-10-21"

    var endpoint: URL? {
        switch self {
        case .claude: return URL(string: "https://api.anthropic.com/v1/messages")
        case .chatGPT: return URL(string: "https://api.openai.com/v1/chat/completions")
        case .google: return URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")
        case .other: return nil
        }
    }

    /// The model each tier sends. Verified 2026-11-13 against the providers' own model lists:
    /// both OpenAI models support `v1/chat/completions`, and the Gemini IDs are the stable
    /// codes on Google's model page (used through its OpenAI-compatible endpoint).
    public func model(for tier: AIModelTier) -> String? {
        switch (self, tier) {
        case (.claude, .standard): return "claude-haiku-5-5"
        case (.claude, .higherQuality): return "claude-sonnet-5-5"
        case (.chatGPT, .standard): return "gpt-6-luna"
        case (.chatGPT, .higherQuality): return "gpt-6.1-terra"
        case (.google, .standard): return "gemini-3.5-flash-lite"
        case (.google, .higherQuality): return "gemini-3.8-flash"
        case (.other, _): return nil
        }
    }

    /// The model a tier sends, by its product name ("Claude Sonnet 5.5"), for the Model picker.
    /// Brand and product names, never translated; the tier's raw value stays the persisted
    /// identity.
    public func modelDisplayName(for tier: AIModelTier) -> String? {
        model(for: tier).map(Self.displayName(forModelID:))
    }

    /// A provider model identifier as its product name: "claude-sonnet-5-5" → "Claude Sonnet 5.5",
    /// "gpt-6.1-terra" → "GPT-6.1 Terra", "gemini-3.5-flash-lite" → "Gemini 3.5 Flash-Lite".
    static func displayName(forModelID id: String) -> String {
        let parts = id.split(separator: "-").map(String.init)
        func word(_ part: String) -> String { part.prefix(1).uppercased() + part.dropFirst() }
        switch parts.first {
        case "claude":
            // claude-<name>-<major>-<minor>
            let rest = parts.dropFirst()
            let names = rest.filter { !$0.allSatisfy(\.isNumber) }.map(word)
            let version = rest.filter { $0.allSatisfy(\.isNumber) }.joined(separator: ".")
            return ([word(parts[0])] + names + (version.isEmpty ? [] : [version])).joined(separator: " ")
        case "gpt" where parts.count >= 2:
            // gpt-<version>-<name>
            return (["GPT-" + parts[1]] + parts.dropFirst(2).map(word)).joined(separator: " ")
        case "gemini" where parts.count >= 3:
            // gemini-<version>-<name>[-lite]
            return [word(parts[0]), parts[1], parts.dropFirst(2).map(word).joined(separator: "-")].joined(separator: " ")
        default:
            return id
        }
    }

    var wireProtocol: AIWireProtocol {
        self == .claude ? .anthropicMessages : .openAIChatCompletions
    }
}

/// Which of a provider's two models a writer chose. The raw values are persisted identity
/// (UserDefaults) and are never localized; `title` is the chrome.
public enum AIModelTier: String, CaseIterable, Identifiable {
    case standard
    case higherQuality

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .standard: return String(localized: "Standard", bundle: .module)
        case .higherQuality: return String(localized: "Higher quality", bundle: .module)
        }
    }
}

/// Everything an action needs to make one request. Resolved at action time only.
public struct AIConnection: Equatable, Sendable {
    public let provider: AIProvider
    let endpoint: URL
    let model: String
    let apiKey: String?
}

extension AIConnection: CustomStringConvertible, CustomDebugStringConvertible {
    /// Never includes the key, so logging or string-interpolating a connection cannot leak it.
    public var description: String {
        "AIConnection(provider: \(provider.rawValue), endpoint: \(endpoint.absoluteString), "
            + "model: \(model), apiKey: \(apiKey == nil ? "none" : "<redacted>"))"
    }

    public var debugDescription: String { description }
}
