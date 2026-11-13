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
            let title = ConnectAIPresentation.title(bundle: bundle)
            let privacy = ConnectAIPresentation.privacyNote(bundle: bundle)
            XCTAssertNotEqual(title, ConnectAIPresentation.title(bundle: .main), language)
            XCTAssertNotEqual(title, "Connect Your AI", language)
            XCTAssertNotEqual(privacy, "Lineform sends only the text you act on, only when you choose an AI action, directly to the provider you connected, under your account and that provider's terms. Lineform's developer receives nothing.", language)
            for key in ["Connect — Lineform will send the text you choose to %@",
                        "Connect — Lineform will send the text you choose to that address"] {
                let consent = bundle.localizedString(forKey: key, value: nil, table: nil)
                XCTAssertNotEqual(consent, key, "\(language): consent label untranslated")
                if key.hasSuffix("%@") {
                    XCTAssertTrue(consent.contains("%@"), "\(language): \"\(consent)\" lost the recipient")
                }
            }
            for provider in AIProvider.allCases {
                XCTAssertNotEqual(ConnectAIPresentation.billingNote(for: provider, bundle: bundle),
                                  ConnectAIPresentation.billingNote(for: provider), "\(language) \(provider)")
            }
        }
    }

    /// The modal's title and the AI client error copy name the same place; keep them in agreement.
    func testTitleMatchesTheNameErrorsPointTo() throws {
        XCTAssertEqual(ConnectAIPresentation.title, "Connect Your AI")
        XCTAssertEqual(AppMenuConfiguration.connectAICommandTitle, "Connect Your AI…")
        XCTAssertTrue(AIClientError.connectionFailed.message.contains(ConnectAIPresentation.title))
        for language in Self.languages {
            let bundle = try bundle(language)
            let title = ConnectAIPresentation.title(bundle: bundle)
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

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appending(path: path), encoding: .utf8)
    }

    /// Return in a field is the Connect gesture; it must never close the modal and drop the
    /// pasted key. There is no default button; Esc (the shared header's ✕) closes.
    func testReturnInAFieldSubmitsConnectAndNeverCloses() throws {
        let source = try source("Lineform/AI/ConnectAIView.swift")
        XCTAssertFalse(source.contains(".defaultAction"), "no default button: Return would close the modal")
        let fields = source.matches(of: /(Secure|Text)Field\(/).count
        XCTAssertEqual(fields, 4, "field count changed; update this test")
        XCTAssertEqual(source.components(separatedBy: ".onSubmit(connect)").count - 1, fields,
                       "every field submits Connect on Return")
    }

    /// Presented exactly like Settings: the shared header (whose ✕ is the Esc-bound cancel
    /// action), the shared card, and the threaded theme — never a window of its own.
    func testModalUsesTheSettingsChromeAndEscCloses() throws {
        let view = try source("Lineform/AI/ConnectAIView.swift")
        XCTAssertTrue(view.contains("MuseModalHeader(title: ConnectAIPresentation.title, usesDarkChrome: usesDarkChrome, dismiss: dismiss)"))
        XCTAssertTrue(view.contains(".museModalCard("))
        XCTAssertFalse(view.contains("@Environment(\\.colorScheme) "), "usesDarkChrome is threaded, never read from the environment")
        XCTAssertFalse(view.contains("NSWindow"), "no window of its own")
        let header = try source("Lineform/Editor/EditorChromeAndControls.swift")
        let headerBody = try XCTUnwrap(header.range(of: "struct MuseModalHeader: View {")).upperBound
        let headerEnd = try XCTUnwrap(header.range(of: "private struct MuseModalCard", range: headerBody..<header.endIndex)).lowerBound
        XCTAssertTrue(header[headerBody..<headerEnd].contains(".keyboardShortcut(.cancelAction)"), "Esc closes via the header's ✕")
    }

    /// Opening and closing go through one state value in the container, like Settings.
    func testModalIsPresentedByTheContainerLikeSettings() throws {
        XCTAssertEqual(EditorAppModal.connectAI.notification, .showConnectAI)
        XCTAssertEqual(EditorAppModal.settings.notification, .showSettings)
        XCTAssertEqual(LineformAppNotification.showConnectAI.name.rawValue, "Lineform.showConnectAI")
        XCTAssertNotEqual(LineformAppNotification.showConnectAI.name, LineformAppNotification.showSettings.name)

        let container = try source("Lineform/Editor/EditorContainerView.swift")
        XCTAssertTrue(container.contains("publisher(for: LineformAppNotification.showConnectAI.name)) { _ in\n            presentAppModalInMainWindow(.connectAI)"))
        XCTAssertTrue(container.contains("if presentedAppModal == .connectAI {"))
        XCTAssertTrue(container.contains("presentedAppModal = nil"), "✕, Esc and the scrim dismiss it")
        let commands = try source("Lineform/App/AppCommands.swift")
        XCTAssertTrue(commands.contains("AppMenuConfiguration.presentInMainWindow(.showConnectAI)"))
        XCTAssertTrue(commands.contains("AppMenuConfiguration.presentInMainWindow(.showSettings)"))
    }

    func testCardFitsTheWindowAndThePaneScrollsWhenShort() {
        XCTAssertGreaterThan(ConnectAIView.contentWidth, SettingsModal.contentWidth, "two columns need more room")
        XCTAssertEqual(ConnectAIView.cardWidth(availableWidth: 2_000), ConnectAIView.contentWidth)
        XCTAssertEqual(ConnectAIView.cardWidth(availableWidth: 500), 476)
        XCTAssertEqual(ConnectAIView.cardWidth(availableWidth: 200), 280)
        XCTAssertEqual(ConnectAIView.bodyHeight(availableHeight: 2_000), ConnectAIView.idealBodyHeight)
        let short: CGFloat = 400
        let body = ConnectAIView.bodyHeight(availableHeight: short)
        XCTAssertLessThan(body, ConnectAIView.idealBodyHeight)
        XCTAssertLessThanOrEqual(body + ConnectAIView.verticalChrome, short, "the card stays inside the window")
        XCTAssertEqual(ConnectAIView.bodyHeight(availableHeight: 50), ConnectAIView.minimumBodyHeight)
    }
}
