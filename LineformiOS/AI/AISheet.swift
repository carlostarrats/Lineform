import LineformCore
import SwiftUI
import UIKit

/// The iPhone's AI sheet (2026-11-24): the Mac drawer's conversation (`AIConversationView`) in a
/// sheet that opens at three-quarters of the screen and drags to half or a quarter without
/// closing. There is no ✕ and no title: dragging it down closes it. Thumb-sized targets
/// (`AIConversationMetrics`). The conversation lives in `SelectionController.conversation`, so
/// closing the sheet keeps it until another document replaces this one.
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

    var body: some View {
        let theme = Theme.theme(for: profile)
        let inks = PhoneInk(theme: theme, userInterfaceStyle: theme.usesDarkChrome ? .dark : .light)
        let page = Color(uiColor: theme.backgroundColor)
        AIConversationView(
            conversation: conversation,
            style: AIConversationStyle(surface: page, page: page, ink: Color(uiColor: theme.textColor),
                                       secondaryInk: inks.secondary, isDark: theme.usesDarkChrome),
            onClose: nil
        )
        .padding(.top, 14)
        .environment(\.colorScheme, theme.usesDarkChrome ? .dark : .light)
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { onTopChange(proxy.frame(in: .global).minY) }
                .onChange(of: proxy.frame(in: .global).minY) { _, top in onTopChange(top) }
        })
        .presentationDetents(Self.detents, selection: $detent)
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .presentationBackground(page)
        .onDisappear { onTopChange(.infinity) }
    }
}
