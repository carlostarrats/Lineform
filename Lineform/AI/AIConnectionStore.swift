import Foundation

enum AIConnectError: Error, Equatable {
    case missingKey
    case invalidAddress
    case insecureAddress
    case keychainFailed

    var message: String {
        switch self {
        case .missingKey:
            return String(localized: "Paste your API key first.")
        case .invalidAddress:
            return String(localized: "Enter an address that starts with http:// or https://.")
        case .insecureAddress:
            return String(localized: "Plain http:// is only allowed for a server on this Mac. Use https:// for other addresses.")
        case .keychainFailed:
            return String(localized: "Lineform couldn't save the key in your Keychain.")
        }
    }
}

enum AIEndpointValidation {
    private static let suffix = "/chat/completions"

    /// Plain http only for a server on this Mac. A `.local` name is another machine on the
    /// network, where a key and the writer's text would travel unencrypted, so it needs https.
    static func allowsPlainHTTP(host: String) -> Bool {
        // URLComponents reports an IPv6 literal with its brackets on some systems.
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    /// True when a stored endpoint still meets the rule above. An address saved before the
    /// rule tightened (`http://box.local`) is not used.
    static func isPermitted(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty else { return false }
        if scheme == "https" { return true }
        return scheme == "http" && allowsPlainHTTP(host: host)
    }

    /// Turns what the writer typed into a chat-completions URL.
    static func chatCompletionsURL(from input: String) -> Result<URL, AIConnectError> {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else {
            return .failure(.invalidAddress)
        }
        if scheme == "http", !allowsPlainHTTP(host: host) {
            return .failure(.insecureAddress)
        }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix(suffix) { path += suffix }
        components.path = path
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { return .failure(.invalidAddress) }
        return .success(url)
    }
}

/// The one active AI connection. Init reads UserDefaults only; the Keychain is read once,
/// by `resolvedConnection()`, when a writer chooses an action.
@MainActor
final class AIConnectionStore: ObservableObject {
    static let shared = AIConnectionStore(defaults: .standard, keychain: SystemAIKeychain())

    static let providerKey = "Lineform.ai.provider"
    static let otherEndpointKey = "Lineform.ai.otherEndpoint"
    static let otherModelKey = "Lineform.ai.otherModel"
    /// Per provider: `Lineform.ai.tier.<provider.rawValue>`, holding an `AIModelTier` raw value.
    static let tierKeyPrefix = "Lineform.ai.tier"
    static func tierKey(for provider: AIProvider) -> String { [tierKeyPrefix, provider.rawValue].joined(separator: ".") }

    @Published private(set) var connectedProvider: AIProvider?
    private(set) var otherEndpoint: URL?
    private(set) var otherModel: String?

    private let defaults: UserDefaults
    private let keychain: AIKeychain

    var isConnected: Bool { connectedProvider != nil }

    init(defaults: UserDefaults, keychain: AIKeychain) {
        self.defaults = defaults
        self.keychain = keychain
        let endpoint = defaults.string(forKey: Self.otherEndpointKey).flatMap(URL.init(string:))
            .flatMap { AIEndpointValidation.isPermitted($0) ? $0 : nil }
        let provider = defaults.string(forKey: Self.providerKey).flatMap(AIProvider.init(rawValue:))
        if provider == .other, endpoint == nil {
            connectedProvider = nil
        } else {
            connectedProvider = provider
        }
        otherEndpoint = endpoint
        otherModel = defaults.string(forKey: Self.otherModelKey)
    }

    /// The writer's model tier for a provider; `.standard` until they choose otherwise.
    func tier(for provider: AIProvider) -> AIModelTier {
        defaults.string(forKey: Self.tierKey(for: provider)).flatMap(AIModelTier.init(rawValue:)) ?? .standard
    }

    /// Takes effect at the next action; the key is untouched.
    func setTier(_ tier: AIModelTier, for provider: AIProvider) {
        guard tier != self.tier(for: provider) else { return }
        objectWillChange.send()
        defaults.set(tier.rawValue, forKey: Self.tierKey(for: provider))
    }

    func connect(_ provider: AIProvider, key: String) -> AIConnectError? {
        guard provider != .other else { return .invalidAddress }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .missingKey }
        guard keychain.writeKey(trimmed, for: provider) else { return .keychainFailed }
        deleteKeys(except: provider)
        clearOther()
        defaults.set(provider.rawValue, forKey: Self.providerKey)
        connectedProvider = provider
        return nil
    }

    func connectOther(address: String, key: String?, model: String?) -> AIConnectError? {
        let endpoint: URL
        switch AIEndpointValidation.chatCompletionsURL(from: address) {
        case .failure(let error): return error
        case .success(let url): endpoint = url
        }
        let trimmedKey = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmedKey.isEmpty {
            keychain.deleteKey(for: .other)
        } else if !keychain.writeKey(trimmedKey, for: .other) {
            return .keychainFailed
        }
        deleteKeys(except: .other)
        let trimmedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        otherEndpoint = endpoint
        otherModel = trimmedModel.isEmpty ? nil : trimmedModel
        defaults.set(endpoint.absoluteString, forKey: Self.otherEndpointKey)
        if let otherModel {
            defaults.set(otherModel, forKey: Self.otherModelKey)
        } else {
            defaults.removeObject(forKey: Self.otherModelKey)
        }
        defaults.set(AIProvider.other.rawValue, forKey: Self.providerKey)
        connectedProvider = .other
        return nil
    }

    func disconnect() {
        deleteKeys(except: nil)
        clearOther()
        defaults.removeObject(forKey: Self.providerKey)
        connectedProvider = nil
    }

    /// The only Keychain read. Returns nil when disconnected, or when a big-three key has
    /// gone missing from the Keychain.
    func resolvedConnection() -> AIConnection? {
        guard let provider = connectedProvider else { return nil }
        let key = keychain.readKey(for: provider)
        if provider == .other {
            guard let endpoint = otherEndpoint, AIEndpointValidation.isPermitted(endpoint) else { return nil }
            return AIConnection(provider: provider, endpoint: endpoint,
                                model: otherModel ?? "default", apiKey: key)
        }
        guard let endpoint = provider.endpoint, let model = provider.model(for: tier(for: provider)),
              let key else { return nil }
        return AIConnection(provider: provider, endpoint: endpoint, model: model, apiKey: key)
    }

    /// True when the store says a big-three provider is connected but its key is gone from
    /// the Keychain (deleted in Keychain Access, or a restored defaults file). Checks the
    /// item's presence only — the key itself is never read here.
    func connectedKeyIsMissing() -> Bool {
        guard let provider = connectedProvider, provider != .other else { return false }
        return !keychain.hasKey(for: provider)
    }

    private func deleteKeys(except keep: AIProvider?) {
        for provider in AIProvider.allCases where provider != keep {
            keychain.deleteKey(for: provider)
        }
    }

    private func clearOther() {
        otherEndpoint = nil
        otherModel = nil
        defaults.removeObject(forKey: Self.otherEndpointKey)
        defaults.removeObject(forKey: Self.otherModelKey)
    }
}
