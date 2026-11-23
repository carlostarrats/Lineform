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
/// - **Message:** the message, ✕; it steps aside after 8 s, as on the Mac.
/// - **Mark:** "3 sentences found", Done (the wash goes).
/// - **Review:** what is ready ("Rephrase ready", "Proofread · 2 of 4"), then Try Again, Reject,
///   Accept, and for two or more pending Next and Accept All; Done ends the review (= rejects
///   what is pending, keeping what was accepted).
///
/// No Esc / Return hints: the hardware keys are the overlay's key commands. Each card is one
/// accessibility container with its decisions as custom actions.
struct AIReviewCardsView: View {
    @ObservedObject var controller: SelectionController
    var profile: ReadingProfile

    var body: some View {
        let theme = Theme.theme(for: profile)
        let ink = Color(uiColor: theme.textColor)
        Group {
            switch controller.aiState {
            case .idle:
                EmptyView()
            case let .running(action, provider):
                card(theme: theme, ink: ink) {
                    HStack(spacing: 12) {
                        ProgressView().accessibilityHidden(true)
                        Text(AIReviewCardPresentation.progressText(for: action, provider: provider))
                            .font(.subheadline.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button(AIReviewCardsPresentation.stopTitle) { controller.aiController.cancel() }
                            .buttonStyle(.bordered)
                    }
                }
                .accessibilityAction(named: AIReviewCardsPresentation.stopTitle) { controller.aiController.cancel() }
            case .message(let message):
                card(theme: theme, ink: ink) {
                    HStack(alignment: .top, spacing: 12) {
                        Text(message)
                            .font(.subheadline.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        closeButton(ink: ink) { controller.aiController.dismissMessage() }
                    }
                }
                .task(id: message) {
                    guard (try? await Task.sleep(for: .seconds(8))) != nil else { return }
                    controller.aiController.dismissMessage()
                }
            case .marking(let ranges):
                card(theme: theme, ink: ink) {
                    HStack(spacing: 12) {
                        Text(AIActionController.markedMessage(ranges.count))
                            .font(.subheadline.weight(.semibold))
                        Spacer(minLength: 8)
                        Button(AIReviewCardsPresentation.doneTitle) { controller.aiController.dismissMarks() }
                            .buttonStyle(.bordered)
                    }
                }
                .accessibilityAction(named: AIReviewCardsPresentation.doneTitle) { controller.aiController.dismissMarks() }
            case .reviewing(let session):
                reviewCard(session, theme: theme, ink: ink)
            }
        }
        .background(GeometryReader { proxy in
            Color.clear.preference(key: AIReviewCardTopKey.self, value: proxy.frame(in: .global).minY)
        })
    }

    private func reviewCard(_ session: AIReviewSession, theme: Theme, ink: Color) -> some View {
        let titles = AIReviewCardPresentation.buttonTitles
        let handle: (AIReviewCommand) -> Void = { command in controller.aiController.handle(command) }
        let offersMore = session.pending.count >= 2
        let acceptAll = AIReviewCardPresentation.offersAcceptAll(session)
        return card(theme: theme, ink: ink) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(AIReviewCardPresentation.title(for: session))
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button(AIReviewCardsPresentation.doneTitle) { handle(.end) }
                        .font(.subheadline)
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
                        acceptButton(titles.accept, page: Color(uiColor: theme.backgroundColor)) { handle(.acceptCurrent) }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            retryButton { handle(.retry) }
                            Button(titles.reject) { handle(.rejectCurrent) }.buttonStyle(.bordered).fixedSize()
                            Spacer(minLength: 0)
                            acceptButton(titles.accept, page: Color(uiColor: theme.backgroundColor)) { handle(.acceptCurrent) }
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
                }
                .tint(ink)
            }
        }
        .accessibilityLabel(AIReviewCardPresentation.reviewCardLabel)
        .modifier(ReviewCardActions(offersMore: offersMore, acceptAll: acceptAll, handle: handle))
        .accessibilityIdentifier("ai.reviewCard")
    }

    /// The prominent decision: the page colour on the ink, so its label reads (the card's ink
    /// foreground would otherwise draw it ink on ink).
    private func acceptButton(_ title: String, page: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).foregroundStyle(page)
        }
        .buttonStyle(.borderedProminent)
        .fixedSize()
    }

    private func retryButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: AIReviewCardPresentation.retrySymbol)
                .font(.system(size: 14, weight: .semibold))
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(AIReviewCardPresentation.retryTitle)
    }

    private func closeButton(ink: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .bold))
                .opacity(0.6)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AIReviewCardPresentation.closeTitle)
    }

    private func card<Content: View>(theme: Theme, ink: Color, @ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(14)
            .foregroundStyle(ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .floatingCardChrome(theme: theme, cornerRadius: LineformDesign.FloatingCard.radius)
            .accessibilityElement(children: .contain)
    }
}

/// The review card's decisions as VoiceOver / Switch Control custom actions.
private struct ReviewCardActions: ViewModifier {
    let offersMore: Bool
    let acceptAll: Bool
    let handle: (AIReviewCommand) -> Void

    func body(content: Content) -> some View {
        let titles = AIReviewCardsPresentation.accessibilityActionTitles()
        content
            .accessibilityAction(named: titles[0]) { handle(.acceptCurrent) }
            .accessibilityAction(named: titles[1]) { handle(.rejectCurrent) }
            .accessibilityAction(named: titles[4]) { if offersMore { handle(.move(1)) } }
            .accessibilityAction(named: titles[3]) { if acceptAll { handle(.acceptAll) } }
            .accessibilityAction(named: titles[2]) { handle(.end) }
    }
}
