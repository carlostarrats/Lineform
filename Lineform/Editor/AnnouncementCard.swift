import SwiftUI
import LineformCore

/// The announcement card: a small floating card at the bottom-trailing corner of the
/// EDITOR CONTENT (not the shell — hanging it off the content is what keeps it from
/// overlapping the status bar beneath).
///
/// It is an overlay rather than a laid-out row for the same reason Find & Replace is:
/// the top edge of the shell is what the translucent toolbar samples, so nothing may be
/// added there. Top-trailing is already Find & Replace's corner, so this takes the
/// opposite end.
///
/// `usesDarkChrome` is THREADED from the theme, never read from
/// `@Environment(\.colorScheme)` — a nested control that reads the environment renders
/// invisible text after a tab or inspector transition.
struct AnnouncementCard: View {
    let announcement: Announcement
    let usesDarkChrome: Bool
    var onAction: () -> Void
    var onDismiss: () -> Void

    @State private var isHoveringClose = false
    @State private var isHoveringAction = false

    static let cornerRadius: CGFloat = LineformDesign.FloatingCard.radius
    /// Ideal width. A CAP, not a fixed size — see the `.frame` comment below.
    static let maximumWidth: CGFloat = 326
    /// Inset from the content area's bottom-trailing corner.
    static let edgeInset: CGFloat = 16

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon

            VStack(alignment: .leading, spacing: 5) {
                Text(announcement.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(primaryInk)
                    .fixedSize(horizontal: false, vertical: true)

                Text(announcement.body)
                    .font(.system(size: 11.5))
                    .lineSpacing(2)
                    .foregroundStyle(secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)

                if let label = announcement.actionLabel {
                    Button(action: onAction) {
                        HStack(spacing: 3) {
                            Text(label)
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .font(.system(size: 11.5, weight: .medium))
                        // The tint is drawn as a background on a padded label rather than
                        // by growing the button: the negative outer padding puts the text
                        // back on the same baseline and left edge it sits at unhovered, so
                        // hovering tints the row without nudging the card's layout.
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(accentInk.opacity(actionTintOpacity))
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .padding(.horizontal, -6)
                        .padding(.vertical, -3)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(accentInk)
                    .onHover { isHoveringAction = $0 }
                    .padding(.top, 3)
                }
            }

            Spacer(minLength: 0)

            closeButton
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.vertical, 13)
        // maxWidth, never a fixed width: the editor's minimum content width is 220pt
        // (`EditorLayout.minimumContentWidth`), so a fixed 326 plus insets overflows a
        // narrow window and clips off-screen. The inner `Spacer(minLength: 0)` makes the
        // row take the offered width up to this cap, so the card is its ideal size when
        // there is room and compresses when there isn't — the same concession
        // `findReplaceBar` makes.
        .frame(maxWidth: Self.maximumWidth, alignment: .leading)
        .modifier(FloatingCardChrome(usesDarkChrome: usesDarkChrome))
        .onExitCommand(perform: onDismiss)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Announcement: \(announcement.title)")
    }

    /// A soft tinted glyph rather than a loud badge — the app's whole posture is quiet,
    /// and this is the one piece of chrome that arrives uninvited.
    private var icon: some View {
        Image(systemName: "sparkles")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(accentInk)
            .frame(width: 24, height: 24)
            .background(
                Circle().fill(accentInk.opacity(usesDarkChrome ? 0.16 : 0.10))
            )
            .padding(.top, 1)
    }

    /// A real `Button`, not a hit-tested shape: an affordance drawn as geometry exists
    /// for assistive tech only if it also carries an explicit AX identity, and the
    /// simplest way to never get that wrong is a control that already has one.
    private var closeButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(isHoveringClose ? primaryInk : secondaryInk)
                .frame(width: 18, height: 18)
                .background(
                    Circle().fill(
                        isHoveringClose
                            ? (usesDarkChrome ? Color.white.opacity(0.12) : Color.black.opacity(0.07))
                            : Color.clear
                    )
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHoveringClose = $0 }
        .accessibilityLabel("Dismiss announcement")
        .padding(.top, -2)
        .padding(.trailing, -2)
    }

    private var primaryInk: Color {
        MuseModalChrome.primaryTextColor(usesDarkChrome: usesDarkChrome)
    }

    private var secondaryInk: Color {
        MuseModalChrome.secondaryTextColor(usesDarkChrome: usesDarkChrome)
    }

    /// Hover wash behind the action label. Heavier on dark chrome for the same reason the
    /// close button's is: the same alpha reads weaker against a dark card.
    private var actionTintOpacity: Double {
        guard isHoveringAction else { return 0 }
        return usesDarkChrome ? 0.22 : 0.12
    }

