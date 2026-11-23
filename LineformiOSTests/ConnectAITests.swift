import LineformCore
import SwiftUI
import UIKit
import XCTest
@testable import LineformCore
@testable import LineformiOS

/// Connect Your AI on iPhone (Menu ▸ Settings ▸ Connect Your AI…): the consent button names what
/// is sent and to whom, one provider at a time, Disconnect, Other's address and model, and no
/// string that names a Mac. The Keychain is always the in-memory double.
@MainActor
final class ConnectAITests: XCTestCase {
    private var suites: [String] = []
    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window = nil
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        super.tearDown()
    }

    func testConnectButtonCarriesFullConsentLabel() async throws {
        try skipUnlessEnglishInterface()
        let (form, _, _) = makeForm()
        form.select(.claude)
        XCTAssertEqual(form.connectTitle, "Connect — Lineform will send the text you choose to Anthropic")
        form.select(.chatGPT)
        XCTAssertEqual(form.connectTitle, "Connect — Lineform will send the text you choose to OpenAI")
        form.select(.google)
        XCTAssertEqual(form.connectTitle, "Connect — Lineform will send the text you choose to Google")
        form.select(.other)
        XCTAssertEqual(form.connectTitle, "Connect — Lineform will send the text you choose to that address")
        form.address = "https://ai.example.com/v1"
        XCTAssertEqual(form.connectTitle, "Connect — Lineform will send the text you choose to ai.example.com")
        XCTAssertEqual(form.connectTitle, ConnectAIPresentation.connectButtonTitle(for: .other, otherHost: "ai.example.com"))

        // On screen, the button carries the whole label, never a shortened one.
        form.select(.claude)
        let window = try host(ConnectAISheet(form: form, usesDarkChrome: false, onDone: {}))
        try await spin { Self.element("Connect — Lineform will send the text you choose to Anthropic", in: window) != nil }
        let button = try XCTUnwrap(Self.element("Connect — Lineform will send the text you choose to Anthropic", in: window))
        XCTAssertTrue(button.accessibilityTraits.contains(.button))
    }

    func testConnectingDeletesOtherKeys() throws {
        let (form, store, keychain) = makeForm()
        keychain.writeKey("old-openai", for: .chatGPT)
        keychain.writeKey("old-google", for: .google)
        keychain.writeKey("old-local", for: .other)

        form.select(.claude)
        form.key = "  sk-ant-test  "
        XCTAssertTrue(form.connect())
        XCTAssertNil(form.error)
        XCTAssertEqual(store.connectedProvider, .claude)
        XCTAssertTrue(keychain.hasKey(for: .claude))
        XCTAssertFalse(keychain.hasKey(for: .chatGPT), "one provider at a time")
        XCTAssertFalse(keychain.hasKey(for: .google))
        XCTAssertFalse(keychain.hasKey(for: .other))
        XCTAssertEqual(keychain.readCount, 0, "connecting stores the key; it never reads one")
        XCTAssertEqual(form.key, "", "a typed key never lingers in the form")
        XCTAssertEqual(form.paneState, .connected)

        // Switching provider replaces the connection and its key.
        form.select(.google)
        form.key = "g-test"
        XCTAssertTrue(form.connect())
        XCTAssertEqual(store.connectedProvider, .google)
        XCTAssertFalse(keychain.hasKey(for: .claude))
        XCTAssertTrue(keychain.hasKey(for: .google))

        // An empty key is refused and stores nothing.
        form.select(.chatGPT)
        XCTAssertFalse(form.connect())
        XCTAssertEqual(form.error, .missingKey)
        XCTAssertEqual(store.connectedProvider, .google)
    }

    func testDisconnectRemovesKey() throws {
        let (form, store, keychain) = makeForm()
        form.select(.chatGPT)
        form.key = "sk-test"
        XCTAssertTrue(form.connect())
        XCTAssertTrue(keychain.hasKey(for: .chatGPT))

        form.disconnect()
        XCTAssertNil(store.connectedProvider)
        XCTAssertFalse(store.isConnected)
        for provider in AIProvider.allCases {
            XCTAssertFalse(keychain.hasKey(for: provider), "\(provider)")
        }
        XCTAssertEqual(form.paneState, .needsKey(reconnect: false))
        XCTAssertNil(store.resolvedConnection())
    }

    func testOtherRequiresAddressAndModel() throws {
        try skipUnlessEnglishInterface()
        let (form, store, keychain) = makeForm()
        form.select(.claude)
        XCTAssertFalse(form.showsAddressAndModelFields)
        XCTAssertTrue(form.showsTierPicker)

        form.select(.other)
        XCTAssertTrue(form.showsAddressAndModelFields, "Other has an address and a model")
        XCTAssertFalse(form.showsTierPicker, "Other's model is what the writer types")

        // No address: refused, nothing stored.
        XCTAssertFalse(form.connect())
        XCTAssertEqual(form.error, .invalidAddress)
        XCTAssertNil(store.connectedProvider)

        // Plain http to another machine: refused, in iPhone words.
        form.address = "http://192.168.1.5:1234/v1"
        XCTAssertFalse(form.connect())
        XCTAssertEqual(form.error, .insecureAddress)
        XCTAssertEqual(form.error?.message,
                       "Plain http:// is only allowed for a server on this iPhone. Use https:// for other addresses.")
        XCTAssertNil(store.connectedProvider)

        form.address = "https://ai.example.com/v1"
        form.model = "llama3.3"
        XCTAssertTrue(form.connect())
        XCTAssertEqual(store.connectedProvider, .other)
        XCTAssertEqual(store.otherEndpoint?.absoluteString, "https://ai.example.com/v1/chat/completions")
        let connection = try XCTUnwrap(store.resolvedConnection())
        XCTAssertEqual(connection.model, "llama3.3")
        XCTAssertFalse(keychain.hasKey(for: .other), "Other's key is optional")
    }

    func testNoMacWordingInConnectStrings() throws {
        try skipUnlessEnglishInterface()
        let mac = try NSRegularExpression(pattern: "\\bMac(s|’s|'s)?\\b")
        func check(_ text: String, _ context: String) {
            let range = NSRange(text.startIndex..., in: text)
            XCTAssertNil(mac.firstMatch(in: text, range: range), "\(context) names a Mac: \(text)")
            XCTAssertFalse(text.contains("Lineform ▸"), "\(context) points at the Mac's menu bar: \(text)")
        }
        let english = ConnectAIFormModel.allDisplayedStrings
        XCTAssertTrue(english.contains("Use a model you run yourself — Ollama, LM Studio, llama.cpp — or any OpenAI-compatible server."))
        XCTAssertTrue(english.contains("Connect your AI again in Menu ▸ Settings ▸ Connect Your AI…."))
        for text in english { check(text, "en") }

        // Every language, from the package catalog the strings live in.
        let catalog = try Self.packageCatalog()
        var checked = 0
        for text in english {
            guard let entry = catalog[text] as? [String: Any],
                  let localizations = entry["localizations"] as? [String: [String: Any]] else { continue }
            checked += 1
            for (language, localization) in localizations {
                if let value = (localization["stringUnit"] as? [String: Any])?["value"] as? String {
                    check(value, language)
                }
            }
        }
        XCTAssertGreaterThan(checked, 10, "the strings are the package's, with their translations")

        // The runtime values too, per language.
        for language in ["es", "fr", "de", "ja", "zh-Hans"] {
            let bundle = try XCTUnwrap(Bundle.lineformCore.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)))
            let note = ConnectAIPresentation.billingNote(for: .other, bundle: bundle)
            XCTAssertNotEqual(note, ConnectAIPresentation.billingNote(for: .other), "\(language) is translated")
            check(note, language)
            check(AIActionController.reconnectMessage(bundle: bundle), language)
            check(AIConnectError.insecureAddress.message(bundle: bundle), language)
        }
    }

    /// The Settings note says everything that can be sent: the passage or the whole document, the
    /// comment typed, and for Find the sentences involved (fix after the step 8 review), in every
    /// language.
    func testSettingsNoteNamesCommentAndFindSentences() throws {
        try skipUnlessEnglishInterface()
        let note = SettingsSection.connectAINote
        XCTAssertEqual(note, "Rewrite and proofread with an AI account of your own. Only the passage you select is sent, or the whole document when you choose Ask AI for it, with any comment you type. For Find, that is each whole sentence your selection touches, or every sentence of the document. Nothing is sent until you choose an action.")
        for language in ["es", "fr", "de", "ja", "zh-Hans"] {
            let bundle = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)))
            let localized = bundle.localizedString(forKey: note, value: nil, table: nil)
            XCTAssertNotEqual(localized, note, "\(language) has the new note")
            XCTAssertFalse(localized.contains("Mac"), language)
        }
    }

    /// Menu ▸ Settings ▸ Connect Your AI… opens the sheet.
    func testSettingsRowOpensConnectYourAI() async throws {
        let (_, store, _) = makeForm()
        let suite = "ConnectAITests-settings-\(UUID().uuidString)"
        suites.append(suite)
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        let window = try host(SettingsSection(settings: settings, aiStore: store))
        try await spin { Self.element(SettingsSection.connectAITitle, in: window, containing: true) != nil }
        let row = try XCTUnwrap(Self.element(SettingsSection.connectAITitle, in: window, containing: true))
        XCTAssertTrue(row.accessibilityActivate())
        try await spin { window.rootViewController?.presentedViewController != nil }
        try await spin { Self.element(ConnectAIPresentation.connectButtonTitle(for: .claude, otherHost: nil), in: window.rootViewController?.presentedViewController?.view ?? window) != nil }
    }

    // MARK: - Helpers

    private func makeForm() -> (ConnectAIFormModel, AIConnectionStore, InMemoryAIKeychain) {
        let suite = "ConnectAITests-\(UUID().uuidString)"
        suites.append(suite)
        let keychain = InMemoryAIKeychain()
        let store = AIConnectionStore(defaults: UserDefaults(suiteName: suite)!, keychain: keychain)
        return (ConnectAIFormModel(store: store), store, keychain)
    }

    static func packageCatalog() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Packages/LineformCore/Sources/LineformCore/Resources/Localizable.xcstrings")
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return try XCTUnwrap(root["strings"] as? [String: Any])
    }

    private func host(_ view: some View) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        self.window = window
        return window
    }

    private func spin(timeout: TimeInterval = 3, until condition: () -> Bool,
                      file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out", file: file, line: line)
                return
            }
            try await Task.sleep(for: .milliseconds(20))
            window?.layoutIfNeeded()
        }
    }

    /// The accessibility element labelled exactly `label` (or containing it).
    static func element(_ label: String, in root: NSObject, containing: Bool = false, depth: Int = 0) -> NSObject? {
        guard depth < 60 else { return nil }
        if let own = root.accessibilityLabel, containing ? own.contains(label) : own == label, !(root is UIWindow) {
            return root
        }
        var children: [NSObject] = []
        if let view = root as? UIView { children += view.subviews }
        if let elements = root.accessibilityElements as? [NSObject] { children += elements }
        let count = root.accessibilityElementCount()
        if count != NSNotFound, count > 0 {
            for index in 0..<count {
                if let element = root.accessibilityElement(at: index) as? NSObject { children.append(element) }
            }
        }
        for child in children where child !== root {
            if let found = element(label, in: child, containing: containing, depth: depth + 1) { return found }
        }
        return nil
    }
}
