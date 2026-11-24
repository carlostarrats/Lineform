import LineformCore
import SwiftUI

/// The Menu sheet's Settings: four switches, each with a short note, worded for iPhone (the
/// Mac's notes name a Mac and a sidebar). The values are `AppSettings`, per device, under the
/// Mac's keys.
///
/// Below the switches, Connect Your AI… opens `ConnectAISheet` over the sheet. Then Clear History
/// (the Mac's row, note and confirmation): it removes every document's saved versions — on this
/// iPhone and, for documents in the Lineform iCloud folder, everywhere they sync — and leaves the
/// files alone. Last, Check for Updates… (`PhoneUpdateCommand`): one App Store lookup when the writer
/// taps it, then one alert that can open the App Store page.
struct SettingsSection: View {
    @ObservedObject var settings: AppSettings
    /// The one AI connection (`AIConnectionStore.shared` in the app). Reading it reads
    /// UserDefaults only; the Keychain is never read here.
    @ObservedObject var aiStore: AIConnectionStore
    /// Check for Updates… (`PhoneUpdateCommand.shared` in the app).
    @ObservedObject var updateCommand: PhoneUpdateCommand
    /// The store Clear History empties: the app's one History store.
    var historyStore: PassageHistoryPersisting
    /// Made fresh each time Connect Your AI… is tapped, so a typed key never outlives the sheet.
    @State private var connectForm: ConnectAIFormModel?
    @State private var isConfirmingClearHistory = false
    var usesDarkChrome = false
    @Environment(\.menuTheme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(
        settings: AppSettings,
        aiStore: AIConnectionStore = .shared,
        historyStore: PassageHistoryPersisting = PhoneHistoryController.sharedStore,
        updateCommand: PhoneUpdateCommand = .shared,
        usesDarkChrome: Bool = false
    ) {
        self.settings = settings
        self.aiStore = aiStore
        self.updateCommand = updateCommand
        self.historyStore = historyStore
        self.usesDarkChrome = usesDarkChrome
    }

    static var connectAITitle: String { String(localized: "Connect Your AI…") }
    static var connectAINote: String {
        String(localized: "Rewrite and proofread with an AI account of your own. Only the passage you select is sent, or the whole document when you choose Ask AI for it, with any comment you type. For Find, that is each whole sentence your selection touches, or every sentence of the document. Nothing is sent until you choose an action.")
    }

    // MARK: Clear History (the Mac's strings)

    static var clearHistoryTitle: String { String(localized: "Clear History") }
    static var clearHistoryNote: String { String(localized: "Removes saved versions for every document. Your files are not changed.") }
    static var clearHistoryButtonTitle: String { String(localized: "Clear…") }
    static var clearHistoryConfirmTitle: String { String(localized: "Clear all history?") }
    static var clearHistoryConfirmMessage: String {
        String(localized: "Saved versions for every document will be removed. This can't be undone. Your files are not changed.")
    }
    static var cancelTitle: String { String(localized: "Cancel") }
    static var notConnectedText: String { String(localized: "Not connected") }

    /// Connect Your AI…'s value for VoiceOver: the connected provider, or that none is.
    static func connectAIAccessibilityValue(providerName: String?) -> String {
        providerName ?? notConnectedText
    }

    // MARK: Check for Updates (the Mac's title)

    static var checkForUpdatesTitle: String { String(localized: "Check for Updates…") }
    static var checkForUpdatesNote: String {
        String(localized: "Asks the App Store whether a newer version of Lineform is out. Nothing about you or your documents is sent.")
    }

    /// Every switch's title, in order, then Clear History and Check for Updates…. (Connect Your
    /// AI… sits between them; it is a navigation row with its own `connectAITitle`.)
    static var rowTitles: [String] { rows.map(\.title) + [clearHistoryTitle, checkForUpdatesTitle] }

    /// The confirmed Clear History: empties the store, and every History controller on it
    /// re-reads it (leaving History mode first), so nothing open writes the cleared history back.
    static func clearHistory(store: PassageHistoryPersisting, center: NotificationCenter = .default) {
        PhoneHistoryController.clearAllHistory(in: store, center: center)
    }

    /// One switch: its title, its note, and the setting it changes.
    struct Row: Identifiable {
        var id: String
        var title: String
        var note: String
        var value: ReferenceWritableKeyPath<AppSettings, Bool>
    }

    static var rows: [Row] {
        [
            Row(
                id: "automaticDarkMode",
                title: String(localized: "Automatic Dark Mode"),
                note: String(localized: "Goes dark when your iPhone is in Dark Mode, including at night if its appearance is set to Automatic."),
                value: \.automaticDarkMode
            ),
            Row(
                id: "showICloud",
                title: String(localized: "Show iCloud in Files"),
                note: String(localized: "When off, Files hides Lineform’s iCloud folder. New documents still save there."),
                value: \.showICloudInFiles
            ),
            Row(
                id: "checksSpelling",
                title: String(localized: "Check spelling while typing"),
                note: String(localized: "Misspellings underline as you type. Nothing is autocorrected."),
                value: \.checksSpellingWhileTyping
            ),
            Row(
                id: "announcements",
                title: String(localized: "In-app notifications"),
                note: String(localized: "Occasional news about new versions, checked once a day. Nothing about you or your documents is sent. When off, Lineform makes no automatic network request."),
                value: \.checksForAnnouncements
            ),
        ]
    }

    var body: some View {
        let ink = PhoneInk.menu(theme)
        List {
            ForEach(Self.rows) { row in
                toggleRow(row, ink: ink)
                    .padding(.vertical, 4)
                    .listRowBackground(Color.clear)
            }
            Button {
                connectForm = ConnectAIFormModel(store: aiStore)
            } label: {
                connectAILabel(ink: ink)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)
            .listRowBackground(Color.clear)
            // One stop: the title, then the provider (or Not connected); the note is the hint.
            .accessibilityLabel(Text(Self.connectAITitle))
            .accessibilityValue(Text(Self.connectAIAccessibilityValue(providerName: aiStore.connectedProvider?.displayName)))
            .accessibilityHint(Text(Self.connectAINote))
            .accessibilityIdentifier("settings.connectAI")
            clearHistoryRow
                .padding(.vertical, 4)
                .listRowBackground(Color.clear)
            checkForUpdatesRow
                .padding(.vertical, 4)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .sheet(item: $connectForm) { form in
            ConnectAISheet(form: form, usesDarkChrome: usesDarkChrome) { connectForm = nil }
        }
    }

    /// A switch, its title and its note. VoiceOver reads the title as the label and the note as
    /// the hint, not the whole note as the label. At accessibility sizes the switch goes under
    /// the text, which would otherwise be squeezed into a narrow column beside it.
    @ViewBuilder
    private func toggleRow(_ row: Row, ink: PhoneInk) -> some View {
        let isOn = Binding(
            get: { settings[keyPath: row.value] },
            set: { settings[keyPath: row.value] = $0 }
        )
        let text = VStack(alignment: .leading, spacing: 3) {
            Text(row.title)
            Text(row.note)
                .font(.footnote)
                .foregroundStyle(ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                text
                    .accessibilityHidden(true)
                Toggle(isOn: isOn) { Text(row.title) }
                    .labelsHidden()
                    .accessibilityLabel(Text(row.title))
                    .accessibilityHint(Text(row.note))
            }
        } else {
            Toggle(isOn: isOn) { text }
                .accessibilityLabel(Text(row.title))
                .accessibilityHint(Text(row.note))
        }
    }

    @ViewBuilder
    private func connectAILabel(ink: PhoneInk) -> some View {
        let text = VStack(alignment: .leading, spacing: 3) {
            Text(Self.connectAITitle)
            Text(Self.connectAINote)
                .font(.footnote)
                .foregroundStyle(ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        let provider = aiStore.connectedProvider.map { provider in
            Text(verbatim: provider.displayName)
                .font(.footnote)
                .foregroundStyle(ink.secondary)
        }
        let chevron = Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(ink.icon)
        if dynamicTypeSize.isAccessibilitySize {
            // The note keeps the line's width; the provider and the chevron go under it.
            VStack(alignment: .leading, spacing: 6) {
                text
                HStack(spacing: 8) {
                    provider
                    Spacer(minLength: 0)
                    chevron
                }
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                text
                Spacer(minLength: 0)
                provider
                chevron
            }
        }
    }

    private var clearHistoryRow: some View {
        let text = VStack(alignment: .leading, spacing: 3) {
            Text(Self.clearHistoryTitle)
            Text(Self.clearHistoryNote)
                .font(.footnote)
                .foregroundStyle(PhoneInk.menu(theme).secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityHidden(true)
        let button = Button(Self.clearHistoryButtonTitle, role: .destructive) {
            isConfirmingClearHistory = true
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(Self.clearHistoryTitle)
        .accessibilityHint(Self.clearHistoryNote)
        return Group {
            // At accessibility sizes Clear… goes under the note instead of squeezing it.
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    text
                    button
                }
            } else {
                HStack(alignment: .center, spacing: 12) {
                    text
                    Spacer(minLength: 0)
                    button
                }
            }
        }
        .alert(Self.clearHistoryConfirmTitle, isPresented: $isConfirmingClearHistory) {
            Button(Self.cancelTitle, role: .cancel) {}
            Button(Self.clearHistoryTitle, role: .destructive) {
                Self.clearHistory(store: historyStore)
            }
        } message: {
            Text(Self.clearHistoryConfirmMessage)
        }
    }

    /// One lookup per tap; a tap while a check runs (or its alert is up) does nothing, and the
    /// row shows a spinner meanwhile.
    private var checkForUpdatesRow: some View {
        Button {
            Task { await updateCommand.run() }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(Self.checkForUpdatesTitle)
                    Text(Self.checkForUpdatesNote)
                        .font(.footnote)
                        .opacity(0.6)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if updateCommand.isChecking {
                    ProgressView()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(updateCommand.isChecking)
        .accessibilityIdentifier("settings.checkForUpdates")
    }
}
