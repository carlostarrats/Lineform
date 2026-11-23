import LineformCore
import SwiftUI

/// The state behind Connect Your AI on iPhone (Menu ▸ Settings ▸ Connect Your AI…): the provider
/// picked, what the writer typed, and the last refusal. The decisions are `ConnectAIPresentation`
/// and `AIConnectionStore`, the Mac's own; only the layout is the iPhone's.
///
/// Opening the sheet makes no network request and never reads a key. Its one Keychain call is the
/// store's presence check (`connectedKeyIsMissing`), so a provider whose key went missing shows the
/// key field again instead of a "Connected" that would fail at the first action. A model is made
/// fresh for each presentation, so a typed key never lingers after the sheet closes.
@MainActor
final class ConnectAIFormModel: ObservableObject, Identifiable {
    let store: AIConnectionStore

    @Published private(set) var selection: AIProvider
    @Published var key = ""
    @Published var address = ""
    @Published var model = ""
    @Published private(set) var error: AIConnectError?
    @Published private(set) var keyMissing = false

    init(store: AIConnectionStore) {
        self.store = store
        selection = store.connectedProvider ?? .claude
    }

    /// The presence check, each time the sheet appears.
    func appear() {
        keyMissing = store.connectedKeyIsMissing()
    }

    /// A different provider starts with empty fields and no refusal.
    func select(_ provider: AIProvider) {
        guard provider != selection else { return }
        selection = provider
        key = ""
        address = ""
        model = ""
        error = nil
    }

    var paneState: ConnectAIPaneState {
        ConnectAIPresentation.paneState(for: selection, connectedProvider: store.connectedProvider, keyMissing: keyMissing)
    }

    /// The consent step names what is sent and to whom, in full: "Connect — Lineform will send the
    /// text you choose to …".
    var connectTitle: String {
        ConnectAIPresentation.connectButtonTitle(for: selection, otherHost: ConnectAIPresentation.host(fromAddress: address))
    }

    /// Other is an address, an optional key and a model; the big three are a key and a tier.
    var showsAddressAndModelFields: Bool { selection == .other }
    var showsTierPicker: Bool { selection.model(for: .standard) != nil }

    /// The consent step. Stores the key (and Other's address and model), deleting every other
    /// provider's key; makes no request. True when connected.
    @discardableResult
    func connect() -> Bool {
        let result: AIConnectError?
        if selection == .other {
            result = store.connectOther(address: address, key: key, model: model)
        } else {
            result = store.connect(selection, key: key)
        }
        error = result
        guard result == nil else { return false }
        key = ""
        address = ""
        model = ""
        keyMissing = false
        return true
    }

    /// Removes every key and the connection.
    func disconnect() {
        store.disconnect()
        keyMissing = false
        error = nil
    }

    /// Everything Connect Your AI and the AI messages can show on iPhone, in English, for the
    /// no-Mac-wording tests.
    static var allDisplayedStrings: [String] {
        var strings = [
            ConnectAIPresentation.title, ConnectAIPresentation.createKeyTitle, ConnectAIPresentation.keyLabel,
            ConnectAIPresentation.addressLabel, ConnectAIPresentation.optionalKeyLabel,
            ConnectAIPresentation.optionalModelLabel, ConnectAIPresentation.connectedText,
            ConnectAIPresentation.disconnectTitle, ConnectAIPresentation.reconnectNote,
            ConnectAIPresentation.privacyNote, ConnectAIPresentation.modelTierLabel,
            ConnectAIPresentation.connectButtonTitle(for: .other, otherHost: nil),
            AIActionController.reconnectMessage,
            SettingsSection.connectAITitle, SettingsSection.connectAINote,
        ]
        for provider in AIProvider.allCases {
            strings.append(provider.displayName)
            strings.append(ConnectAIPresentation.billingNote(for: provider))
            if let guidance = ConnectAIPresentation.keyGuidance(for: provider) { strings.append(guidance) }
            if provider != .other {
                strings.append(ConnectAIPresentation.connectButtonTitle(for: provider, otherHost: nil))
            }
        }
        strings += AIModelTier.allCases.map(\.title)
        strings += [AIConnectError.missingKey, .invalidAddress, .insecureAddress, .keychainFailed].map(\.message)
        return strings
    }
}

/// Connect Your AI on iPhone: a form sheet over the Menu sheet. The provider at the top (Claude,
/// ChatGPT, Google, Other), its billing note, then either "Connected" with the tier and Disconnect,
/// or the key field (Other: address, optional key, model), the privacy note and the consent button.
struct ConnectAISheet: View {
    @ObservedObject var form: ConnectAIFormModel
    /// Observed too: the tier lives in the store.
    @ObservedObject private var store: AIConnectionStore
    var usesDarkChrome: Bool
    var onDone: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The Form's readable inks for the sheet's forced scheme. The `form*` roles depend only on
    /// light or dark (a Form draws the system's cells), so a built-in theme of that darkness
    /// stands in for the writer's.
    private var ink: PhoneInk { Self.ink(usesDarkChrome: usesDarkChrome) }

    static func ink(usesDarkChrome: Bool) -> PhoneInk {
        PhoneInk(theme: usesDarkChrome ? .night : .system, userInterfaceStyle: usesDarkChrome ? .dark : .light)
    }

    /// Four providers do not fit a segmented control at accessibility sizes (it neither wraps
    /// nor scales): there the provider is a menu.
    static func usesProviderMenu(at size: DynamicTypeSize) -> Bool { size.isAccessibilitySize }

