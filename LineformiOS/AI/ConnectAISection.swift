import LineformCore
import SwiftUI

/// The state behind Connect Your AI on iPhone (the word menu ▸ Connect Your AI): the provider
/// picked, what the writer typed, and the last refusal. The decisions are `ConnectAIPresentation`
/// and `AIConnectionStore`, the Mac's own; only the layout is the iPhone's.
///
/// Opening the sheet makes no network request and never reads a key. Its one Keychain call is the
/// store's presence check (`connectedKeyIsMissing`), so a provider whose key went missing shows the
/// key field again instead of a "Connected" that would fail at the first action. A model is made
/// fresh each time the page appears, so a typed key never lingers after the page closes.
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

    /// The consent step: the button says "Connect"; the small text under it names what is sent and
    /// to whom ("Lineform will send the text you choose to Anthropic."), then the privacy note.
    var connectTitle: String { ConnectAIPresentation.connectTitle }

    var consentNote: String {
        ConnectAIPresentation.consentNote(for: selection, otherHost: ConnectAIPresentation.host(fromAddress: address))
    }

    /// Other is an address, an optional key and a model; the big three are a key and a model
    /// picked from a list.
    var showsAddressAndModelFields: Bool { selection == .other }
    var showsModelPicker: Bool { !selection.models.isEmpty }

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
            ConnectAIPresentation.privacyNote, ConnectAIPresentation.modelLabel,
            ConnectAIPresentation.connectTitle,
            ConnectAIPresentation.recipientNote(for: .other, otherHost: nil),
            AIActionController.reconnectMessage,
            ConnectAISection.title, ConnectAISection.note,
        ]
        for provider in AIProvider.allCases {
            strings.append(provider.displayName)
            strings.append(ConnectAIPresentation.billingNote(for: provider))
            if let guidance = ConnectAIPresentation.keyGuidance(for: provider) { strings.append(guidance) }
            if provider != .other {
                strings.append(ConnectAIPresentation.recipientNote(for: provider, otherHost: nil))
            }
        }
        strings += [AIConnectError.missingKey, .invalidAddress, .insecureAddress, .keychainFailed].map(\.message)
        return strings
    }
}

/// The word menu's Connect Your AI: what is sent, the providers as rows (Claude, ChatGPT, Google,
/// Other; the picked one ticked), its billing note, then either "Connected" with the model,
/// Disconnect and Ask AI… for the whole document, or the key field (Other: address, optional key,
/// model) and the blue Connect pill, with what is sent, to whom and the privacy note in small text
/// under it (the consent step). The Model row names the models ("Claude Sonnet 5.5"). Connecting
/// makes no request.
struct ConnectAISection: View {
    @StateObject private var form: ConnectAIFormModel
    /// Observed too: the connection and the chosen model live in the store.
    @ObservedObject private var store: AIConnectionStore
    var mode: EditorDisplayMode
    var hasText: Bool
    /// Ask AI… for the whole document: the screen closes the menu, then runs the shared policy.
    var onAskAI: () -> Void

    @Environment(\.wordMenuPalette) private var palette
    @Environment(\.openURL) private var openURL

    init(store: AIConnectionStore, mode: EditorDisplayMode = .write, hasText: Bool = false, onAskAI: @escaping () -> Void = {}) {
        _form = StateObject(wrappedValue: ConnectAIFormModel(store: store))
        _store = ObservedObject(wrappedValue: store)
        self.mode = mode
        self.hasText = hasText
        self.onAskAI = onAskAI
    }

    // MARK: - Copy

    static var title: String { WordMenuItem.connectAI.title }
    static var note: String {
        String(localized: "Rewrite and proofread with an AI account of your own. Only the passage you select is sent, or the whole document when you choose Ask AI for it, with any comment you type. For Find, that is each whole sentence your selection touches, or every sentence of the document. Nothing is sent until you choose an action.")
    }
    static var askAITitle: String { String(localized: "Ask AI…") }
    static var askAINote: String { String(localized: "Sends the whole document to your AI, with any comment you type.") }

    /// Ask AI… shows while an AI is connected, an editor is on screen (Read has no editor to hold
    /// the comment field, and allows no AI), and the document has text to send.
    static func showsAskAI(isConnected: Bool, mode: EditorDisplayMode, hasText: Bool) -> Bool {
        isConnected && mode != .read && hasText
    }

    /// The document has something to send: not empty, and not only white space.
    static func hasText(_ text: String) -> Bool {
        ExportPrintSection.hasText(text)
    }

    /// What VoiceOver hears after Connect.
    static func connectAnnouncement(connected: Bool, error: AIConnectError?) -> String? {
        connected ? ConnectAIPresentation.connectedText : error?.message
    }

    // MARK: - Body

    var body: some View {
        WordMenuPageScaffold(title: Self.title) {
            WordMenuNote(text: Self.note)
            VStack(spacing: 6) {
                ForEach(AIProvider.allCases) { provider in
                    providerRow(provider)
                }
            }
            WordMenuNote(text: ConnectAIPresentation.billingNote(for: form.selection))
                .padding(.top, 4)
            switch form.paneState {
            case .connected:
                connected
            case .needsKey(let reconnect):
                keyEntry(reconnect: reconnect)
            }
        }
        .onAppear { form.appear() }
    }

