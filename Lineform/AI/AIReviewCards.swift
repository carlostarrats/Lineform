import SwiftUI
import LineformCore

/// The AI cards' padding and width cap, then the shared `FloatingCardChrome` — the default-app
/// card's metrics exactly (h14 v13, corner 12), so the cards in the bottom-right corner match.
/// The width HUGS the content up to the cap: no inner `Spacer`, so a short card stays short.
private struct AICardChrome: ViewModifier {
    let usesDarkChrome: Bool

    func body(content: Content) -> some View {
        // A cap, never a fixed width: the editor can be as narrow as 220pt. Not
        // `.frame(maxWidth:)`, which grows to the cap whenever the overlay offers more.
        AICardWidthCap(maximumWidth: AnnouncementCard.maximumWidth) {
            content
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
        }
        .modifier(FloatingCardChrome(usesDarkChrome: usesDarkChrome))
    }
}

/// Offers its one child the proposed width up to `maximumWidth` and takes the child's own size:
/// a short card hugs its content, a long one wraps at the cap, a narrow editor squeezes it.
struct AICardWidthCap: Layout {
    let maximumWidth: CGFloat

    private func offer(_ proposal: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: min(proposal.width ?? maximumWidth, maximumWidth), height: nil)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(offer(proposal)) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// The review card's measured height, so the overlay can keep the current change above it.
struct AIReviewCardHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The ✕ every AI card carries, top-trailing: the announcement card's close button (18×18, 9pt
/// bold xmark, −2 offsets). A real `Button`, so it has an AX identity of its own.
private struct AICardCloseButton: View {
    let usesDarkChrome: Bool
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(isHovering
                    ? MuseModalChrome.primaryTextColor(usesDarkChrome: usesDarkChrome)
                    : MuseModalChrome.secondaryTextColor(usesDarkChrome: usesDarkChrome))
                .frame(width: 18, height: 18)
                .background(
                    Circle().fill(isHovering
                        ? (usesDarkChrome ? Color.white.opacity(0.12) : Color.black.opacity(0.07))
                        : Color.clear)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(AIReviewCardPresentation.closeTitle)
        .padding(.top, -2)
        .padding(.trailing, -2)
    }
}

/// The review card, in the bottom-right corner while a review is up: what is ready ("Rewrite
/// ready"), the keys, then Try Again (an icon button), Reject and Accept; ✕ ends the review (= reject, like Esc). One action
/// is one change, so there is no counter and no batch button. A refused accept ends the review, so
/// its explanation is the status card's message, never drawn here.
struct AIReviewCard: View {
    let title: String
    let hint: String
    let usesDarkChrome: Bool
    var onAccept: () -> Void
    var onReject: () -> Void
    /// Proofread with two or more corrections left; nil hides the button.
    var onAcceptAll: (() -> Void)?
    var onRetry: () -> Void
    var onClose: () -> Void

    init(title: String, hint: String = AIReviewCardPresentation.reviewHint, usesDarkChrome: Bool,
         onAccept: @escaping () -> Void, onReject: @escaping () -> Void,
         onAcceptAll: (() -> Void)? = nil,
         onRetry: @escaping () -> Void = {}, onClose: @escaping () -> Void) {
        self.title = title
        self.hint = hint
        self.usesDarkChrome = usesDarkChrome
        self.onAccept = onAccept
        self.onReject = onReject
        self.onAcceptAll = onAcceptAll
        self.onRetry = onRetry
        self.onClose = onClose
    }

    var body: some View {
        let titles = AIReviewCardPresentation.buttonTitles
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MuseModalChrome.primaryTextColor(usesDarkChrome: usesDarkChrome))
                    .fixedSize(horizontal: false, vertical: true)
                Text(hint)
                    .font(.system(size: 11.5))
                    .lineSpacing(2)
                    .foregroundStyle(MuseModalChrome.secondaryTextColor(usesDarkChrome: usesDarkChrome))
                    .fixedSize(horizontal: false, vertical: true)
                // One row when it fits; otherwise (German, with Accept All) Accept All drops to a
                // row of its own rather than squeezing or truncating the buttons.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        retryButton
                        rejectButton(titles.reject)
                        if let onAcceptAll { acceptAllButton(onAcceptAll) }
                        acceptButton(titles.accept)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            retryButton
                            rejectButton(titles.reject)
                            acceptButton(titles.accept)
                        }
                        if let onAcceptAll { acceptAllButton(onAcceptAll) }
                    }
                }
                .padding(.top, 5)
            }
            AICardCloseButton(usesDarkChrome: usesDarkChrome, action: onClose)
        }
        .modifier(AICardChrome(usesDarkChrome: usesDarkChrome))
        .background(GeometryReader { proxy in
            Color.clear.preference(key: AIReviewCardHeightKey.self, value: proxy.size.height)
        })
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AIReviewCardPresentation.reviewCardLabel)
    }

    private var retryButton: some View {
        Button(action: onRetry) {
            Image(systemName: AIReviewCardPresentation.retrySymbol)
                .font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(AIReviewCardPresentation.retryTitle)
        .accessibilityLabel(AIReviewCardPresentation.retryTitle)
    }

    private func rejectButton(_ title: String) -> some View {
        Button(title, action: onReject).buttonStyle(.bordered).controlSize(.small).fixedSize()
    }

    private func acceptAllButton(_ action: @escaping () -> Void) -> some View {
        Button(AIReviewCardPresentation.acceptAllTitle, action: action).buttonStyle(.bordered).controlSize(.small).fixedSize()
    }

    private func acceptButton(_ title: String) -> some View {
        Button(title, action: onAccept).buttonStyle(.borderedProminent).controlSize(.small).fixedSize()
    }
}

/// A status card for a running request ("Rewriting with ChatGPT…", Esc to cancel — the spinner in
/// the default-app card's icon slot), a message, or Mark's result. Same chrome, corner and ✕ as
/// the review card.
struct AIStatusCard: View {
    let text: String
    let hint: String?
    let showsProgress: Bool
    let usesDarkChrome: Bool
    var onClose: () -> Void

    init(text: String, hint: String?, showsProgress: Bool, usesDarkChrome: Bool, onClose: @escaping () -> Void) {
        self.text = text
        self.hint = hint
        self.showsProgress = showsProgress
        self.usesDarkChrome = usesDarkChrome
        self.onClose = onClose
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if showsProgress {
                // The default-app card's 26pt icon slot, holding the spinner.
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 26, height: 26)
                    .padding(.top, 1)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(text)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MuseModalChrome.primaryTextColor(usesDarkChrome: usesDarkChrome))
                    .fixedSize(horizontal: false, vertical: true)
                if let hint {
                    Text(hint)
                        .font(.system(size: 11.5))
                        .lineSpacing(2)
                        .foregroundStyle(MuseModalChrome.secondaryTextColor(usesDarkChrome: usesDarkChrome))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            AICardCloseButton(usesDarkChrome: usesDarkChrome, action: onClose)
        }
        .modifier(AICardChrome(usesDarkChrome: usesDarkChrome))
        .accessibilityElement(children: .contain)
    }
}
