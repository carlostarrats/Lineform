import LineformCore
import SwiftUI

/// The Menu sheet's Settings: four switches, each with a short note, worded for iPhone (the
/// Mac's notes name a Mac and a sidebar). The values are `AppSettings`, per device, under the
/// Mac's keys.
///
/// Below the switches, Connect Your AI… opens `ConnectAISheet` over the sheet. Then Clear History
/// (the Mac's row, note and confirmation): it removes every document's saved versions — on this
/// iPhone and, for documents in the Lineform iCloud folder, everywhere they sync — and leaves the
/// files alone. Check for Updates arrives with roadmap step 12.
struct SettingsSection: View {
    @ObservedObject var settings: AppSettings
    /// The one AI connection (`AIConnectionStore.shared` in the app). Reading it reads
    /// UserDefaults only; the Keychain is never read here.
    @ObservedObject var aiStore: AIConnectionStore
    /// The store Clear History empties: the app's one History store.
    var historyStore: PassageHistoryPersisting
    /// Made fresh each time Connect Your AI… is tapped, so a typed key never outlives the sheet.
    @State private var connectForm: ConnectAIFormModel?
    @State private var isConfirmingClearHistory = false
    var usesDarkChrome = false

    init(
        settings: AppSettings,
        aiStore: AIConnectionStore = .shared,
        historyStore: PassageHistoryPersisting = PhoneHistoryController.sharedStore,
        usesDarkChrome: Bool = false
    ) {
        self.settings = settings
        self.aiStore = aiStore
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

    /// Every switch's title, in order, then Clear History. (Connect Your AI… sits between them; it
    /// is a navigation row with its own `connectAITitle`.)
    static var rowTitles: [String] { rows.map(\.title) + [clearHistoryTitle] }

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
        List {
            ForEach(Self.rows) { row in
                Toggle(isOn: Binding(
                    get: { settings[keyPath: row.value] },
                    set: { settings[keyPath: row.value] = $0 }
                )) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.title)
                        Text(row.note)
                            .font(.footnote)
                            .opacity(0.6)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
                .listRowBackground(Color.clear)
            }
            Button {
                connectForm = ConnectAIFormModel(store: aiStore)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(Self.connectAITitle)
                        Text(Self.connectAINote)
                            .font(.footnote)
                            .opacity(0.6)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if let provider = aiStore.connectedProvider {
                        Text(verbatim: provider.displayName)
                            .font(.footnote)
                            .opacity(0.6)
                    }
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .opacity(0.35)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)
            .listRowBackground(Color.clear)
            .accessibilityIdentifier("settings.connectAI")
            clearHistoryRow
                .padding(.vertical, 4)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .sheet(item: $connectForm) { form in
            ConnectAISheet(form: form, usesDarkChrome: usesDarkChrome) { connectForm = nil }
        }
    }

    private var clearHistoryRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(Self.clearHistoryTitle)
                Text(Self.clearHistoryNote)
                    .font(.footnote)
                    .opacity(0.6)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityHidden(true)
            Spacer(minLength: 0)
            Button(Self.clearHistoryButtonTitle, role: .destructive) {
                isConfirmingClearHistory = true
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(Self.clearHistoryTitle)
            .accessibilityHint(Self.clearHistoryNote)
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
}
