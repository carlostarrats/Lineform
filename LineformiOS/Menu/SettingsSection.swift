import LineformCore
import SwiftUI

/// The word menu's Settings: four switches (tinted Lineform blue), each with a short note worded
/// for iPhone (the Mac's notes name a Mac and a sidebar), then the Files settings (Show Hidden
/// Folders and the sort) and Clear History. The values are `AppSettings`, per device, under the
/// Mac's keys. (Check Document Now is the format row's Check Spelling, 2026-11-24.)
///
/// Clear History (the Mac's row, note and confirmation) removes every
/// document's saved versions — on this iPhone and, for documents in the Lineform iCloud folder,
/// everywhere they sync — and leaves the files alone.
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
    static var clearHistoryTitle: String { String(localized: "Clear History") }
    static var clearHistoryNote: String { String(localized: "Removes saved versions for every document. Your files are not changed.") }
    static var clearHistoryButtonTitle: String { String(localized: "Clear…") }
    static var clearHistoryConfirmTitle: String { String(localized: "Clear all history?") }
    static var clearHistoryConfirmMessage: String {
        String(localized: "Saved versions for every document will be removed. This can't be undone. Your files are not changed.")
    }
    static var cancelTitle: String { String(localized: "Cancel") }

    /// Every switch's title, in order, then Clear History.
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
        WordMenuPageScaffold(title: WordMenuItem.settings.title) {
            ForEach(Self.rows) { row in
                WordMenuToggleRow(
                    title: row.title,
                    note: row.note,
                    isOn: Binding(
                        get: { settings[keyPath: row.value] },
                        set: { settings[keyPath: row.value] = $0 }
                    )
                )
            }
            if let files {
                WordMenuGroupLabel(title: Self.filesGroupTitle)
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
            WordMenuRow(
                title: Self.clearHistoryTitle,
                note: Self.clearHistoryNote,
                accessory: .text(Self.clearHistoryButtonTitle),
                isDestructive: true
            ) {
                isConfirmingClearHistory = true
            }
            .accessibilityHint(Text(Self.clearHistoryNote))
            .accessibilityIdentifier("settings.clearHistory")
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
                systemImage: "arrow.up.arrow.down",
                accessory: .text(files.sortOrder.title)
            )
        }
        .buttonStyle(WordMenuPressStyle())
        .accessibilityLabel(FilesSection.sortMenuTitle)
        .accessibilityValue(files.sortOrder.title)
    }
}
