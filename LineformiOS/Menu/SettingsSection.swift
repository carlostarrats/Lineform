import LineformCore
import SwiftUI

/// The word menu's Settings, as the approved mockup (`word-menu.html`, `settings`): single-line
/// rows with no visible description and no icons. First the mockup's three switches (tinted
/// Lineform blue): Automatic Dark Mode, Check spelling while typing, In-app notifications. Then
/// the "Files" group: Show iCloud in Files (only when this device's iCloud container resolves),
/// Show Hidden Folders, and Sort folders by with its value on the right. Then the "History" group's
/// Clear Version History. Each row's explanation is VoiceOver's hint, never drawn text. The values
/// are `AppSettings`, per device, under the Mac's keys. (Check Document Now is the format row's
/// Check Spelling, 2026-11-24.)
///
/// Clear Version History (the Mac's row and confirmation) removes every document's saved
/// versions — on this iPhone and, for documents in the Lineform iCloud folder, everywhere they
/// sync — and leaves the files alone; its confirmation says so.
struct SettingsSection: View {
    @ObservedObject var settings: AppSettings
    var files: FilesStore?
    /// The store Clear History empties: the app's one History store.
    var historyStore: PassageHistoryPersisting
    @State private var isConfirmingClearHistory = false

    init(
        settings: AppSettings,
        files: FilesStore? = nil,
        historyStore: PassageHistoryPersisting = PhoneHistoryController.sharedStore
    ) {
        self.settings = settings
        self.files = files
        self.historyStore = historyStore
    }

    // MARK: Copy (the Mac's strings where the English matches)

    static var filesGroupTitle: String { WordMenuItem.files.title }
    static var historyGroupTitle: String { WordMenuItem.history.title }
    static var clearHistoryTitle: String { String(localized: "Clear Version History") }
    /// Clear Version History's VoiceOver hint.
    static var clearHistoryNote: String { String(localized: "Deletes the earlier versions Lineform kept of passages you changed. Your documents stay exactly as they are.") }
    static var clearHistoryConfirmTitle: String { String(localized: "Clear version history?") }
    static var clearHistoryConfirmMessage: String {
        String(localized: "Earlier versions of passages in every document will be removed. This can't be undone. Your documents aren't changed.")
    }
    static var cancelTitle: String { String(localized: "Cancel") }

    /// Every row's title, in order: the switches, the Files group (Show iCloud in Files when it
    /// shows), then Clear Version History.
    static var rowTitles: [String] {
        rows.map(\.title)
            + [iCloudRow.title, FilesSection.hiddenFoldersTitle, FilesSection.sortMenuTitle]
            + [clearHistoryTitle]
    }

    /// The confirmed Clear History: empties the store, and every History controller on it
    /// re-reads it (leaving History mode first), so nothing open writes the cleared history back.
    static func clearHistory(store: PassageHistoryPersisting, center: NotificationCenter = .default) {
        PhoneHistoryController.clearAllHistory(in: store, center: center)
    }

    /// One switch: its title, its explanation (VoiceOver's hint), and the setting it changes.
    struct Row: Identifiable {
        var id: String
        var title: String
        var note: String
        var value: ReferenceWritableKeyPath<AppSettings, Bool>
    }

    /// The mockup's three switches, in its order.
    static var rows: [Row] {
        [
            Row(
                id: "automaticDarkMode",
                title: String(localized: "Automatic Dark Mode"),
                note: String(localized: "Goes dark when your iPhone is in Dark Mode, including at night if its appearance is set to Automatic."),
                value: \.automaticDarkMode
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

    /// Show iCloud in Files, first in the Files group, only when iCloud resolves.
    static var iCloudRow: Row {
        Row(
            id: "showICloud",
            title: String(localized: "Show iCloud in Files"),
            note: String(localized: "When off, Files hides Lineform’s iCloud folder. New documents still save there."),
            value: \.showICloudInFiles
        )
    }

    /// The Files group's switches: Show iCloud in Files only when this device's iCloud container
    /// resolves (never in Debug, which has no iCloud entitlement).
    static func shownFilesRows(iCloudAvailable: Bool) -> [Row] {
        iCloudAvailable ? [iCloudRow] : []
    }

    var body: some View {
        WordMenuPageScaffold(title: WordMenuItem.settings.title) {
            ForEach(Self.rows) { row in toggle(row) }
            if let files {
                WordMenuGroupLabel(title: Self.filesGroupTitle)
                ForEach(Self.shownFilesRows(iCloudAvailable: files.isICloudAvailable == true)){ row in toggle(row) }
                WordMenuToggleRow(
                    title: FilesSection.hiddenFoldersTitle,
                    note: nil,
                    isOn: Binding(
                        get: { files.showsHidden },
                        set: { shows in Task { await files.setShowsHidden(shows) } }
                    )
                )
                sortMenu(files)
            }
            WordMenuGroupLabel(title: Self.historyGroupTitle)
            WordMenuRow(title: Self.clearHistoryTitle, accessory: .none, isDestructive: true) {
                isConfirmingClearHistory = true
            }
            .accessibilityHint(Text(Self.clearHistoryNote))
            .accessibilityIdentifier("settings.clearHistory")
        }
        .task { await files?.lookUpICloudAvailability() }
        .alert(Self.clearHistoryConfirmTitle, isPresented: $isConfirmingClearHistory) {
            Button(Self.cancelTitle, role: .cancel) {}
            Button(Self.clearHistoryTitle, role: .destructive) {
                Self.clearHistory(store: historyStore)
            }
        } message: {
            Text(Self.clearHistoryConfirmMessage)
        }
    }

    /// A single-line switch; its explanation is only VoiceOver's hint.
    private func toggle(_ row: Row) -> some View {
        WordMenuToggleRow(
            title: row.title,
            note: nil,
            hint: row.note,
            isOn: Binding(
                get: { settings[keyPath: row.value] },
                set: { settings[keyPath: row.value] = $0 }
            )
        )
        .accessibilityIdentifier("settings.\(row.id)")
    }

    private func sortMenu(_ files: FilesStore) -> some View {
        Menu {
            // An inline Picker, so the checkmark sits in the system's selection gutter.
            Picker(FilesSection.sortMenuTitle, selection: Binding(
                get: { files.sortOrder },
                set: { order in Task { await files.setSort(order) } }
            )) {
                ForEach(FilesSection.sortOptions) { order in
                    Text(order.title).tag(order)
                }
            }
            .pickerStyle(.inline)
        } label: {
            WordMenuRowLabel(
                title: FilesSection.sortMenuTitle,
                accessory: .text(files.sortOrder.title)
            )
        }
        .buttonStyle(WordMenuPressStyle())
        .accessibilityLabel(FilesSection.sortMenuTitle)
        .accessibilityValue(files.sortOrder.title)
    }
}
