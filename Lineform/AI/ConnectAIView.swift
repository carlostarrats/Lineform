import AppKit
import SwiftUI

/// Connect Your AI — opened from Lineform ▸ Connect Your AI…, presented exactly like Settings:
/// a `MuseModalChrome` card over a `MuseModalScrim` inside the main document window
/// (`EditorContainerView`, `EditorAppModal.connectAI`), with the shared header, ✕ and Esc to
/// close. Pick a provider on the left; the right pane holds the key (or Other's address) and the
/// consent button, whose title names what is sent and to whom. Pressing it only stores the key:
/// nothing is sent until the writer chooses an AI action.
///
/// Opening the modal makes no network request and never reads a key. The one Keychain call
/// it makes is a presence check (`AIConnectionStore.connectedKeyIsMissing`), so a provider
/// whose key went missing shows the key field again instead of a "Connected" that would fail
/// at the first action. The view is built fresh on every presentation, so typed keys never
/// linger after it closes and the check runs again each time.
struct ConnectAIView: View {
    /// Wider than Settings (460) so the provider list and the pane fit side by side.
    static let contentWidth: CGFloat = 640
    static let providerColumnWidth: CGFloat = 160
    /// The two columns' height when the window allows; the pane scrolls when it is shorter.
    static let idealBodyHeight: CGFloat = 380
    static let minimumBodyHeight: CGFloat = 140
    /// Card padding (24 × 2), the header row (28) and the gap under it (18), plus a 24pt margin
    /// above and below the card — everything around the two columns.
    static let verticalChrome: CGFloat = 24 * 2 + 28 + 18 + 24 * 2

    /// Clamps to the window like `SettingsModal.cardWidth(availableWidth:)`.
    static func cardWidth(availableWidth: CGFloat) -> CGFloat {
        min(contentWidth, max(280, availableWidth - 24))
    }

    static func bodyHeight(availableHeight: CGFloat) -> CGFloat {
        min(idealBodyHeight, max(minimumBodyHeight, availableHeight - verticalChrome))
    }

    @ObservedObject private var store: AIConnectionStore
    /// THREADED from the theme, never read from `@Environment(\.colorScheme)` — see
    /// `MuseModalChrome.primaryTextColor(usesDarkChrome:)`.
    private let usesDarkChrome: Bool
    /// The window size the presenting container offers (via GeometryReader).
    private let availableSize: CGSize
    private let dismiss: () -> Void

    @State private var selection: AIProvider
    @State private var keyMissing = false
    @State private var key = ""
    @State private var address = ""
    @State private var model = ""
    @State private var error: AIConnectError?

    init(
        store: AIConnectionStore,
        usesDarkChrome: Bool = false,
        availableSize: CGSize = CGSize(width: ConnectAIView.contentWidth + 24, height: 600),
        dismiss: @escaping () -> Void
    ) {
        _store = ObservedObject(wrappedValue: store)
        self.usesDarkChrome = usesDarkChrome
        self.availableSize = availableSize
        self.dismiss = dismiss
        _selection = State(initialValue: store.connectedProvider ?? .claude)
    }

    private var paneState: ConnectAIPaneState {
        ConnectAIPresentation.paneState(for: selection, connectedProvider: store.connectedProvider,
                                        keyMissing: keyMissing)
    }

    private var primaryText: Color { MuseModalChrome.primaryTextColor(usesDarkChrome: usesDarkChrome) }
    private var secondaryText: Color { MuseModalChrome.secondaryTextColor(usesDarkChrome: usesDarkChrome) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Its ✕ carries `.keyboardShortcut(.cancelAction)`: Esc closes, as in Settings.
            // There is deliberately no default button — Return belongs to the fields, where it
            // submits Connect.
            MuseModalHeader(title: ConnectAIPresentation.title, usesDarkChrome: usesDarkChrome, dismiss: dismiss)

            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(AIProvider.allCases) { provider in
                        providerRow(provider)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.trailing, 12)
                .frame(width: Self.providerColumnWidth)

                Divider()

                ScrollView {
                    pane
                        .padding(.leading, 20)
                        .padding(.trailing, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(selection)
            }
            .frame(height: Self.bodyHeight(availableHeight: availableSize.height))
        }
        .museModalCard(
            width: Self.cardWidth(availableWidth: availableSize.width),
            accessibilityLabel: ConnectAIPresentation.title,
            usesDarkChrome: usesDarkChrome
        )
        .accessibilityIdentifier("connectAI.modal")
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
                    .foregroundStyle(primaryText)
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
                .fill(isSelected ? primaryText.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // A plain button swallows the mouse-moved stream `modalArrowCursor` rides on; see
        // `CursorRectView`. Not on the pane: its fields keep their I-beam.
        .background(CursorRectView(cursor: .arrow))
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
                .foregroundStyle(secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            switch paneState {
            case .connected:
                connectedContent
            case .needsKey(let reconnect):
                if reconnect {
                    Text(ConnectAIPresentation.reconnectNote)
                        .font(.callout)
                        .foregroundStyle(primaryText)
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
                    .foregroundStyle(secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Button(connectTitle, action: connect)
                    .buttonStyle(.borderedProminent)
                    .background(CursorRectView(cursor: .arrow))
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
                .foregroundStyle(primaryText)
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
                .foregroundStyle(secondaryText)
                .textSelection(.enabled)
        }
        Button(ConnectAIPresentation.disconnectTitle, action: disconnect)
            .background(CursorRectView(cursor: .arrow))
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
