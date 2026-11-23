import LineformCore
import SwiftUI

/// The iPhone cards' own words (the card text itself is `AIReviewCardPresentation`'s, shared with
/// the Mac). The accessibility titles are the Mac overlay's.
enum AIReviewCardsPresentation {
    static var doneTitle: String { String(localized: "Done") }
    static var nextTitle: String { String(localized: "Next") }
    static var stopTitle: String { String(localized: "Stop") }

    /// Accept Change, Reject Change, End Review, Accept All, Next Change, Previous Change — the
    /// overlay's custom actions and the key commands' titles, in that order.
    static func accessibilityActionTitles() -> [String] {
        [
            String(localized: "Accept Change"),
            String(localized: "Reject Change"),
            String(localized: "End Review"),
            AIReviewCardPresentation.acceptAllTitle,
            String(localized: "Next Change"),
            String(localized: "Previous Change"),
        ]
    }
}

/// The card's measured top, in the window: the overlay keeps the current change above it.
struct AIReviewCardTopKey: PreferenceKey {
    static let defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = min(value, nextValue()) }
}

/// The AI's one card at the bottom of the page, above the keyboard (or the home indicator),
/// placed by `SelectionBottomChrome` from the keyboard tracker. The Mac's `AIStatusCard` and
/// `AIReviewCard`, full-width in the iPhone's floating-card chrome:
///
/// - **Running:** a spinner, "Rephrasing with Claude…", Stop.
/// - **Message:** the message, ✕; it steps aside after 8 s, as on the Mac (never while VoiceOver
///   runs: `messageDismissDelay`).
/// - **Mark:** "3 sentences found", Done (the wash goes).
/// - **Review:** what is ready ("Rephrase ready", "Proofread · 2 of 4"), then Try Again, Reject,
///   Accept, and for two or more pending Next and Accept All; Done ends the review (= rejects
///   what is pending, keeping what was accepted).
///
/// No Esc / Return hints: the hardware keys are the overlay's key commands. Each card is one
/// accessibility container with its decisions as custom actions, and VoiceOver's escape closes it.
/// Its states are spoken by the shared controller (`AIEditorSurface.announceAI`). At accessibility
/// sizes the running, marks and review cards stack their buttons under the text.
struct AIReviewCardsView: View {
    @ObservedObject var controller: SelectionController
    var profile: ReadingProfile

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    /// The glyph sizes scale with the text around them (13 and 12 pt at the default size).
    @ScaledMetric(relativeTo: .subheadline) private var retryGlyphSize: CGFloat = 14
    @ScaledMetric(relativeTo: .footnote) private var closeGlyphSize: CGFloat = 12

    /// How long a message stays before it steps aside: 8 s, as on the Mac — and never on its own
    /// while VoiceOver runs (WCAG 2.2.1): the writer closes it, or the next action replaces it.
    static func messageDismissDelay(voiceOverRunning: Bool) -> Duration? {
        voiceOverRunning ? nil : .seconds(8)
    }

