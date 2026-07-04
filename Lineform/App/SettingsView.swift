import SwiftUI

/// The app's Settings surface (⌘, / Lineform › Settings…), presented as a
/// Muse-style in-window modal — the same chrome language as the Info modal
/// (`MarkdownBasicsModal`): light card, scrim, close button, Esc dismissal —
/// deliberately NOT the native macOS settings window, so every modal in the
/// app looks and behaves the same.
struct SettingsModal: View {
    @ObservedObject var settings: LineformSettingsStore
    @StateObject private var iCloud: ICloudSettingViewModel
    var dismiss: () -> Void

    static let title = "Settings"
    static let contentWidth: CGFloat = 460
    static let animationDuration = MarkdownBasicsModal.animationDuration
    static let entranceYOffset = MarkdownBasicsModal.entranceYOffset

    static let showSidebarOnLaunchTitle = "Show sidebar on launch"
    static let showSidebarOnLaunchNote = "New windows open with the sidebar visible."
    static let allowCollapseTitle = "Allow root folders to expand and collapse"
    static let allowCollapseNote = "When off, the iCloud and Workspace sections in the Files sidebar always stay expanded."
    static let showICloudTitle = "Show iCloud in sidebar"
    static let iCloudCheckingNote = "Checking…"
    static let iCloudUnavailableNote = "iCloud is not available on this Mac."
    static let iCloudDisabledNote = "Only available when your Lineform iCloud folder is empty. This hides iCloud in Lineform's sidebar; it does not delete anything from iCloud Drive."
    static let iCloudEnabledNote = "Hides iCloud in Lineform's sidebar; nothing in iCloud Drive is changed."

    @State private var isCloseHovered = false

    init(
        settings: LineformSettingsStore,
        // Autoclosure so the default view-model is built at most once, inside
        // StateObject's own lazy storage — not on every SettingsModal init.
        iCloudViewModel: @autoclosure @escaping () -> ICloudSettingViewModel = ICloudSettingViewModel(),
        dismiss: @escaping () -> Void = {}
    ) {
        self.settings = settings
        _iCloud = StateObject(wrappedValue: iCloudViewModel())
        self.dismiss = dismiss
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text(Self.title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Self.primaryTextColor)

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Self.secondaryTextColor)
                        .frame(width: 28, height: 28)
                        .background(
                            Circle()
                                .fill(Self.primaryTextColor.opacity(isCloseHovered ? MarkdownBasicsModal.closeHoverFillOpacity : MarkdownBasicsModal.closeRestingFillOpacity))
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .contentShape(Circle())
                .help("Close")
                .onHover { hovering in
                    isCloseHovered = hovering
                }
                .animation(.easeOut(duration: 0.12), value: isCloseHovered)
            }

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
                    isOn: $settings.allowRootFolderCollapse
                )

                Divider()
                    .padding(.vertical, 12)

                settingRow(
                    title: Self.showICloudTitle,
                    note: iCloudNote,
                    isOn: $settings.showICloudInSidebar,
                    disabled: iCloud.isToggleDisabled(currentlyShown: settings.showICloudInSidebar)
                )
            }
        }
        .padding(24)
        .frame(width: Self.contentWidth, alignment: .leading)
        .background(Self.backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.16), radius: 28, x: 0, y: 14)
        .environment(\.colorScheme, .light)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings")
        .task { await iCloud.refresh() }
    }

    /// The iCloud row's explanatory line tracks the probe state: checking →
    /// unavailable → blocked-because-not-empty → the plain description.
    private var iCloudNote: String {
        if iCloud.isChecking {
            return Self.iCloudCheckingNote
        }
        if iCloud.isUnavailable {
            return Self.iCloudUnavailableNote
        }
        if iCloud.isToggleDisabled(currentlyShown: settings.showICloudInSidebar) {
            return Self.iCloudDisabledNote
        }
        return Self.iCloudEnabledNote
    }

    private func settingRow(title: String, note: String, isOn: Binding<Bool>, disabled: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Self.primaryTextColor)
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(Self.secondaryTextColor)
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
        .accessibilityElement(children: .combine)
    }

    private static var backgroundColor: Color {
        Color(nsColor: NSColor(calibratedWhite: MarkdownBasicsModal.backgroundWhiteComponent, alpha: 1))
    }

    private static var primaryTextColor: Color {
        Color(nsColor: NSColor(
            calibratedRed: MarkdownBasicsModal.textRedComponent,
            green: MarkdownBasicsModal.textRedComponent,
            blue: MarkdownBasicsModal.textRedComponent,
            alpha: 1
        ))
    }

    private static var secondaryTextColor: Color {
        primaryTextColor.opacity(MarkdownBasicsModal.secondaryTextOpacity)
    }
}
