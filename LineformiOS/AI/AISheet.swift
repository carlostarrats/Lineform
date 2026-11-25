import LineformCore
import SwiftUI
import UIKit

/// The iPhone's AI sheet (2026-11-24): the Mac drawer's conversation (`AIConversationView`) in a
/// sheet that opens at three-quarters of the screen and drags to half or a quarter without
/// closing. There is no ✕ and no title: dragging it down closes it, except while a request runs
/// or a suggestion waits for Accept or Reject (those live only here: closing then would leave the
/// read-only review with no way out). The conversation lives in `SelectionController.conversation`,
/// so closing the sheet keeps it until another document replaces this one. Thumb-sized targets
/// (`AIConversationMetrics`).
///
/// The sheet draws on its own surface, never the page (owner review 4, the approved prompt-words
/// mockup's `--chrome`): #FDFDFD on a light theme, #262626 on a dark one. The AI's bubble keeps the
/// page colour, so it reads as a card on the sheet. Every ink is measured on both (`Inks`).
struct AISheetView: View {
    @ObservedObject var conversation: AIConversation
    let profile: ReadingProfile
    /// Where the sheet's top sits in the window, so the review overlay keeps the current change
    /// above it (`SelectionController.aiCardTopInWindow`).
    var onTopChange: (CGFloat) -> Void = { _ in }

    @State private var detent: PresentationDetent = Self.opening

    static let quarter = PresentationDetent.fraction(0.25)
    static let opening = PresentationDetent.fraction(0.75)
    static let detents: Set<PresentationDetent> = [quarter, .medium, opening]

    /// The sheet's surface on a light theme: the mockup's `--chrome` (#FDFDFD).
    static let lightSurface = UIColor(red: 0xFD / 255, green: 0xFD / 255, blue: 0xFD / 255, alpha: 1)
    /// The sheet's surface on a dark theme: the mockup's Quiet `--chrome` (#262626), a step apart
    /// from every dark page (Quiet's #303030 above it, Night's and the high-contrast black below).
    static let darkSurface = UIColor(red: 0x26 / 255, green: 0x26 / 255, blue: 0x26 / 255, alpha: 1)

    static func surface(for theme: Theme) -> UIColor {
        theme.usesDarkChrome ? darkSurface : lightSurface
    }

    /// A request is running or a suggestion waits for a decision: the sheet cannot be swiped away.
    static func locksDismissal(_ conversation: AIConversation) -> Bool {
        conversation.isWorking || conversation.pendingSuggestion != nil
    }

    var body: some View {
        let theme = Theme.theme(for: profile)
        let inks = Inks(theme: theme)
        AIConversationView(
            conversation: conversation,
            style: AIConversationStyle(surface: Color(uiColor: inks.surface), page: Color(uiColor: inks.page),
                                       ink: Color(uiColor: inks.primary), secondaryInk: Color(uiColor: inks.secondary),
                                       isDark: theme.usesDarkChrome),
            onClose: nil
        )
        .padding(.top, 14)
        .environment(\.colorScheme, theme.usesDarkChrome ? .dark : .light)
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { onTopChange(proxy.frame(in: .global).minY) }
                .onChange(of: proxy.frame(in: .global).minY) { _, top in onTopChange(top) }
        })
        .modifier(AISheetPresentation(detent: $detent, surface: Color(uiColor: inks.surface),
                                      locksDismissal: Self.locksDismissal(conversation)))
        .onDisappear { onTopChange(.infinity) }
    }
}

/// The sheet's presentation, bundled so the view's modifier chain stays short (CI's type-checker).
private struct AISheetPresentation: ViewModifier {
    @Binding var detent: PresentationDetent
    let surface: Color
    let locksDismissal: Bool

    func body(content: Content) -> some View {
        content
            .presentationDetents(AISheetView.detents, selection: $detent)
            .presentationDragIndicator(.visible)
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            .presentationBackground(surface)
            .interactiveDismissDisabled(locksDismissal)
    }
}

extension AISheetView {
    /// Every ink the sheet draws text with, made readable (AA) on the sheet's surface AND on the
    /// page-coloured AI bubble. `AISheetTests` measures `entries`.
    @MainActor
    struct Inks {
        let surface: UIColor
        /// The AI's bubble: the page colour (light), or the dark bubble's wash over the surface.
        let page: UIColor
        let primary: UIColor
        let secondary: UIColor

        /// The dark bubble as it lands (`AIConversationStyle.aiBubble`: white at 7.5% over the surface).
        static let darkBubbleWhiteAlpha: CGFloat = 0.075

        init(theme: Theme) {
            let style: UIUserInterfaceStyle = theme.usesDarkChrome ? .dark : .light
            var sheet = PhoneInk(theme: theme, userInterfaceStyle: style).theme
            let page = sheet.backgroundColor
            let surface = AISheetView.surface(for: sheet)
            sheet.backgroundColor = surface
            self.surface = surface
            self.page = page
            let bubble = sheet.usesDarkChrome
                ? PhoneInk.flatten(.white, alpha: Self.darkBubbleWhiteAlpha, over: surface)
                : page
            func readable(_ base: UIColor) -> UIColor {
                let onSurface = sheet.readableInk(base, minimumRatio: PhoneInk.Role.textMinimum)
                return sheet.readableInk(onSurface, minimumRatio: PhoneInk.Role.textMinimum, on: bubble)
            }
            primary = readable(sheet.textColor)
            secondary = readable(sheet.textColor.withAlphaComponent(0.6))
            bubbleSurface = bubble
        }

        /// The bubble's colour as measured.
        let bubbleSurface: UIColor

        var entries: [PhoneInk.Entry] {
            [
                PhoneInk.Entry(name: "primary", color: primary, surface: surface, minimumRatio: PhoneInk.Role.textMinimum),
                PhoneInk.Entry(name: "secondary", color: secondary, surface: surface, minimumRatio: PhoneInk.Role.textMinimum),
                PhoneInk.Entry(name: "primaryOnBubble", color: primary, surface: bubbleSurface, minimumRatio: PhoneInk.Role.textMinimum),
                PhoneInk.Entry(name: "secondaryOnBubble", color: secondary, surface: bubbleSurface,
                               minimumRatio: PhoneInk.Role.textMinimum),
            ]
        }
    }
}