    init(form: ConnectAIFormModel, usesDarkChrome: Bool, onDone: @escaping () -> Void) {
        self.form = form
        _store = ObservedObject(wrappedValue: form.store)
        self.usesDarkChrome = usesDarkChrome
        self.onDone = onDone
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    providerPicker
                } footer: {
                    Text(ConnectAIPresentation.billingNote(for: form.selection))
                        .foregroundStyle(ink.color(.formFooter))
                }

                switch form.paneState {
                case .connected:
                    connectedSections
                case .needsKey(let reconnect):
                    keySections(reconnect: reconnect)
                }
            }
            .navigationTitle(ConnectAIPresentation.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done"), action: onDone)
                }
            }
        }
        .environment(\.colorScheme, usesDarkChrome ? .dark : .light)
        .onAppear { form.appear() }
    }

    @ViewBuilder
    private var connectedSections: some View {
        Section {
            Label(ConnectAIPresentation.connectedText, systemImage: "checkmark.circle.fill")
                .foregroundStyle(ink.color(.formSuccess))
                .accessibilityIdentifier("connectAI.connected")
            if form.showsTierPicker { tierPicker }
            if form.selection == .other, let endpoint = store.otherEndpoint {
                Text(verbatim: endpoint.absoluteString)
                    .font(.footnote)
                    .foregroundStyle(ink.color(.formSecondary))
                    .textSelection(.enabled)
            }
        }
        Section {
            Button(ConnectAIPresentation.disconnectTitle, role: .destructive) { form.disconnect() }
                .accessibilityIdentifier("connectAI.disconnect")
        }
    }

    @ViewBuilder
    private func keySections(reconnect: Bool) -> some View {
        Section {
            if reconnect {
                Text(ConnectAIPresentation.reconnectNote)
            }
            if form.showsAddressAndModelFields {
                TextField(ConnectAIPresentation.addressLabel, text: $form.address,
                          prompt: Text(verbatim: "https://example.com/v1"))
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel(ConnectAIPresentation.addressLabel)
                    .accessibilityIdentifier("connectAI.address")
                SecureField(ConnectAIPresentation.optionalKeyLabel, text: $form.key)
                    .accessibilityIdentifier("connectAI.key")
                TextField(ConnectAIPresentation.optionalModelLabel, text: $form.model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("connectAI.model")
            } else {
                if let url = form.selection.createKeyURL {
                    Link(ConnectAIPresentation.createKeyTitle, destination: url)
                }
                SecureField(ConnectAIPresentation.keyLabel, text: $form.key)
                    .accessibilityIdentifier("connectAI.key")
            }
        } footer: {
            if let guidance = ConnectAIPresentation.keyGuidance(for: form.selection) {
                Text(guidance)
                    .foregroundStyle(ink.color(.formFooter))
            }
        }
        if form.showsTierPicker {
            Section { tierPicker }
        }
        Section {
            if let error = form.error {
                Text(error.message)
                    .foregroundStyle(ink.color(.formDestructive))
                    .accessibilityIdentifier("connectAI.error")
            }
            Button(form.connectTitle) { connect() }
                .accessibilityIdentifier("connectAI.connect")
        } footer: {
            Text(ConnectAIPresentation.privacyNote)
                .foregroundStyle(ink.color(.formFooter))
        }
    }

    /// Standard or Higher quality, with the model that tier sends under it (provider identifiers,
    /// shown verbatim). A change while connected takes effect at the next action; no key is read.
    @ViewBuilder
    private var tierPicker: some View {
        let provider = form.selection
        Picker(ConnectAIPresentation.modelTierLabel, selection: Binding(
            get: { store.tier(for: provider) },
            set: { store.setTier($0, for: provider) }
        )) {
            ForEach(AIModelTier.allCases) { tier in
                Text(tier.title).tag(tier)
            }
        }
        .accessibilityIdentifier("connectAI.tier")
        if let model = provider.model(for: store.tier(for: provider)) {
            Text(verbatim: model)
                .font(.footnote)
                .foregroundStyle(ink.color(.formSecondary))
                .accessibilityIdentifier("connectAI.tierModel")
        }
    }

    /// Claude, ChatGPT, Google, Other: segmented, or a menu at accessibility sizes.
    @ViewBuilder
    private var providerPicker: some View {
        let picker = Picker(ConnectAIPresentation.title, selection: Binding(
            get: { form.selection },
            set: { form.select($0) }
        )) {
            ForEach(AIProvider.allCases) { provider in
                Text(provider.displayName).tag(provider)
            }
        }
        if Self.usesProviderMenu(at: dynamicTypeSize) {
            picker
                .pickerStyle(.menu)
                .accessibilityIdentifier("connectAI.provider")
        } else {
            picker
                .pickerStyle(.segmented)
                .accessibilityIdentifier("connectAI.provider")
        }
    }

    /// The consent step, with what happened said aloud: "Connected", or the refusal.
    private func connect() {
        let connected = form.connect()
        if let spoken = Self.connectAnnouncement(connected: connected, error: form.error) {
            UIAccessibility.post(notification: .announcement, argument: spoken)
        }
    }

    /// What VoiceOver hears after Connect.
    static func connectAnnouncement(connected: Bool, error: AIConnectError?) -> String? {
        connected ? ConnectAIPresentation.connectedText : error?.message
    }
}
