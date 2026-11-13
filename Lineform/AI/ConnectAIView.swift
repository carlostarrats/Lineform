import AppKit
import SwiftUI

/// Connect Your AI — one window, opened from Lineform ▸ Connect Your AI…. Pick a provider on
/// the left; the right pane holds the key (or Other's address) and the consent button, whose
/// title names what is sent and to whom. Pressing it only stores the key: nothing is sent
/// until the writer chooses an AI action.
///
/// Opening the window makes no network request and never reads a key. The one Keychain call
/// it makes is a presence check (`AIConnectionStore.connectedKeyIsMissing`), so a provider
/// whose key went missing shows the key field again instead of a "Connected" that would fail
/// at the first action.
struct ConnectAIView: View {
    private enum Layout {
        static let sidebarWidth: CGFloat = 180
        static let windowSize = CGSize(width: 680, height: 460)
    }

    @ObservedObject private var store: AIConnectionStore
    private let onDone: () -> Void

    @State private var selection: AIProvider
    @State private var keyMissing = false
    @State private var key = ""
    @State private var address = ""
    @State private var model = ""
    @State private var error: AIConnectError?

    init(store: AIConnectionStore, onDone: @escaping () -> Void) {
        _store = ObservedObject(wrappedValue: store)
        self.onDone = onDone
        _selection = State(initialValue: store.connectedProvider ?? .claude)
    }

    private var paneState: ConnectAIPaneState {
        ConnectAIPresentation.paneState(for: selection, connectedProvider: store.connectedProvider,
                                        keyMissing: keyMissing)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(ConnectAIPresentation.windowTitle)
                .font(.system(size: 24, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 16)

            Divider()

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(AIProvider.allCases) { provider in
                        providerRow(provider)
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .frame(width: Layout.sidebarWidth)

                Divider()

                ScrollView {
                    pane
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(selection)
            }
            .frame(maxHeight: .infinity)

            Divider()

            HStack {
                Spacer()
                // Not the default button: Return belongs to the fields, where it submits
                // Connect. Esc closes, like ⌘W.
                Button(ConnectAIPresentation.doneTitle, action: onDone)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("connectAI.done")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: Layout.windowSize.width, height: Layout.windowSize.height)
        .accessibilityIdentifier("connectAI.window")
        .onAppear { keyMissing = store.connectedKeyIsMissing() }
    }

    // MARK: - List

    private func providerRow(_ provider: AIProvider) -> some View {
        let isSelected = selection == provider
        let isConnected = ConnectAIPresentation.showsConnectedMark(
            for: provider, connectedProvider: store.connectedProvider, keyMissing: keyMissing)
        return Button {
            select(provider)
        } label: {
            HStack(spacing: 8) {
                Text(provider.displayName)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if isConnected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityLabel(ConnectAIPresentation.connectedText)
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color.primary.opacity(0.10) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("connectAI.provider.\(provider.rawValue)")
    }

    private func select(_ provider: AIProvider) {
        guard provider != selection else { return }
        selection = provider
        key = ""
        address = ""
        model = ""
        error = nil
    }

    // MARK: - Pane

    @ViewBuilder
    private var pane: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(ConnectAIPresentation.billingNote(for: selection))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            switch paneState {
            case .connected:
                connectedContent
            case .needsKey(let reconnect):
                if reconnect {
                    Text(ConnectAIPresentation.reconnectNote)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                fields
                if let error {
                    Text(error.message)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("connectAI.error")
                }
                Text(ConnectAIPresentation.privacyNote)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(connectTitle, action: connect)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("connectAI.connect")
            }
        }
    }

    private var connectTitle: String {
        ConnectAIPresentation.connectButtonTitle(
            for: selection, otherHost: ConnectAIPresentation.host(fromAddress: address))
    }

    @ViewBuilder
    private var fields: some View {
        if selection == .other {
            labeledField(ConnectAIPresentation.addressLabel) {
                TextField(ConnectAIPresentation.addressLabel, text: $address,
                          prompt: Text(verbatim: "http://localhost:11434/v1"))
                    .accessibilityIdentifier("connectAI.address")
                    .onSubmit(connect)
            }
            labeledField(ConnectAIPresentation.optionalKeyLabel) {
                SecureField(ConnectAIPresentation.optionalKeyLabel, text: $key)
                    .accessibilityIdentifier("connectAI.key")
                    .onSubmit(connect)
            }
            labeledField(ConnectAIPresentation.optionalModelLabel) {
                TextField(ConnectAIPresentation.optionalModelLabel, text: $model)
                    .accessibilityIdentifier("connectAI.model")
                    .onSubmit(connect)
            }
        } else {
            if let url = selection.createKeyURL {
                Link(ConnectAIPresentation.createKeyTitle, destination: url)
                    .font(.callout)
            }
            labeledField(ConnectAIPresentation.keyLabel) {
                SecureField(ConnectAIPresentation.keyLabel, text: $key)
                    .accessibilityIdentifier("connectAI.key")
                    .onSubmit(connect)
            }
        }
    }

    private func labeledField<Field: View>(_ label: String, @ViewBuilder field: () -> Field) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.callout)
                .accessibilityHidden(true)
            field()
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
        }
    }

    @ViewBuilder
    private var connectedContent: some View {
        Label(ConnectAIPresentation.connectedText, systemImage: "checkmark.circle.fill")
            .font(.callout.weight(.semibold))
            .foregroundStyle(.green)
        if selection == .other, let endpoint = store.otherEndpoint {
            Text(verbatim: endpoint.absoluteString)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        Button(ConnectAIPresentation.disconnectTitle, action: disconnect)
            .accessibilityIdentifier("connectAI.disconnect")
    }

    // MARK: - Actions

    /// The consent step. Stores the key (and Other's address); makes no request.
    private func connect() {
        let result: AIConnectError?
        if selection == .other {
            result = store.connectOther(address: address, key: key, model: model)
        } else {
            result = store.connect(selection, key: key)
        }
        error = result
        guard result == nil else { return }
        key = ""
        address = ""
        model = ""
        keyMissing = false
    }

    private func disconnect() {
        store.disconnect()
        keyMissing = false
        error = nil
    }
}