    private func providerRow(_ provider: AIProvider) -> some View {
        let isPicked = form.selection == provider
        return Button {
            form.select(provider)
        } label: {
            HStack {
                Text(verbatim: provider.displayName)
                    .foregroundStyle(palette.color(palette.ink))
                Spacer(minLength: 8)
                if isPicked {
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(palette.color(palette.blueMark))
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: WordMenuMetrics.minimumTarget)
            .background(
                RoundedRectangle(cornerRadius: WordMenuMetrics.rowRadius, style: .continuous)
                    .fill(palette.color(palette.soft))
            )
            .overlay(
                RoundedRectangle(cornerRadius: WordMenuMetrics.rowRadius, style: .continuous)
                    .strokeBorder(palette.color(palette.blueMark), lineWidth: isPicked ? 1.5 : 0)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(WordMenuPressStyle())
        .accessibilityAddTraits(isPicked ? .isSelected : [])
        .accessibilityIdentifier("connectAI.provider.\(provider.rawValue)")
    }

    @ViewBuilder
    private var connected: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .accessibilityHidden(true)
            Text(ConnectAIPresentation.connectedText)
        }
        .foregroundStyle(palette.color(palette.saved))
        .padding(.horizontal, 4)
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("connectAI.connected")
        if form.showsModelPicker { modelPicker }
        if form.selection == .other, let endpoint = store.otherEndpoint {
            Text(verbatim: endpoint.absoluteString)
                .font(.footnote)
                .foregroundStyle(palette.color(palette.secondary))
                .textSelection(.enabled)
                .padding(.horizontal, 4)
        }
        if Self.showsAskAI(isConnected: store.isConnected, mode: mode, hasText: hasText) {
            WordMenuRow(title: Self.askAITitle, note: Self.askAINote, systemImage: "text.bubble", accessory: .none) {
                onAskAI()
            }
            .accessibilityIdentifier("connectAI.askAI")
            .padding(.top, 6)
        }
        WordMenuRow(title: ConnectAIPresentation.disconnectTitle, accessory: .none, isDestructive: true) {
            form.disconnect()
        }
        .accessibilityIdentifier("connectAI.disconnect")
        .padding(.top, 6)
    }

    @ViewBuilder
    private func keyEntry(reconnect: Bool) -> some View {
        if reconnect {
            WordMenuNote(text: ConnectAIPresentation.reconnectNote)
        }
        if form.showsAddressAndModelFields {
            TextField(ConnectAIPresentation.addressLabel, text: $form.address, prompt: Text(verbatim: "https://example.com/v1"))
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel(ConnectAIPresentation.addressLabel)
                .accessibilityIdentifier("connectAI.address")
                .wordMenuField()
            SecureField(ConnectAIPresentation.optionalKeyLabel, text: $form.key)
                .accessibilityIdentifier("connectAI.key")
                .wordMenuField()
            TextField(ConnectAIPresentation.optionalModelLabel, text: $form.model)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("connectAI.model")
                .wordMenuField()
        } else {
            if let url = form.selection.createKeyURL {
                WordMenuRow(title: ConnectAIPresentation.createKeyTitle, accessory: .external) { openURL(url) }
            }
            SecureField(ConnectAIPresentation.keyLabel, text: $form.key)
                .accessibilityIdentifier("connectAI.key")
                .wordMenuField()
        }
        if let guidance = ConnectAIPresentation.keyGuidance(for: form.selection) {
            WordMenuNote(text: guidance)
        }
        if form.showsModelPicker { modelPicker }
        if let error = form.error {
            Text(error.message)
                .font(.subheadline)
                .foregroundStyle(palette.color(palette.destructive))
                .padding(.horizontal, 4)
                .accessibilityIdentifier("connectAI.error")
        }
        WordMenuPrimaryButton(title: form.connectTitle) { connect() }
            .accessibilityHint(Text(form.consentNote))
            .accessibilityIdentifier("connectAI.connect")
        // What is sent, to whom, and the privacy note: small secondary text under the button.
        Text(form.consentNote)
            .font(.footnote)
            .foregroundStyle(palette.color(palette.secondary))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
            .padding(.top, 2)
            .accessibilityIdentifier("connectAI.consentNote")
    }

    /// The model, by its product name ("Claude Sonnet 5.5"), from the provider's list, cheapest
    /// first; the model ID is the stored choice. A change while connected takes effect at the
    /// next action; no key is read.
    @ViewBuilder
    private var modelPicker: some View {
        let provider = form.selection
        let current = store.model(for: provider)?.displayName ?? ""
        Menu {
            Picker(ConnectAIPresentation.modelLabel, selection: Binding(
                get: { store.model(for: provider) },
                set: { picked in if let picked { store.setModel(picked, for: provider) } }
            )) {
                ForEach(provider.models) { option in
                    Text(verbatim: option.displayName).tag(Optional(option))
                }
            }
            .pickerStyle(.inline)
        } label: {
            WordMenuRowLabel(
                title: ConnectAIPresentation.modelLabel,
                accessory: .text(current)
            )
        }
        .buttonStyle(WordMenuPressStyle())
        .accessibilityLabel(ConnectAIPresentation.modelLabel)
        .accessibilityValue(Text(verbatim: current))
        .accessibilityIdentifier("connectAI.modelPicker")
    }

    /// The consent step, with what happened said aloud: "Connected", or the refusal.
    private func connect() {
        let connected = form.connect()
        if let spoken = Self.connectAnnouncement(connected: connected, error: form.error) {
            ChromeAnnouncer.announce(spoken)
        }
    }
}
