import XCTest
@testable import LineformCore
import LineformCoreTestSupport

@MainActor
final class AIConnectionStoreTests: XCTestCase {
    private func freshDefaults(_ name: String) -> UserDefaults {
        let suite = "AIConnectionStoreTests.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testInitReadsNoKeychainAndStartsDisconnected() {
        let keychain = InMemoryAIKeychain()
        let store = AIConnectionStore(defaults: freshDefaults("init"), keychain: keychain)
        XCTAssertEqual(keychain.readCount, 0)
        XCTAssertFalse(store.isConnected)
    }

    func testConnectStoresKeyInKeychainNotDefaults() {
        let defaults = freshDefaults("keychain")
        let keychain = InMemoryAIKeychain()
        let store = AIConnectionStore(defaults: defaults, keychain: keychain)
        XCTAssertNil(store.connect(.claude, key: "  sk-test \n"))
        XCTAssertEqual(keychain.readKey(for: .claude), "sk-test")
        let stored = defaults.persistentDomain(forName: "AIConnectionStoreTests.keychain") ?? [:]
        XCTAssertFalse(String(describing: stored).contains("sk-test"))
    }

    func testConnectingAnotherProviderReplacesTheFirst() {
        let keychain = InMemoryAIKeychain()
        let store = AIConnectionStore(defaults: freshDefaults("replace"), keychain: keychain)
        XCTAssertNil(store.connect(.claude, key: "a"))
        XCTAssertNil(store.connect(.google, key: "b"))
        XCTAssertEqual(store.connectedProvider, .google)
        XCTAssertNil(keychain.readKey(for: .claude))
    }

    func testDisconnectRemovesKeyAndProvider() {
        let keychain = InMemoryAIKeychain()
        let defaults = freshDefaults("disconnect")
        let store = AIConnectionStore(defaults: defaults, keychain: keychain)
        XCTAssertNil(store.connect(.chatGPT, key: "k"))
        store.disconnect()
        XCTAssertFalse(store.isConnected)
        XCTAssertNil(keychain.readKey(for: .chatGPT))
        XCTAssertNil(defaults.string(forKey: AIConnectionStore.providerKey))
        XCTAssertNil(store.resolvedConnection())
    }

    func testConnectRejectsEmptyKey() {
        let store = AIConnectionStore(defaults: freshDefaults("empty"), keychain: InMemoryAIKeychain())
        XCTAssertEqual(store.connect(.claude, key: "  "), .missingKey)
        XCTAssertFalse(store.isConnected)
    }

    func testPlainHTTPAllowedOnlyForLoopback() throws {
        XCTAssertEqual(try AIEndpointValidation.chatCompletionsURL(from: "http://localhost:11434/v1").get().absoluteString,
                       "http://localhost:11434/v1/chat/completions")
        XCTAssertEqual(try AIEndpointValidation.chatCompletionsURL(from: "http://127.0.0.1:8765/v1").get().absoluteString,
                       "http://127.0.0.1:8765/v1/chat/completions")
        XCTAssertEqual(try AIEndpointValidation.chatCompletionsURL(from: "https://example.com/v1/chat/completions").get().absoluteString,
                       "https://example.com/v1/chat/completions")
        XCTAssertEqual(AIEndpointValidation.chatCompletionsURL(from: "http://192.168.1.5:1234/v1"), .failure(.insecureAddress))
        XCTAssertEqual(try AIEndpointValidation.chatCompletionsURL(from: "http://[::1]:8080/v1").get().absoluteString,
                       "http://[::1]:8080/v1/chat/completions")
        // A `.local` name is another machine on the network, not this Mac: it needs https.
        XCTAssertEqual(AIEndpointValidation.chatCompletionsURL(from: "http://printer.local:1234/v1"), .failure(.insecureAddress))
        XCTAssertEqual(try AIEndpointValidation.chatCompletionsURL(from: "https://printer.local:1234/v1").get().absoluteString,
                       "https://printer.local:1234/v1/chat/completions")
        XCTAssertEqual(AIEndpointValidation.chatCompletionsURL(from: "http://[2001:db8::1]:8080/v1"), .failure(.insecureAddress))
        XCTAssertEqual(AIEndpointValidation.chatCompletionsURL(from: "http://notlocal.example:80/v1"), .failure(.insecureAddress))
        XCTAssertEqual(AIEndpointValidation.chatCompletionsURL(from: "ftp://x"), .failure(.invalidAddress))
    }

    /// An `http://….local` address saved before plain http was limited to this Mac must not be
    /// used: the stored connection is dropped rather than sent over plain http.
    func testStoredPlainHTTPLocalEndpointIsNotResolved() {
        let defaults = freshDefaults("storedlocal")
        defaults.set(AIProvider.other.rawValue, forKey: AIConnectionStore.providerKey)
        defaults.set("http://box.local:1234/v1/chat/completions", forKey: AIConnectionStore.otherEndpointKey)
        let store = AIConnectionStore(defaults: defaults, keychain: InMemoryAIKeychain())
        XCTAssertNil(store.resolvedConnection())
        XCTAssertFalse(store.isConnected)
    }

