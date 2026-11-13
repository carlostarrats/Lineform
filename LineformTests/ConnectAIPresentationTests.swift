import XCTest
@testable import Lineform

@MainActor
final class ConnectAIPresentationTests: XCTestCase {
    private static let languages = ["es", "fr", "de", "ja", "zh-Hans"]

    private func bundle(_ language: String) throws -> Bundle {
        try XCTUnwrap(
            Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)),
            "\(language).lproj missing from the test host"
        )
    }

    private func freshDefaults(_ name: String) -> UserDefaults {
        let suite = "ConnectAIPresentationTests.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testConnectButtonNamesWhatIsSentAndToWhom() {
        XCTAssertTrue(ConnectAIPresentation.connectButtonTitle(for: .claude, otherHost: nil).contains("Anthropic"))
        XCTAssertTrue(ConnectAIPresentation.connectButtonTitle(for: .chatGPT, otherHost: nil).contains("OpenAI"))
        XCTAssertTrue(ConnectAIPresentation.connectButtonTitle(for: .google, otherHost: nil).contains("Google"))
        XCTAssertTrue(ConnectAIPresentation.connectButtonTitle(for: .other, otherHost: "localhost").contains("localhost"))
        XCTAssertTrue(ConnectAIPresentation.connectButtonTitle(for: .claude, otherHost: nil).contains("text you choose"))
        XCTAssertTrue(ConnectAIPresentation.connectButtonTitle(for: .other, otherHost: nil).contains("that address"))
        XCTAssertTrue(ConnectAIPresentation.connectButtonTitle(for: .other, otherHost: "  ").contains("that address"))
    }

    func testBillingNoteSaysSubscriptionDoesNotCoverIt() {
        for provider in [AIProvider.claude, .chatGPT, .google] {
            let note = ConnectAIPresentation.billingNote(for: provider)
            XCTAssertTrue(note.contains("doesn't cover"), "\(provider): \(note)")
            XCTAssertTrue(note.contains(provider.companyName!), "\(provider): \(note)")
        }
        XCTAssertTrue(ConnectAIPresentation.billingNote(for: .other).contains("Ollama"))
    }

    func testCopyIsTranslatedInEveryLanguage() throws {
        for language in Self.languages {
            let bundle = try bundle(language)
            let title = ConnectAIPresentation.windowTitle(bundle: bundle)
            let privacy = ConnectAIPresentation.privacyNote(bundle: bundle)
            XCTAssertNotEqual(title, ConnectAIPresentation.windowTitle(bundle: .main), language)
            XCTAssertNotEqual(title, "Connect Your AI", language)
            XCTAssertNotEqual(privacy, "Lineform sends only the text you act on, only when you choose an AI action, directly to the provider you connected, under your account and that provider's terms. Lineform's developer receives nothing.", language)
            for provider in AIProvider.allCases {
                XCTAssertNotEqual(ConnectAIPresentation.billingNote(for: provider, bundle: bundle),
                                  ConnectAIPresentation.billingNote(for: provider), "\(language) \(provider)")
            }
        }
    }

    /// The window and the AI client error copy name the same place; keep them in agreement.
    func testWindowTitleMatchesTheNameErrorsPointTo() throws {
        XCTAssertEqual(ConnectAIPresentation.windowTitle, "Connect Your AI")
        XCTAssertEqual(AppMenuConfiguration.connectAICommandTitle, "Connect Your AI…")
        XCTAssertTrue(AIClientError.connectionFailed.message.contains(ConnectAIPresentation.windowTitle))
        for language in Self.languages {
            let bundle = try bundle(language)
            let title = ConnectAIPresentation.windowTitle(bundle: bundle)
            let error = bundle.localizedString(
                forKey: "Couldn't make a secure connection to the AI. Check the address in Connect Your AI.",
                value: nil, table: nil)
            XCTAssertTrue(error.contains(title), "\(language): \"\(error)\" does not name \"\(title)\"")
        }
    }

    func testEveryProviderHasEndpointModelAndKeyPage() {
        for provider in [AIProvider.claude, .chatGPT, .google] {
            XCTAssertNotNil(provider.endpoint, "\(provider)")
            XCTAssertNotNil(provider.defaultModel, "\(provider)")
            XCTAssertNotNil(provider.createKeyURL, "\(provider)")
            XCTAssertNotNil(provider.companyName, "\(provider)")
        }
        XCTAssertNil(AIProvider.other.endpoint)
        XCTAssertNil(AIProvider.other.defaultModel)
        XCTAssertNil(AIProvider.other.createKeyURL)
    }

    func testOtherHostComesFromTheTypedAddress() {
        XCTAssertEqual(ConnectAIPresentation.host(fromAddress: "http://localhost:11434/v1"), "localhost")
        XCTAssertEqual(ConnectAIPresentation.host(fromAddress: " https://ai.example.com "), "ai.example.com")
        XCTAssertNil(ConnectAIPresentation.host(fromAddress: ""))
        XCTAssertNil(ConnectAIPresentation.host(fromAddress: "not an address"))
    }

    // MARK: - Pane state

    func testPaneShowsConnectedOnlyForTheConnectedProviderWithItsKey() {
        XCTAssertEqual(ConnectAIPresentation.paneState(for: .claude, connectedProvider: .claude, keyMissing: false),
                       .connected)
        XCTAssertEqual(ConnectAIPresentation.paneState(for: .chatGPT, connectedProvider: .claude, keyMissing: false),
                       .needsKey(reconnect: false))
        XCTAssertEqual(ConnectAIPresentation.paneState(for: .claude, connectedProvider: nil, keyMissing: false),
                       .needsKey(reconnect: false))
    }

    /// Store says connected, Keychain has no key: show the key field again, never "Connected".
    func testMissingKeyShowsReconnectNotConnected() {
        XCTAssertEqual(ConnectAIPresentation.paneState(for: .claude, connectedProvider: .claude, keyMissing: true),
                       .needsKey(reconnect: true))
        XCTAssertFalse(ConnectAIPresentation.showsConnectedMark(for: .claude, connectedProvider: .claude, keyMissing: true))
        XCTAssertTrue(ConnectAIPresentation.showsConnectedMark(for: .claude, connectedProvider: .claude, keyMissing: false))
        XCTAssertFalse(ConnectAIPresentation.showsConnectedMark(for: .google, connectedProvider: .claude, keyMissing: false))
    }

    func testStoreReportsAMissingKeyWithoutReadingTheSecret() {
        let keychain = InMemoryAIKeychain()
        let store = AIConnectionStore(defaults: freshDefaults("missing"), keychain: keychain)
        XCTAssertFalse(store.connectedKeyIsMissing(), "disconnected is not 'missing'")
        XCTAssertNil(store.connect(.claude, key: "sk-test"))
        XCTAssertFalse(store.connectedKeyIsMissing())
        keychain.deleteKey(for: .claude)
        XCTAssertTrue(store.connectedKeyIsMissing())
        XCTAssertEqual(keychain.readCount, 0, "the presence check must never read the key itself")
    }

    func testOtherWithoutAKeyIsNotMissingAKey() {
        let keychain = InMemoryAIKeychain()
        let store = AIConnectionStore(defaults: freshDefaults("other"), keychain: keychain)
        XCTAssertNil(store.connectOther(address: "http://127.0.0.1:8080", key: nil, model: nil))
        XCTAssertFalse(store.connectedKeyIsMissing(), "Other's key is optional")
        XCTAssertEqual(keychain.readCount, 0)
    }
}
