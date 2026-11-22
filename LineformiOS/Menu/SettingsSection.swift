import LineformCore
import SwiftUI

/// The Menu sheet's Settings: four switches, each with a short note, worded for iPhone (the
/// Mac's notes name a Mac and a sidebar). The values are `AppSettings`, per device, under the
/// Mac's keys.
///
/// Connect Your AI, Clear History and Check for Updates arrive with roadmap steps 8, 9 and 12.
struct SettingsSection: View {
    @ObservedObject var settings: AppSettings

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
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}