    func testOtherConnectsWithoutAKey() {
        let store = AIConnectionStore(defaults: freshDefaults("other"), keychain: InMemoryAIKeychain())
        XCTAssertNil(store.connectOther(address: "http://127.0.0.1:8765/v1", key: nil, model: nil))
        let resolved = store.resolvedConnection()
        XCTAssertNil(resolved?.apiKey)
        XCTAssertEqual(resolved?.model, "default")
        XCTAssertEqual(resolved?.endpoint.absoluteString, "http://127.0.0.1:8765/v1/chat/completions")
    }

    func testRelaunchRestoresConnectedProvider() {
        let defaults = freshDefaults("relaunch")
        let keychain = InMemoryAIKeychain()
        XCTAssertNil(AIConnectionStore(defaults: defaults, keychain: keychain).connect(.claude, key: "k"))
        let second = AIConnectionStore(defaults: defaults, keychain: keychain)
        XCTAssertEqual(second.connectedProvider, .claude)
        XCTAssertEqual(keychain.readCount, 0)
    }

    func testModelDefaultsToCheapestAndPersistsPerProvider() throws {
        let defaults = freshDefaults("model")
        let store = AIConnectionStore(defaults: defaults, keychain: InMemoryAIKeychain())
        XCTAssertEqual(store.model(for: .claude)?.id, "claude-haiku-5-5")
        XCTAssertEqual(store.model(for: .chatGPT)?.id, "gpt-6-luna")
        XCTAssertEqual(store.model(for: .google)?.id, "gemini-3.5-flash-lite")
        XCTAssertNil(store.model(for: .other), "Other's model is typed")
        let sol = try XCTUnwrap(AIProvider.chatGPT.model(withID: "gpt-6.2-sol"))
        store.setModel(sol, for: .chatGPT)
        XCTAssertEqual(store.model(for: .chatGPT), sol)
        XCTAssertEqual(store.model(for: .claude)?.id, "claude-haiku-5-5")
        XCTAssertEqual(defaults.string(forKey: "Lineform.ai.model.chatgpt"), "gpt-6.2-sol")
        let relaunched = AIConnectionStore(defaults: defaults, keychain: InMemoryAIKeychain())
        XCTAssertEqual(relaunched.model(for: .chatGPT), sol)
        XCTAssertEqual(relaunched.model(for: .google)?.id, "gemini-3.5-flash-lite")
        // Another provider's model is refused.
        let opus = try XCTUnwrap(AIProvider.claude.model(withID: "claude-opus-5-5"))
        store.setModel(opus, for: .google)
        XCTAssertNil(defaults.string(forKey: "Lineform.ai.model.google"))
    }

    func testSavedTiersMigrateToTheirModels() {
        let defaults = freshDefaults("migrate")
        defaults.set("higherQuality", forKey: "Lineform.ai.tier.claude")
        defaults.set("higherQuality", forKey: "Lineform.ai.tier.chatgpt")
        defaults.set("higherQuality", forKey: "Lineform.ai.tier.google")
        let store = AIConnectionStore(defaults: defaults, keychain: InMemoryAIKeychain())
        XCTAssertEqual(store.model(for: .claude)?.id, "claude-sonnet-5-5")
        XCTAssertEqual(store.model(for: .chatGPT)?.id, "gpt-6.1-terra")
        XCTAssertEqual(store.model(for: .google)?.id, "gemini-3.8-flash")
        for provider in AIProvider.allCases {
            XCTAssertNil(defaults.string(forKey: "Lineform.ai.tier.\(provider.rawValue)"), "tier key removed")
        }

        let standard = freshDefaults("migrate-standard")
        standard.set("standard", forKey: "Lineform.ai.tier.claude")
        standard.set("standard", forKey: "Lineform.ai.tier.google")
        let second = AIConnectionStore(defaults: standard, keychain: InMemoryAIKeychain())
        XCTAssertEqual(second.model(for: .claude)?.id, "claude-haiku-5-5")
        XCTAssertEqual(second.model(for: .google)?.id, "gemini-3.5-flash-lite")
        XCTAssertNil(standard.string(forKey: "Lineform.ai.tier.claude"))

        // A model already chosen wins over a leftover tier.
        let both = freshDefaults("migrate-both")
        both.set("claude-opus-5-5", forKey: "Lineform.ai.model.claude")
        both.set("standard", forKey: "Lineform.ai.tier.claude")
        XCTAssertEqual(AIConnectionStore(defaults: both, keychain: InMemoryAIKeychain()).model(for: .claude)?.id,
                       "claude-opus-5-5")
    }

