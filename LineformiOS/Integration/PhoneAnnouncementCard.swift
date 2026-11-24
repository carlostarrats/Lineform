import LineformCore
import SwiftUI

/// An announcement on iPhone: a small one-time sheet, as tall as its content, on the word menu's
/// wash. The title, the body, the action as the full-width blue pill, and a quiet "Not now" under
/// it. When the action is the Lineform Guide, a footnote says where the guide lives (About
/// Lineform). Not now, a swipe down and the action all dismiss the announcement for good
/// (`PhoneAnnouncementStore`'s rules: dismissed ids are never pruned).
///
/// Title and body are remote input and render as plain `Text` (verbatim), never Markdown; the
/// store only lets an https link through. The screen presents it only when nothing else holds the
/// page (`DocumentScreen.canPresentAnnouncement`).
struct PhoneAnnouncementSheet: View {
    let announcement: Announcement
    let profile: ReadingProfile
    var onAction: () -> Void
    var onDismiss: () -> Void
    /// The content's height, for the sheet's one detent.
    @Binding var contentHeight: CGFloat

    static var notNowTitle: String { String(localized: "Not now") }
    static var guideFootnote: String { String(localized: "You can find the guide anytime in About Lineform.") }
    static func accessibilityTitle(_ announcement: Announcement) -> String {
        String(localized: "Announcement: \(announcement.title)")
    }

    /// Whether the action opens the Lineform Guide (the footnote's case).
    static func isGuideAction(_ announcement: Announcement) -> Bool {
        guard let url = announcement.actionURL, let guide = URL(string: LineformLinks.guideURL) else { return false }
        return url.host() == guide.host() && url.path().trimmingCharacters(in: ["/"]) == guide.path().trimmingCharacters(in: ["/"])
    }

    /// The sheet's height for content `height` tall: never under a small floor.
    static func detentHeight(for height: CGFloat) -> CGFloat { max(height, 180) }

    var body: some View {
        let palette = WordMenuPalette.forTheme(Theme.theme(for: profile))
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(palette.color(palette.blueMark))
                    .accessibilityHidden(true)
                Text(verbatim: announcement.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(palette.color(palette.ink))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: announcement.body)
                    .font(.body)
                    .foregroundStyle(palette.color(palette.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 2) {
                    if let label = announcement.actionLabel {
                        WordMenuPrimaryButton(title: label, action: onAction)
                            .accessibilityAddTraits(.isLink)
                            .accessibilityIdentifier("announcement.action")
                    }
                    Button(action: onDismiss) {
                        Text(Self.notNowTitle)
                            .font(.body)
                            .foregroundStyle(palette.color(palette.secondary))
                            .frame(maxWidth: .infinity, minHeight: WordMenuMetrics.minimumTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("announcement.notNow")
                }
                .padding(.top, 6)
                if Self.isGuideAction(announcement) {
                    Text(Self.guideFootnote)
                        .font(.footnote)
                        .foregroundStyle(palette.color(palette.tertiary))
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 12)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Self.accessibilityTitle(announcement))
        }
        .scrollBounceBehavior(.basedOnSize)
        .environment(\.wordMenuPalette, palette)
        .environment(\.colorScheme, palette.colorScheme)
        .presentationBackground { palette.wash }
        .presentationDetents([.height(Self.detentHeight(for: contentHeight))])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(palette.colorScheme)
    }
}
