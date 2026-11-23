import Combine
import LineformCore
import SwiftUI
import UIKit

/// The iPhone's settings, per device, under the Mac's `Lineform.settings.*` key names
/// (`LineformSettingKeys`). Every one is on until the writer turns it off. Initial values load
/// through `Published(initialValue:)`, so reading a default writes nothing; each change is
/// written at once.
///
/// - `automaticDarkMode`: while the iPhone is in Dark appearance, a light theme draws as Quiet
///   (`displayProfile`), the Mac's mapping. The stored profile keeps the writer's theme.
/// - `showICloudInFiles` (the Mac's `showICloudInSidebar`): the Files section shows Lineform's
///   iCloud folder. New documents still save there.
/// - `checksSpellingWhileTyping`: the editor's `SpellCheckPass` runs as the writer types.
/// - `checksForAnnouncements`: gates the announcement request itself (`PhoneAnnouncementStore`),
///   and off takes a card on screen away.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings(defaults: .standard)

    @Published var automaticDarkMode: Bool {
        didSet { defaults.set(automaticDarkMode, forKey: LineformSettingKeys.automaticDarkMode) }
    }
    @Published var showICloudInFiles: Bool {
        didSet { defaults.set(showICloudInFiles, forKey: LineformSettingKeys.showICloudInSidebar) }
    }
    @Published var checksSpellingWhileTyping: Bool {
        didSet { defaults.set(checksSpellingWhileTyping, forKey: LineformSettingKeys.checksSpellingWhileTyping) }
    }
    @Published var checksForAnnouncements: Bool {
        didSet { defaults.set(checksForAnnouncements, forKey: LineformSettingKeys.checksForAnnouncements) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        _automaticDarkMode = Published(initialValue: LineformSettingKeys.bool(
            LineformSettingKeys.automaticDarkMode, default: LineformSettingKeys.Defaults.automaticDarkMode, in: defaults
        ))
        _showICloudInFiles = Published(initialValue: LineformSettingKeys.bool(
            LineformSettingKeys.showICloudInSidebar, default: LineformSettingKeys.Defaults.showICloudInSidebar, in: defaults
        ))
        _checksSpellingWhileTyping = Published(initialValue: LineformSettingKeys.bool(
            LineformSettingKeys.checksSpellingWhileTyping, default: LineformSettingKeys.Defaults.checksSpellingWhileTyping, in: defaults
        ))
        _checksForAnnouncements = Published(initialValue: LineformSettingKeys.bool(
            LineformSettingKeys.checksForAnnouncements, default: LineformSettingKeys.Defaults.checksForAnnouncements, in: defaults
        ))
    }

    /// The profile the editor and Read draw with: `profile` with Automatic Dark Mode applied for
    /// the iPhone's appearance, by the Mac's rule (`ReadingProfile.displayProfile`).
    static func displayProfile(
        _ profile: ReadingProfile, automaticDarkMode: Bool, userInterfaceStyle: UIUserInterfaceStyle
    ) -> ReadingProfile {
        profile.displayProfile(automaticDarkMode: automaticDarkMode, systemIsDark: userInterfaceStyle == .dark)
    }

    func displayProfile(_ profile: ReadingProfile, userInterfaceStyle: UIUserInterfaceStyle) -> ReadingProfile {
        Self.displayProfile(profile, automaticDarkMode: automaticDarkMode, userInterfaceStyle: userInterfaceStyle)
    }
}

extension UIUserInterfaceStyle {
    /// The trait-collection style for SwiftUI's colour scheme.
    init(_ colorScheme: ColorScheme) {
        self = colorScheme == .dark ? .dark : .light
    }
}