    /// The one tinted element. Kept to the system accent so it matches whatever the
    /// user has chosen system-wide rather than inventing a brand colour.
    private var accentInk: Color {
        Color.accentColor
    }
}

/// A one-time, quiet invitation shown only after the user has already worked with a Markdown
/// document in an earlier launch. It shares the announcement card's bottom-corner visual language,
/// but the document glyph and explicit two-choice footer make this a local app preference rather
/// than product news.
struct DefaultMarkdownAppCard: View {
    let status: DefaultMarkdownAppStatus
    let usesDarkChrome: Bool
    var onMakeDefault: () -> Void
    var onNotNow: () -> Void

    static let title = String(localized: "Make Lineform your default Markdown app?")
    static let body = String(localized: "Double-clicking .md and .markdown files will open them in Lineform.")
    static let failureBody = String(localized: "Lineform couldn't change the default app. Try again.")
    static let makeDefaultTitle = String(localized: "Make Default")
    static let notNowTitle = String(localized: "Not Now")
    static let maximumWidth: CGFloat = 344
    static let edgeInset = AnnouncementCard.edgeInset

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.accentColor.opacity(usesDarkChrome ? 0.17 : 0.10)))
                .padding(.top, 1)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(Self.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(primaryInk)
                    .fixedSize(horizontal: false, vertical: true)

                Text(status == .failed ? Self.failureBody : Self.body)
                    .font(.system(size: 11.5))
                    .lineSpacing(2)
                    .foregroundStyle(secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button(Self.makeDefaultTitle, action: onMakeDefault)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(status == .requesting)

                    if status == .requesting {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(SettingsModal.changingDefaultTitle)
                    }

                    Button(Self.notNowTitle, action: onNotNow)
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(secondaryInk)
                        .disabled(status == .requesting)
                }
                .padding(.top, 5)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .frame(maxWidth: Self.maximumWidth, alignment: .leading)
        .modifier(FloatingCardChrome(usesDarkChrome: usesDarkChrome))
        .onExitCommand(perform: onNotNow)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.title)
    }

    private var primaryInk: Color {
        MuseModalChrome.primaryTextColor(usesDarkChrome: usesDarkChrome)
    }

    private var secondaryInk: Color {
        MuseModalChrome.secondaryTextColor(usesDarkChrome: usesDarkChrome)
    }
}

/// The chrome every floating bottom card shares (announcement, default app, AI): Liquid Glass on
/// macOS 26 (before it, an opaque two-variant fill, a hairline and the shadow), the corner, and
/// the arrow cursor. One definition, so the cards cannot drift apart. `usesDarkChrome` is THREADED
/// from the theme.
struct FloatingCardChrome: ViewModifier {
    let usesDarkChrome: Bool

    func body(content: Content) -> some View {
        content
            // Pin the controls to the matching appearance so every glyph reads against the
            // card, whichever page theme is active.
            .environment(\.colorScheme, usesDarkChrome ? .dark : .light)
            .modifier(FloatingCardSurface(usesDarkChrome: usesDarkChrome))
            // The card floats over the text view, whose I-beam otherwise wins the cursor over
            // the whole content area (see CursorRectView — it tracks geometrically).
            .background(CursorRectView(cursor: .arrow))
    }
}

/// The floating card's material. macOS 26: Liquid Glass in the card's shape, in the pinned light
/// or dark. Earlier: an OPAQUE fill, matching `findReplaceBar`'s two-variant treatment (a
/// `.regularMaterial` was tried underneath and removed: the opaque fill above it occluded it
/// completely, so it drew nothing and cost a blur layer), the hairline and the soft shadow.
private struct FloatingCardSurface: ViewModifier {
    let usesDarkChrome: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: AnnouncementCard.cornerRadius, style: .continuous)
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(shape.fill(usesDarkChrome ? Color(white: 0.17) : Color(white: 0.99)))
                .overlay(
                    shape.strokeBorder(
                        usesDarkChrome
                            ? Color.white.opacity(LineformDesign.FloatingCard.hairlineOpacityDark)
                            : Color.black.opacity(LineformDesign.FloatingCard.hairlineOpacityLight),
                        lineWidth: LineformDesign.FloatingCard.hairlineWidth
                    )
                )
                .clipShape(shape)
                .shadow(
                    color: .black.opacity(
                        usesDarkChrome
                            ? LineformDesign.FloatingCard.shadowOpacityDark
                            : LineformDesign.FloatingCard.shadowOpacityLight
                    ),
                    radius: LineformDesign.FloatingCard.shadowRadius,
                    x: LineformDesign.FloatingCard.shadowOffset.width,
                    y: LineformDesign.FloatingCard.shadowOffset.height
                )
        }
    }
}
