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


/// The phone's own Light/Dark setting, and the screen's own colour scheme.
///
/// The document screen draws in its display theme's own light or dark
/// (`DocumentScreen.chromeColorScheme`), so the status bar's text is dark on a light page and
/// light on a dark one whatever the phone is set to. The scheme is set as the ROOT view
/// controller's `overrideUserInterfaceStyle` (`SystemAppearanceReader`), never with SwiftUI's
/// `.preferredColorScheme` at the root: in the app, that one lands on the window SCENE's trait
/// overrides, so the scene, the window and every view then report the theme's darkness, and
/// Automatic Dark Mode could never see the phone switch again (measured on iOS 26). With the
/// override on the root view controller only, the window above it keeps the system's style and
/// its trait changes say when the phone switches; the style itself is read from the screen, which
/// no override reaches (a sheet that forces its own scheme can still override the window while it
/// is up; its leaving is a window trait change, read again then).
///
/// `followsWindow` false (tests): nothing reads the window, and `style` is set by hand, standing in
/// for the phone's setting.
@MainActor
final class SystemAppearance: ObservableObject {
    @Published var style: UIUserInterfaceStyle?
    let followsWindow: Bool

    init(style: UIUserInterfaceStyle? = nil, followsWindow: Bool = true) {
        _style = Published(initialValue: style)
        self.followsWindow = followsWindow
    }
}

/// Applies the screen's colour scheme to the root view controller and feeds `SystemAppearance`
/// from the window and screen (`SystemAppearance` explains why).
struct SystemAppearanceReader: UIViewRepresentable {
    let appearance: SystemAppearance
    let scheme: ColorScheme

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.style = scheme == .dark ? .dark : .light
        guard appearance.followsWindow else { return view }
        view.onChange = { [weak appearance] style in
            // Never during SwiftUI's update: the next turn.
            Task { @MainActor in if appearance?.style != style { appearance?.style = style } }
        }
        return view
    }

    func updateUIView(_ view: ReaderView, context: Context) {
        view.style = scheme == .dark ? .dark : .light
    }

    final class ReaderView: UIView {
        var onChange: ((UIUserInterfaceStyle) -> Void)?
        /// The screen's colour scheme, set on the root view controller while in a window.
        var style: UIUserInterfaceStyle = .unspecified {
            didSet { if style != oldValue { applyStyle() } }
        }
        private var registration: (any UITraitChangeRegistration)?
        private weak var observedWindow: UIWindow?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
            isHidden = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        private func applyStyle() {
            guard let root = window?.rootViewController, root.overrideUserInterfaceStyle != style else { return }
            root.overrideUserInterfaceStyle = style
            root.setNeedsStatusBarAppearanceUpdate()
        }

        /// The phone's style: the screen's, which no override reaches.
        private func report() {
            guard let window else { return }
            let style = window.screen.traitCollection.userInterfaceStyle
            onChange?(style == .unspecified ? window.traitCollection.userInterfaceStyle : style)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            applyStyle()
            guard onChange != nil, let window else { return }
            if window !== observedWindow {
                if let registration, let observedWindow { observedWindow.unregisterForTraitChanges(registration) }
                observedWindow = window
                registration = window.registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
                    [weak self] (_: UIWindow, _: UITraitCollection) in
                    self?.report()
                }
            }
            report()
        }
    }
}

extension DocumentScreen {
    /// The colour scheme the document screen (and so the status bar, the word menu over it and the
    /// keyboard's default look) runs in: the display theme's own darkness. A theme whose colours
    /// follow the appearance (high contrast) is resolved for the phone's real style first, so it
    /// keeps following the phone.
    static func chromeColorScheme(for profile: ReadingProfile, systemStyle: UIUserInterfaceStyle) -> ColorScheme {
        var isDark = false
        UITraitCollection(userInterfaceStyle: systemStyle).performAsCurrent {
            isDark = Theme.theme(for: profile).usesDarkChrome
        }
        return isDark ? .dark : .light
    }
}
