import LineformCore
import SwiftUI

/// The announcement card on iPhone: the Mac's `AnnouncementCard` (sparkle glyph, title, body, an
/// optional link, a ✕) in the iPhone's floating-card chrome (`floatingCardChrome`, LineformDesign's
/// radius, hairline and shadow on the page colour). It floats above the Menu and Aa buttons at the
/// bottom right, never as a full-width bar.
///
/// Title and body are remote input and render as plain `Text` (verbatim), never Markdown. The
/// colours come from the page's theme (`Theme.usesDarkChrome`), never the system appearance.
struct PhoneAnnouncementCard: View {
    let announcement: Announcement
    let profile: ReadingProfile
    var onAction: () -> Void
    var onDismiss: () -> Void

    /// A cap, not a fixed width: on a narrow phone the card takes the width it is offered.
    static let maximumWidth: CGFloat = 360

    static var dismissTitle: String { String(localized: "Dismiss announcement") }
    static func accessibilityTitle(_ announcement: Announcement) -> String {
        String(localized: "Announcement: \(announcement.title)")
    }

    var body: some View {
        let theme = Theme.theme(for: profile)
        let ink = Color(uiColor: theme.textColor)
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkles")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.accentColor.opacity(theme.usesDarkChrome ? 0.16 : 0.10)))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: announcement.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: announcement.body)
                    .font(.footnote)
                    .foregroundStyle(ink.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
                if let label = announcement.actionLabel {
                    Button(action: onAction) {
                        HStack(spacing: 3) {
                            Text(verbatim: label)
                            Image(systemName: "arrow.up.right")
                                .font(.caption2.weight(.semibold))
                                .accessibilityHidden(true)
                        }
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                        .frame(minHeight: 32, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer(minLength: 0)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(ink.opacity(0.6))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Self.dismissTitle)
            // A 44 pt target without widening the card.
            .padding(.top, -10)
            .padding(.trailing, -10)
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.vertical, 13)
        .frame(maxWidth: Self.maximumWidth, alignment: .leading)
        .environment(\.colorScheme, theme.usesDarkChrome ? .dark : .light)
        .floatingCardChrome(theme: theme, cornerRadius: LineformDesign.FloatingCard.radius)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.accessibilityTitle(announcement))
        // Escape (VoiceOver's two-finger scrub, or Esc on a keyboard) closes it, as Esc does on the Mac.
        .accessibilityAction(.escape, onDismiss)
    }
}