    func testUnlistedSavedModelFallsBackToDefault() {
        let defaults = freshDefaults("unlisted")
        defaults.set("claude-fable-5-2", forKey: "Lineform.ai.model.claude")
        defaults.set("gpt-6.2-astra", forKey: "Lineform.ai.model.chatgpt")
        let store = AIConnectionStore(defaults: defaults, keychain: InMemoryAIKeychain())
        XCTAssertEqual(store.model(for: .claude)?.id, "claude-haiku-5-5")
        XCTAssertEqual(store.model(for: .chatGPT)?.id, "gpt-6-luna")
        XCTAssertNil(store.connect(.claude, key: "k"))
        XCTAssertEqual(store.resolvedConnection()?.model, "claude-haiku-5-5")
    }

    func testResolvedConnectionUsesChosenModel() throws {
        let store = AIConnectionStore(defaults: freshDefaults("resolved"), keychain: InMemoryAIKeychain())
        XCTAssertNil(store.connect(.claude, key: "k"))
        var resolved = store.resolvedConnection()
        XCTAssertEqual(resolved?.endpoint.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(resolved?.model, "claude-haiku-5-5")
        XCTAssertEqual(resolved?.apiKey, "k")
        // Changing the model while connected needs no new key.
        store.setModel(try XCTUnwrap(AIProvider.claude.model(withID: "claude-opus-5-5")), for: .claude)
        resolved = store.resolvedConnection()
        XCTAssertEqual(resolved?.model, "claude-opus-5-5")
        XCTAssertEqual(resolved?.apiKey, "k")

        XCTAssertNil(store.connect(.chatGPT, key: "k"))
        XCTAssertEqual(store.resolvedConnection()?.model, "gpt-6-luna")
        store.setModel(try XCTUnwrap(AIProvider.chatGPT.model(withID: "gpt-6.1-terra")), for: .chatGPT)
        XCTAssertEqual(store.resolvedConnection()?.model, "gpt-6.1-terra")

        XCTAssertNil(store.connect(.google, key: "k"))
        XCTAssertEqual(store.resolvedConnection()?.model, "gemini-3.5-flash-lite")
        store.setModel(try XCTUnwrap(AIProvider.google.model(withID: "gemini-4-neon")), for: .google)
        XCTAssertEqual(store.resolvedConnection()?.model, "gemini-4-neon")
    }

    func testModelListsAreCuratedCheapestFirst() {
        XCTAssertEqual(AIProvider.claude.models.map(\.id), ["claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5"])
        XCTAssertEqual(AIProvider.chatGPT.models.map(\.id), ["gpt-6-luna", "gpt-6.1-terra", "gpt-6.2-sol"])
        XCTAssertEqual(AIProvider.google.models.map(\.id),
                       ["gemini-3.5-flash-lite", "gemini-3.8-flash", "gemini-4-hydrogen", "gemini-4-neon"])
        XCTAssertEqual(AIProvider.claude.models.map(\.displayName),
                       ["Claude Haiku 5.5", "Claude Sonnet 5.5", "Claude Opus 5.5"])
        XCTAssertEqual(AIProvider.chatGPT.models.map(\.displayName), ["GPT-6 Luna", "GPT-6.1 Terra", "GPT-6.2 Sol"])
        XCTAssertEqual(AIProvider.google.models.map(\.displayName),
                       ["Gemini 3.5 Flash-Lite", "Gemini 3.8 Flash", "Gemini 4 Hydrogen", "Gemini 4 Neon"])
        // The top tier is never offered.
        let ids = AIProvider.allCases.flatMap(\.models).map(\.id)
        for excluded in ["fable", "mythos", "astra", "-pro", "carbon", "argon", "ultra"] {
            XCTAssertFalse(ids.contains { $0.contains(excluded) }, excluded)
        }
        XCTAssertTrue(AIProvider.other.models.isEmpty)
        XCTAssertNil(AIProvider.other.defaultModel)
    }

    func testFailedKeychainWriteLeavesTheExistingConnectionIntact() {
        let keychain = InMemoryAIKeychain()
        let store = AIConnectionStore(defaults: freshDefaults("failwrite"), keychain: keychain)
        XCTAssertNil(store.connect(.claude, key: "claude-key"))
        keychain.failWrites = true
        XCTAssertEqual(store.connect(.google, key: "google-key"), .keychainFailed)
        XCTAssertEqual(store.connectedProvider, .claude)
        XCTAssertEqual(keychain.readKey(for: .claude), "claude-key")
        XCTAssertNil(keychain.readKey(for: .google))
    }

    func testConnectionDescriptionsRedactTheKey() {
        let connection = AIConnection(provider: .claude, endpoint: AIProvider.claude.endpoint!,
                                      model: "m", apiKey: "sk-secret-123")
        XCTAssertFalse(connection.description.contains("sk-secret-123"))
        XCTAssertFalse(connection.debugDescription.contains("sk-secret-123"))
        XCTAssertFalse("\(connection)".contains("sk-secret-123"))
        XCTAssertFalse(String(reflecting: connection).contains("sk-secret-123"))
        XCTAssertTrue(connection.description.contains("<redacted>"))
    }
}
