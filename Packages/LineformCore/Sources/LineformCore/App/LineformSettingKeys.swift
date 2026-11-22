import Foundation

/// The persisted `UserDefaults` identity both apps share: key names and the value each setting
/// has when its key is absent. Each device keeps its own values; the names are the Mac's, kept
/// byte for byte, because changing one silently resets every user's choice.
///
/// The Mac's `LineformSettingsStore` and `OutlineFileBrowserStore` keep their old key constants
/// as forwarders to these.
public enum LineformSettingKeys {
    // MARK: Settings (`Lineform.settings.*`)

    public static let showSidebarOnLaunch = "Lineform.settings.showSidebarOnLaunch"
    public static let allowRootFolderCollapse = "Lineform.settings.allowRootFolderCollapse"
    public static let showICloudInSidebar = "Lineform.settings.showICloudInSidebar"
    public static let checksSpellingWhileTyping = "Lineform.settings.checksSpellingWhileTyping"
    public static let checksForAnnouncements = "Lineform.settings.checksForAnnouncements"
    public static let automaticDarkMode = "Lineform.settings.automaticDarkMode"

    /// The value of each Boolean setting when its key is absent. `allowRootFolderCollapse` has no
    /// entry: absent means "the user never chose", which the Mac reads as nil.
    public enum Defaults {
        public static let showSidebarOnLaunch = true
        public static let showICloudInSidebar = true
        public static let checksSpellingWhileTyping = true
        public static let checksForAnnouncements = true
        public static let automaticDarkMode = true
    }

    // MARK: Files tree (`Lineform.outline.*`)

    public static let iCloudSnapshot = "Lineform.outline.iCloudSnapshot"
    public static let workspaceBookmark = "Lineform.outline.workspaceBookmark"
    public static let workspaceSnapshot = "Lineform.outline.workspaceSnapshot"
    public static let showsHiddenFolders = "Lineform.outline.showsHiddenFolders"
    public static let iCloudSortOrder = "Lineform.outline.sortOrder.icloud"
    public static let workspaceSortOrder = "Lineform.outline.sortOrder.workspace"
    public static let lastKnownICloudAvailable = "Lineform.outline.lastKnownICloudAvailable"

    /// A Boolean that defaults to `fallback` when its key is absent. `bool(forKey:)` cannot be
    /// used for a setting that is on by default: it reads an absent key as false.
    public static func bool(_ key: String, default fallback: Bool, in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) as? Bool ?? fallback
    }
}
