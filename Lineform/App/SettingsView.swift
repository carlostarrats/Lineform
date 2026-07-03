import SwiftUI

/// The app's Settings window (⌘,). A single restrained "General" pane with the
/// three preferences. Native `Form`; no custom chrome.
struct SettingsView: View {
    @ObservedObject var settings: LineformSettingsStore
    @StateObject private var iCloud: ICloudSettingViewModel

    static let showSidebarOnLaunchTitle = "Show sidebar on launch"
    static let keepRootsExpandedTitle = "Keep root folders expanded"
    static let keepRootsExpandedNote = "Root sections stay open and can't be collapsed."
    static let showICloudTitle = "Show iCloud in sidebar"
    static let iCloudCheckingNote = "Checking…"
    static let iCloudDisabledNote = "Only available when your Lineform iCloud folder is empty. This hides iCloud in Lineform's sidebar; it does not delete anything from iCloud Drive."

    /// The emptiness guard only blocks turning iCloud OFF. Re-showing a hidden root is
    /// always safe, so when the setting is already off the toggle stays operable even
    /// if the folder has since become non-empty (otherwise the user could get stuck
    /// unable to bring iCloud back).
    static func iCloudToggleDisabled(currentlyShown: Bool, canToggleOff: Bool) -> Bool {
        currentlyShown && !canToggleOff
    }

    init(
        settings: LineformSettingsStore,
        iCloudViewModel: ICloudSettingViewModel = ICloudSettingViewModel()
    ) {
        self.settings = settings
        _iCloud = StateObject(wrappedValue: iCloudViewModel)
    }

    var body: some View {
        Form {
            Toggle(Self.showSidebarOnLaunchTitle, isOn: $settings.showSidebarOnLaunch)

            VStack(alignment: .leading, spacing: 2) {
                Toggle(Self.keepRootsExpandedTitle, isOn: $settings.keepRootFoldersExpanded)
                Text(Self.keepRootsExpandedNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if iCloud.isControlVisible {
                let toggleDisabled = Self.iCloudToggleDisabled(
                    currentlyShown: settings.showICloudInSidebar,
                    canToggleOff: iCloud.isToggleEnabled
                )
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(Self.showICloudTitle, isOn: $settings.showICloudInSidebar)
                        .disabled(toggleDisabled)
                    if iCloud.isChecking {
                        Text(Self.iCloudCheckingNote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if toggleDisabled {
                        Text(Self.iCloudDisabledNote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .task { await iCloud.refresh() }
    }
}
