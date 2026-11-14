import XCTest
@testable import Lineform

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

    func testTierDefaultsToStandardAndPersistsPerProvider() {
        let defaults = freshDefaults("tier")
        let store = AIConnectionStore(defaults: defaults, keychain: InMemoryAIKeychain())
        for provider in AIProvider.allCases {
            XCTAssertEqual(store.tier(for: provider), .standard, "\(provider)")
        }
        store.setTier(.higherQuality, for: .chatGPT)
        XCTAssertEqual(store.tier(for: .chatGPT), .higherQuality)
        XCTAssertEqual(store.tier(for: .claude), .standard)
        XCTAssertEqual(defaults.string(forKey: "Lineform.ai.tier.chatgpt"), "higherQuality")
        let relaunched = AIConnectionStore(defaults: defaults, keychain: InMemoryAIKeychain())
        XCTAssertEqual(relaunched.tier(for: .chatGPT), .higherQuality)
        XCTAssertEqual(relaunched.tier(for: .google), .standard)
    }

    func testResolvedConnectionUsesTierModel() {
        let store = AIConnectionStore(defaults: freshDefaults("resolved"), keychain: InMemoryAIKeychain())
        XCTAssertNil(store.connect(.claude, key: "k"))
        var resolved = store.resolvedConnection()
        XCTAssertEqual(resolved?.endpoint.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(resolved?.model, "claude-haiku-5-5")
        XCTAssertEqual(resolved?.apiKey, "k")
        // Changing the tier while connected needs no new key.
        store.setTier(.higherQuality, for: .claude)
        resolved = store.resolvedConnection()
        XCTAssertEqual(resolved?.model, "claude-sonnet-5-5")
        XCTAssertEqual(resolved?.apiKey, "k")

        XCTAssertNil(store.connect(.chatGPT, key: "k"))
        XCTAssertEqual(store.resolvedConnection()?.model, "gpt-6-luna")
        store.setTier(.higherQuality, for: .chatGPT)
        XCTAssertEqual(store.resolvedConnection()?.model, "gpt-6.1-terra")

        XCTAssertNil(store.connect(.google, key: "k"))
        XCTAssertEqual(store.resolvedConnection()?.model, "gemini-3.5-flash-lite")
        store.setTier(.higherQuality, for: .google)
        XCTAssertEqual(store.resolvedConnection()?.model, "gemini-3.8-flash")
    }

    func testOtherHasNoTierModel() {
        for tier in AIModelTier.allCases {
            XCTAssertNil(AIProvider.other.model(for: tier))
        }
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
