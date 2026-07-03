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
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(Self.showICloudTitle, isOn: $settings.showICloudInSidebar)
                        .disabled(!iCloud.isToggleEnabled)
                    if iCloud.isChecking {
                        Text(Self.iCloudCheckingNote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if !iCloud.isToggleEnabled {
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
