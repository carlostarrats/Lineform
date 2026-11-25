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

    /// The models the writer can pick, cheapest first; the first is the default. A curated
    /// static list (no network fetch) of each provider's current general-purpose chat models,
    /// leaving out the top tier (Claude Fable, GPT Astra, Gemini 4 Carbon and its Argon variant)
    /// and every non-chat model (embedding, image, audio, TTS, live). Verified 2026-11-24 against
    /// platform.claude.com/docs/en/about-claude/models/overview, developers.openai.com/api/docs/models
    /// (each GPT page lists `v1/chat/completions` as supported) and aistudio.google.com/docs/models
    /// with its pricing page (all stable; served through Google's OpenAI-compatible endpoint).
    /// Display names are product names, never translated.
    public var models: [AIModelOption] {
        switch self {
        case .claude:
            return [
                AIModelOption(id: "claude-haiku-5-5", displayName: "Claude Haiku 5.5"),
                AIModelOption(id: "claude-sonnet-5-5", displayName: "Claude Sonnet 5.5"),
                AIModelOption(id: "claude-opus-5-5", displayName: "Claude Opus 5.5"),
            ]
        case .chatGPT:
            return [
                AIModelOption(id: "gpt-6-luna", displayName: "GPT-6 Luna"),
                AIModelOption(id: "gpt-6.1-terra", displayName: "GPT-6.1 Terra"),
                AIModelOption(id: "gpt-6.2-sol", displayName: "GPT-6.2 Sol"),
            ]
        case .google:
            return [
                AIModelOption(id: "gemini-3.5-flash-lite", displayName: "Gemini 3.5 Flash-Lite"),
                AIModelOption(id: "gemini-3.8-flash", displayName: "Gemini 3.8 Flash"),
                AIModelOption(id: "gemini-4-hydrogen", displayName: "Gemini 4 Hydrogen"),
                AIModelOption(id: "gemini-4-neon", displayName: "Gemini 4 Neon"),
            ]
        case .other:
            return []
        }
    }

    /// The cheapest model; what a writer gets until they choose. Nil for Other, whose model is
    /// what the writer types.
    public var defaultModel: AIModelOption? { models.first }

    /// The listed model with this ID, or nil when it is not (or no longer) in the list.
    public func model(withID id: String) -> AIModelOption? {
        models.first { $0.id == id }
    }

    /// The model a saved two-tier choice (`Lineform.ai.tier.<provider>`, before the full list)
    /// sent: "standard" is the default, "higherQuality" the model that tier sent then. Fixed
    /// here so later list changes cannot move a migrated choice. Nil for anything else.
    func migratedModelID(fromTier tier: String) -> String? {
        switch (self, tier) {
        case (.other, _): return nil
        case (_, "standard"): return defaultModel?.id
        case (.claude, "higherQuality"): return "claude-sonnet-5-5"
        case (.chatGPT, "higherQuality"): return "gpt-6.1-terra"
        case (.google, "higherQuality"): return "gemini-3.8-flash"
        default: return nil
        }
    }

    var wireProtocol: AIWireProtocol {
        self == .claude ? .anthropicMessages : .openAIChatCompletions
    }
}

/// One model the Model picker offers: the ID sent on the wire (persisted identity in
/// UserDefaults) and its product name, never translated.
public struct AIModelOption: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let displayName: String
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
