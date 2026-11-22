import LineformCore
import SwiftUI

/// The "Aa" button beside the Menu button: opens the Styling sheet (`StylingSheet`). It wears the
/// Menu button's floating-card chrome exactly — the theme's page fill and ink, the hairline and
/// the shadow from `LineformDesign.FloatingCard` — so the bottom-trailing buttons read as one row.
struct StylingButton: View {
    var profile: ReadingProfile
    var action: () -> Void

    /// The Menu button's diameter, so the row stays even.
    static let diameter: CGFloat = 44
    static let symbolName = "textformat.size"
    /// The Mac's name for the same panel.
    static var accessibilityLabel: String { String(localized: "Reading Experience") }

    var body: some View {
        let theme = Theme.theme(for: profile)
        let isDark = theme.usesDarkChrome
        Button(action: action) {
            Image(systemName: Self.symbolName)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color(uiColor: theme.textColor))
                .frame(width: Self.diameter, height: Self.diameter)
                .background(Circle().fill(Color(uiColor: theme.backgroundColor)))
                .overlay(
                    Circle().strokeBorder(
                        isDark
                            ? Color.white.opacity(LineformDesign.FloatingCard.hairlineOpacityDark)
                            : Color.black.opacity(LineformDesign.FloatingCard.hairlineOpacityLight),
                        lineWidth: LineformDesign.FloatingCard.hairlineWidth
                    )
                )
                .shadow(
                    color: .black.opacity(
                        isDark ? LineformDesign.FloatingCard.shadowOpacityDark
                            : LineformDesign.FloatingCard.shadowOpacityLight
                    ),
                    radius: LineformDesign.FloatingCard.shadowRadius,
                    x: LineformDesign.FloatingCard.shadowOffset.width,
                    y: LineformDesign.FloatingCard.shadowOffset.height
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.accessibilityLabel)
    }
}
