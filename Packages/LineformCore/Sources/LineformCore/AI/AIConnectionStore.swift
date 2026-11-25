import Foundation

public enum AIConnectError: Error, Equatable {
    case missingKey
    case invalidAddress
    case insecureAddress
    case keychainFailed

    public var message: String { message(bundle: .module) }

    func message(bundle: Bundle) -> String {
        switch self {
        case .missingKey:
            return String(localized: "Paste your API key first.", bundle: bundle)
        case .invalidAddress:
            return String(localized: "Enter an address that starts with http:// or https://.", bundle: bundle)
        case .insecureAddress:
            guard !AIDeviceWording.namesPhone else {
                return String(localized: "Plain http:// is only allowed for a server on this iPhone. Use https:// for other addresses.", bundle: bundle)
            }
            return String(localized: "Plain http:// is only allowed for a server on this Mac. Use https:// for other addresses.", bundle: bundle)
        case .keychainFailed:
            return String(localized: "Lineform couldn't save the key in your Keychain.", bundle: bundle)
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
public final class AIConnectionStore: ObservableObject {
    public static let shared = AIConnectionStore(defaults: .standard, keychain: SystemAIKeychain())

    static let providerKey = "Lineform.ai.provider"
    static let otherEndpointKey = "Lineform.ai.otherEndpoint"
    static let otherModelKey = "Lineform.ai.otherModel"
    /// Per provider: `Lineform.ai.model.<provider.rawValue>`, holding a model ID from
    /// `AIProvider.models`.
    static let modelKeyPrefix = "Lineform.ai.model"
    static func modelKey(for provider: AIProvider) -> String { [modelKeyPrefix, provider.rawValue].joined(separator: ".") }
    /// The earlier two-tier choice (`standard` / `higherQuality`), migrated to a model ID at init.
    static let legacyTierKeyPrefix = "Lineform.ai.tier"
    static func legacyTierKey(for provider: AIProvider) -> String { [legacyTierKeyPrefix, provider.rawValue].joined(separator: ".") }

    @Published public private(set) var connectedProvider: AIProvider?
    public private(set) var otherEndpoint: URL?
    private(set) var otherModel: String?

    private let defaults: UserDefaults
    private let keychain: AIKeychain

    public var isConnected: Bool { connectedProvider != nil }

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
        Self.migrateLegacyTiers(in: defaults)
    }

    /// A saved tier becomes the model it sent; the tier key is then removed. A model already
    /// chosen wins over a leftover tier.
    private static func migrateLegacyTiers(in defaults: UserDefaults) {
        for provider in AIProvider.allCases where provider != .other {
            let tierKey = legacyTierKey(for: provider)
            guard let tier = defaults.string(forKey: tierKey) else { continue }
            if defaults.string(forKey: modelKey(for: provider)) == nil,
               let id = provider.migratedModelID(fromTier: tier) {
                defaults.set(id, forKey: modelKey(for: provider))
            }
            defaults.removeObject(forKey: tierKey)
        }
    }

    /// The writer's model for a provider: the cheapest until they choose otherwise, and again
    /// when a saved ID is no longer in the list. Nil for Other (its model is typed).
    public func model(for provider: AIProvider) -> AIModelOption? {
        defaults.string(forKey: Self.modelKey(for: provider)).flatMap(provider.model(withID:))
            ?? provider.defaultModel
    }

    /// Takes effect at the next action; the key is untouched. IDs not in the provider's list
    /// are ignored.
    public func setModel(_ model: AIModelOption, for provider: AIProvider) {
        guard provider.model(withID: model.id) != nil,
              defaults.string(forKey: Self.modelKey(for: provider)) != model.id else { return }
        objectWillChange.send()
        defaults.set(model.id, forKey: Self.modelKey(for: provider))
    }

    public func connect(_ provider: AIProvider, key: String) -> AIConnectError? {
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

    public func connectOther(address: String, key: String?, model: String?) -> AIConnectError? {
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

    public func disconnect() {
        deleteKeys(except: nil)
        clearOther()
        defaults.removeObject(forKey: Self.providerKey)
        connectedProvider = nil
    }

    /// The only Keychain read. Returns nil when disconnected, or when a big-three key has
    /// gone missing from the Keychain.
    public func resolvedConnection() -> AIConnection? {
        guard let provider = connectedProvider else { return nil }
        let key = keychain.readKey(for: provider)
        if provider == .other {
            guard let endpoint = otherEndpoint, AIEndpointValidation.isPermitted(endpoint) else { return nil }
            return AIConnection(provider: provider, endpoint: endpoint,
                                model: otherModel ?? "default", apiKey: key)
        }
        guard let endpoint = provider.endpoint, let model = self.model(for: provider), let key else { return nil }
        return AIConnection(provider: provider, endpoint: endpoint, model: model.id, apiKey: key)
    }

    /// True when the store says a big-three provider is connected but its key is gone from
    /// the Keychain (deleted in Keychain Access, or a restored defaults file). Checks the
    /// item's presence only — the key itself is never read here.
    public func connectedKeyIsMissing() -> Bool {
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
