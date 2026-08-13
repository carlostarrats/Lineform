import SwiftUI

/// The app's Settings surface (⌘, / Lineform › Settings…), presented as a
/// Muse-style in-window modal (`MuseModalChrome` card over a `MuseModalScrim`):
/// light card, scrim, close button, Esc dismissal — deliberately NOT the native
/// macOS settings window, so every modal in the app looks and behaves the same.
struct SettingsModal: View {
    @ObservedObject var settings: LineformSettingsStore
    @StateObject private var iCloud: ICloudSettingViewModel
    /// THREADED from the theme, never read from `@Environment(\.colorScheme)` — see
    /// `MuseModalChrome.primaryTextColor(usesDarkChrome:)`.
    var usesDarkChrome: Bool
    var dismiss: () -> Void

    static let title = String(localized: "Settings")
    static let contentWidth: CGFloat = 460
    /// The card fits inside narrow windows (minimum editor width is ~300pt): it
    /// takes its ideal width when the window allows, else shrinks with margins.
    static func cardWidth(availableWidth: CGFloat) -> CGFloat {
        min(contentWidth, max(280, availableWidth - 24))
    }
    static let animationDuration = MuseModalChrome.animationDuration
    static let entranceYOffset = MuseModalChrome.entranceYOffset

    static let showSidebarOnLaunchTitle = String(localized: "Show sidebar on launch")
    static let showSidebarOnLaunchNote = String(localized: "New windows open with the sidebar visible.")
    static let allowCollapseTitle = String(localized: "Allow root folders to expand and collapse")
    static let allowCollapseNote = String(localized: "When off, the iCloud and Workspace sections in the Files sidebar always stay expanded.")
    static let showICloudTitle = String(localized: "Show iCloud in sidebar")
    static let iCloudCheckingNote = String(localized: "Checking…")
    static let iCloudUnavailableNote = String(localized: "iCloud is not available on this Mac.")
    static let iCloudEnabledNote = String(localized: "Hides iCloud in Lineform's sidebar. Saving a new document starts outside Lineform iCloud; you can still choose iCloud.")
    static let announcementsTitle = String(localized: "In-app notifications")
    static let announcementsNote = String(localized: "Occasional news about new versions, checked once a day. No personal data is sent or collected. When off, Lineform makes no network request.")

    /// Window width the presenting container offers (via GeometryReader).
    var availableWidth: CGFloat

    init(
        settings: LineformSettingsStore,
        usesDarkChrome: Bool = false,
        availableWidth: CGFloat = SettingsModal.contentWidth + 24,
        // Autoclosure so the default view-model is built at most once, inside
        // StateObject's own lazy storage — not on every SettingsModal init.
        iCloudViewModel: @autoclosure @escaping () -> ICloudSettingViewModel = ICloudSettingViewModel(),
        dismiss: @escaping () -> Void = {}
    ) {
        self.settings = settings
        self.usesDarkChrome = usesDarkChrome
        self.availableWidth = availableWidth
        _iCloud = StateObject(wrappedValue: iCloudViewModel())
        self.dismiss = dismiss
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            MuseModalHeader(title: Self.title, usesDarkChrome: usesDarkChrome, dismiss: dismiss)

            VStack(alignment: .leading, spacing: 0) {
                settingRow(
                    title: Self.showSidebarOnLaunchTitle,
                    note: Self.showSidebarOnLaunchNote,
                    isOn: $settings.showSidebarOnLaunch
                )

                Divider()
                    .padding(.vertical, 12)

                settingRow(
                    title: Self.allowCollapseTitle,
                    note: Self.allowCollapseNote,
                    isOn: allowCollapseBinding
                )

                Divider()
                    .padding(.vertical, 12)

                settingRow(
                    title: Self.showICloudTitle,
                    note: iCloudNote,
                    isOn: $settings.showICloudInSidebar,
                    disabled: iCloudToggleDisabled
                )

                Divider()
                    .padding(.vertical, 12)

                settingRow(
                    title: Self.announcementsTitle,
                    note: Self.announcementsNote,
                    isOn: $settings.checksForAnnouncements
                )
                .onChange(of: settings.checksForAnnouncements) { _, isEnabled in
                    // Turning the feature OFF retracts any card already on screen (the
                    // request gate lives in the store; this is the display side). Turning
                    // it back on defers to the normal launch check / cache restore.
                    if !isEnabled { AnnouncementStore.shared.retractForDisabledSetting() }
                }
            }
        }
        .museModalCard(
            width: Self.cardWidth(availableWidth: availableWidth),
            accessibilityLabel: Self.title,
            usesDarkChrome: usesDarkChrome
        )
        .task { await iCloud.refresh() }
    }

    /// Reads the EFFECTIVE collapse behavior (the user's saved choice, or the
    /// adaptive default: collapsible only while the iCloud root is visible) and
    /// writes an explicit, persisted choice on toggle — so a lone Workspace root
    /// auto-locks open until the user says otherwise, and their say sticks.
    private var allowCollapseBinding: Binding<Bool> {
        Binding(
            get: {
                LineformSettingsStore.effectiveAllowRootFolderCollapse(
                    choice: settings.allowRootFolderCollapseChoice,
                    iCloudRootVisible: !iCloud.isUnavailable && settings.showICloudInSidebar
                )
            },
            set: { settings.setAllowRootFolderCollapse($0) }
        )
    }

    /// Single derivation shared by the row's disabled state AND its caption, so the
    /// two can never disagree.
    private var iCloudToggleDisabled: Bool {
        iCloud.isToggleDisabled(currentlyShown: settings.showICloudInSidebar)
    }

    /// The iCloud row's explanatory line tracks the probe state: checking →
    /// unavailable → the plain description.
    private var iCloudNote: String {
        if iCloud.isChecking {
            return Self.iCloudCheckingNote
        }
        if iCloud.isUnavailable {
            return Self.iCloudUnavailableNote
        }
        return Self.iCloudEnabledNote
    }

    private func settingRow(title: String, note: String, isOn: Binding<Bool>, disabled: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(MuseModalChrome.primaryTextColor(usesDarkChrome: usesDarkChrome))
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(MuseModalChrome.secondaryTextColor(usesDarkChrome: usesDarkChrome))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(disabled)
        }
        .opacity(disabled ? 0.55 : 1)
        // The switch swallows the mouse-moved stream the card's `modalArrowCursor` rides on,
        // so without this the editor's I-beam is what you see over every toggle. See
        // `CursorRectView` — it tracks geometrically and keeps winning over the control.
        .background(CursorRectView(cursor: .arrow))
        .accessibilityElement(children: .combine)
    }
}
