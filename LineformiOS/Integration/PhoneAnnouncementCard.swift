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
    /// The content's own height, so the scroll view is no taller than what it holds.
    @State private var contentHeight: CGFloat?

    /// A cap, not a fixed width: on a narrow phone the card takes the width it is offered.
    static let maximumWidth: CGFloat = 360

    static var dismissTitle: String { String(localized: "Dismiss announcement") }
    static func accessibilityTitle(_ announcement: Announcement) -> String {
        String(localized: "Announcement: \(announcement.title)")
    }

    var body: some View {
        let theme = Theme.theme(for: profile)
        let ink = Color(uiColor: theme.textColor)
        // The link is text: systemBlue is under 4.5:1 on the light pages, so it takes PhoneInk's
        // readable accent for the page's own scheme.
        let inks = PhoneInk(theme: theme, colorScheme: theme.usesDarkChrome ? .dark : .light)
        // At the accessibility text sizes the card can be taller than the room left between the
        // mode switch and the bottom buttons: it then scrolls rather than covering the switch.
        // One scroll view at every size (never a swapped-in second copy of the text), capped at
        // the content's height so a short card stays short.
        ScrollView {
            content(ink: ink, inks: inks)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                // The card's element is its content, inside the scroll view: on the scroll view
                // itself SwiftUI reports the container with an empty frame.
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Self.accessibilityTitle(announcement))
                // Escape (VoiceOver's two-finger scrub, or Esc on a keyboard) closes it, as Esc
                // does on the Mac.
                .accessibilityAction(.escape, onDismiss)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: contentHeight)
        .frame(maxWidth: Self.maximumWidth, alignment: .leading)
        .environment(\.colorScheme, theme.usesDarkChrome ? .dark : .light)
        .floatingCardChrome(theme: theme, cornerRadius: LineformDesign.FloatingCard.radius)
    }

    private func content(ink: Color, inks: PhoneInk) -> some View {
        let theme = Theme.theme(for: profile)
        return HStack(alignment: .top, spacing: 12) {
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
                            // Wraps at the accessibility sizes, never truncates.
                            Text(verbatim: label)
                                .fixedSize(horizontal: false, vertical: true)
                            Image(systemName: "arrow.up.right")
                                .font(.caption2.weight(.semibold))
                                .accessibilityHidden(true)
                        }
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(inks.accent)
                        .frame(minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // A 44 pt target laid out in the 32 pt the link always took.
                    .padding(.vertical, -6)
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
    }
}
