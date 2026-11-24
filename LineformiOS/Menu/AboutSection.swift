import LineformCore
import SwiftUI

/// The word menu's About Lineform: Check for Updates… (`PhoneUpdateCommand`: one App Store lookup
/// when the writer taps it, then one alert that can open the App Store page), the Lineform Guide,
/// the Privacy Policy and the Terms of Use (Safari, at the package's `LineformLinks`), and the
/// version centred below them. No repeated "Lineform" heading: the page's title says it.
struct AboutSection: View {
    @ObservedObject var updateCommand: PhoneUpdateCommand
    @Environment(\.openURL) private var openURL
    @Environment(\.wordMenuPalette) private var palette

    // MARK: - Copy (the Mac's strings where the English matches)

    static var checkForUpdatesTitle: String { String(localized: "Check for Updates…") }
    static var checkForUpdatesNote: String {
        String(localized: "Asks the App Store whether a newer version of Lineform is out. Nothing about you or your documents is sent.")
    }
    static var guideTitle: String { String(localized: "Lineform Guide") }
    static var privacyPolicyTitle: String { String(localized: "Privacy Policy") }
    static var termsOfUseTitle: String { String(localized: "Terms of Use") }

    static let guideURL = URL(string: LineformLinks.guideURL)!
    static let privacyPolicyURL = URL(string: LineformLinks.privacyPolicyURL)!
    static let termsOfUseURL = URL(string: LineformLinks.termsOfUseURL)!

    /// "Version 1.9.0" from the bundle's short version.
    static func versionText(bundle: Bundle = .main) -> String {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        return String(localized: "Version \(version)")
    }

    /// Every row's title, in order.
    static var rowTitles: [String] { [checkForUpdatesTitle, guideTitle, privacyPolicyTitle, termsOfUseTitle] }

    var body: some View {
        WordMenuPageScaffold(title: WordMenuItem.about.title) {
            WordMenuRow(
                title: Self.checkForUpdatesTitle,
                accessory: updateCommand.isChecking ? .progress : .chevron
            ) {
                Task { await updateCommand.run() }
            }
            .disabled(updateCommand.isChecking)
            .accessibilityHint(Text(Self.checkForUpdatesNote))
            .accessibilityIdentifier("about.checkForUpdates")
            WordMenuRow(title: Self.guideTitle, accessory: .external) { openURL(Self.guideURL) }
            Color.clear.frame(height: 10)
            WordMenuRow(title: Self.privacyPolicyTitle, accessory: .external) { openURL(Self.privacyPolicyURL) }
            WordMenuRow(title: Self.termsOfUseTitle, accessory: .external) { openURL(Self.termsOfUseURL) }
            Text(Self.versionText())
                .font(.footnote)
                .foregroundStyle(palette.color(palette.tertiary))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 40)
        }
    }
}