    var body: some View {
        let theme = Theme.theme(for: profile)
        let ink = Color(uiColor: theme.textColor)
        let stacks = dynamicTypeSize.isAccessibilitySize
        Group {
            switch controller.aiState {
            case .idle:
                EmptyView()
            case let .running(action, provider):
                card(theme: theme, ink: ink) {
                    textAndButton(stacks: stacks) {
                        HStack(spacing: 12) {
                            ProgressView().accessibilityHidden(true)
                            Text(AIReviewCardPresentation.progressText(for: action, provider: provider))
                                .font(.subheadline.weight(.semibold))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } button: {
                        Button(AIReviewCardsPresentation.stopTitle) { controller.aiController.cancel() }
                            .buttonStyle(.bordered)
                    }
                }
                .accessibilityAction(named: AIReviewCardsPresentation.stopTitle) { controller.aiController.cancel() }
                .accessibilityAction(.escape) { controller.aiController.cancel() }
            case .message(let message):
                card(theme: theme, ink: ink) {
                    HStack(alignment: .top, spacing: 12) {
                        Text(message)
                            .font(.subheadline.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        closeButton(theme: theme) { controller.aiController.dismissMessage() }
                    }
                }
                .accessibilityAction(.escape) { controller.aiController.dismissMessage() }
                .task(id: message) {
                    guard let delay = Self.messageDismissDelay(voiceOverRunning: voiceOverEnabled || UIAccessibility.isVoiceOverRunning),
                          (try? await Task.sleep(for: delay)) != nil else { return }
                    controller.aiController.dismissMessage()
                }
            case .marking(let ranges):
                card(theme: theme, ink: ink) {
                    textAndButton(stacks: stacks) {
                        Text(AIActionController.markedMessage(ranges.count))
                            .font(.subheadline.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                    } button: {
                        Button(AIReviewCardsPresentation.doneTitle) { controller.aiController.dismissMarks() }
                            .buttonStyle(.bordered)
                    }
                }
                .accessibilityAction(named: AIReviewCardsPresentation.doneTitle) { controller.aiController.dismissMarks() }
                .accessibilityAction(.escape) { controller.aiController.dismissMarks() }
            case .reviewing(let session):
                reviewCard(session, theme: theme, ink: ink, stacks: stacks)
            }
        }
        .background(GeometryReader { proxy in
            Color.clear.preference(key: AIReviewCardTopKey.self, value: proxy.frame(in: .global).minY)
        })
    }

    /// Text then its button on one line; at accessibility sizes the button goes under the text,
    /// so neither is squeezed.
    @ViewBuilder
    private func textAndButton<Leading: View, Trailing: View>(
        stacks: Bool,
        @ViewBuilder text: () -> Leading,
        @ViewBuilder button: () -> Trailing
    ) -> some View {
        if stacks {
            VStack(alignment: .leading, spacing: 10) {
                text()
                button()
            }
        } else {
            HStack(spacing: 12) {
                text()
                Spacer(minLength: 8)
                button()
            }
        }
    }

    private func reviewCard(_ session: AIReviewSession, theme: Theme, ink: Color, stacks: Bool) -> some View {
        let titles = AIReviewCardPresentation.buttonTitles
        let handle: (AIReviewCommand) -> Void = { command in controller.aiController.handle(command) }
        let offersMore = session.pending.count >= 2
        let acceptAll = AIReviewCardPresentation.offersAcceptAll(session)
        let page = Color(uiColor: theme.backgroundColor)
        return card(theme: theme, ink: ink) {
            VStack(alignment: .leading, spacing: 10) {
                textAndButton(stacks: stacks) {
                    Text(AIReviewCardPresentation.title(for: session))
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                } button: {
                    // A 44 pt target; on one line the reach is taken back with negative padding,
                    // so the card lays out as it always did.
                    Button { handle(.end) } label: {
                        Text(AIReviewCardsPresentation.doneTitle)
                            .font(.subheadline)
                            .frame(minWidth: Self.minimumTarget, minHeight: Self.minimumTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .padding(.vertical, stacks ? 0 : -13)
                    .accessibilityIdentifier("ai.reviewDone")
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        retryButton { handle(.retry) }
                        Button(titles.reject) { handle(.rejectCurrent) }.buttonStyle(.bordered).fixedSize()
                        if offersMore {
                            Button(AIReviewCardsPresentation.nextTitle) { handle(.move(1)) }.buttonStyle(.bordered).fixedSize()
                        }
                        if acceptAll {
                            Button(AIReviewCardPresentation.acceptAllTitle) { handle(.acceptAll) }.buttonStyle(.bordered).fixedSize()
                        }
                        Spacer(minLength: 0)
                        acceptButton(titles.accept, page: page) { handle(.acceptCurrent) }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            retryButton { handle(.retry) }
                            Button(titles.reject) { handle(.rejectCurrent) }.buttonStyle(.bordered).fixedSize()
                            Spacer(minLength: 0)
                            acceptButton(titles.accept, page: page) { handle(.acceptCurrent) }
                        }
                        HStack(spacing: 8) {
                            if offersMore {
                                Button(AIReviewCardsPresentation.nextTitle) { handle(.move(1)) }.buttonStyle(.bordered).fixedSize()
                            }
                            if acceptAll {
                                Button(AIReviewCardPresentation.acceptAllTitle) { handle(.acceptAll) }.buttonStyle(.bordered).fixedSize()
                            }
                        }
                    }
                    // Accessibility sizes: one decision per line, Accept first.
                    VStack(alignment: .leading, spacing: 8) {
                        acceptButton(titles.accept, page: page, fixed: false) { handle(.acceptCurrent) }
                        Button(titles.reject) { handle(.rejectCurrent) }.buttonStyle(.bordered)
                        if offersMore {
                            Button(AIReviewCardsPresentation.nextTitle) { handle(.move(1)) }.buttonStyle(.bordered)
                        }
                        if acceptAll {
                            Button(AIReviewCardPresentation.acceptAllTitle) { handle(.acceptAll) }.buttonStyle(.bordered)
                        }
                        retryButton { handle(.retry) }
                    }
                }
                .tint(ink)
            }
        }
        .accessibilityLabel(AIReviewCardPresentation.reviewCardLabel)
        .modifier(ReviewCardActions(offersMore: offersMore, acceptAll: acceptAll, handle: handle))
        .accessibilityAction(.escape) { handle(.end) }
        .accessibilityIdentifier("ai.reviewCard")
    }

    /// The prominent decision: the page colour on the ink, so its label reads (the card's ink
    /// foreground would otherwise draw it ink on ink).
    private func acceptButton(_ title: String, page: Color, fixed: Bool = true,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).foregroundStyle(page)
        }
        .buttonStyle(.borderedProminent)
        .fixedSize(horizontal: fixed, vertical: true)
    }

    private func retryButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: AIReviewCardPresentation.retrySymbol)
                .font(.system(size: retryGlyphSize, weight: .semibold))
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(AIReviewCardPresentation.retryTitle)
    }

    /// A 28 pt glyph circle drawn, a 44 pt target: the extra reach is taken back with negative
    /// padding, so the card's layout is the one it always had.
    private func closeButton(theme: Theme, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: closeGlyphSize, weight: .bold))
                .foregroundStyle(PhoneInk(theme: theme).icon)
                .frame(width: 28, height: 28)
                .frame(width: Self.minimumTarget, height: Self.minimumTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(-(Self.minimumTarget - 28) / 2)
        .accessibilityLabel(AIReviewCardPresentation.closeTitle)
        .accessibilityIdentifier("ai.messageClose")
    }

    /// The smallest touch target (Apple's 44 × 44 pt).
    static let minimumTarget: CGFloat = 44

    private func card<Content: View>(theme: Theme, ink: Color, @ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(14)
            .foregroundStyle(ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .floatingCardChrome(theme: theme, cornerRadius: LineformDesign.FloatingCard.radius)
            .accessibilityElement(children: .contain)
    }
}

/// The review card's decisions as VoiceOver / Switch Control custom actions. Next Change and
/// Accept All are offered only when they would do something (the overlay's own rule).
private struct ReviewCardActions: ViewModifier {
    let offersMore: Bool
    let acceptAll: Bool
    let handle: (AIReviewCommand) -> Void

    func body(content: Content) -> some View {
        let titles = AIReviewCardsPresentation.accessibilityActionTitles()
        content
            .accessibilityAction(named: titles[0]) { handle(.acceptCurrent) }
            .accessibilityAction(named: titles[1]) { handle(.rejectCurrent) }
            .accessibilityActions {
                if offersMore {
                    Button(titles[4]) { handle(.move(1)) }
                }
                if acceptAll {
                    Button(titles[3]) { handle(.acceptAll) }
                }
            }
            .accessibilityAction(named: titles[2]) { handle(.end) }
    }
}
