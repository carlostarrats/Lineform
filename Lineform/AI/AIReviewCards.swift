import SwiftUI

/// The copy on the AI's floating cards. Every string is localized HERE, at its definition (a
/// `String` passed to `Text`/`Button` takes the verbatim overload). `bundle` exists so tests can
/// resolve each language through its `.lproj`.
enum AIReviewCardPresentation {
    /// The review card's label: what is ready ("Rewrite ready"). Mark never opens a review; its
    /// cases name the action so the switch stays total.
    static func title(for action: AIAction, bundle: Bundle = .main) -> String {
        switch action {
        case .trim: return String(localized: "Trim ready", bundle: bundle)
        case .cutInHalf: return String(localized: "Cut ready", bundle: bundle)
        case .rewrite: return String(localized: "Rewrite ready", bundle: bundle)
        case .proofread: return String(localized: "Proofread ready", bundle: bundle)
        case .markWeakest, .markLong: return action.title
        }
    }

    /// One change, one decision: Reject, then Accept (the prominent one, trailing).
    static var buttonTitles: (reject: String, accept: String) { buttonTitles(bundle: .main) }
    static func buttonTitles(bundle: Bundle) -> (reject: String, accept: String) {
        (String(localized: "Reject", bundle: bundle), String(localized: "Accept", bundle: bundle))
    }

    /// The review's modal keys, on the card so they are discoverable.
    static var reviewHint: String { reviewHint(bundle: .main) }
    static func reviewHint(bundle: Bundle) -> String {
        String(localized: "Return to accept · Esc to reject", bundle: bundle)
    }

    /// "Trimming with Claude…"; for Other, "Trimming with your AI…" (its address is not a name).
    static func progressText(for action: AIAction, provider: AIProvider, bundle: Bundle = .main) -> String {
        guard provider != .other else {
            switch action {
            case .trim: return String(localized: "Trimming with your AI…", bundle: bundle)
            case .cutInHalf: return String(localized: "Cutting with your AI…", bundle: bundle)
            case .rewrite: return String(localized: "Rewriting with your AI…", bundle: bundle)
            case .proofread: return String(localized: "Proofreading with your AI…", bundle: bundle)
            case .markWeakest, .markLong: return String(localized: "Marking with your AI…", bundle: bundle)
            }
        }
        let name = provider.displayName
        switch action {
        case .trim: return String(localized: "Trimming with \(name)…", bundle: bundle)
        case .cutInHalf: return String(localized: "Cutting with \(name)…", bundle: bundle)
        case .rewrite: return String(localized: "Rewriting with \(name)…", bundle: bundle)
        case .proofread: return String(localized: "Proofreading with \(name)…", bundle: bundle)
        case .markWeakest, .markLong: return String(localized: "Marking with \(name)…", bundle: bundle)
        }
    }

    static var cancelHint: String { cancelHint(bundle: .main) }
    static func cancelHint(bundle: Bundle) -> String { String(localized: "Esc to cancel", bundle: bundle) }

    static var markHint: String { markHint(bundle: .main) }
    static func markHint(bundle: Bundle) -> String { String(localized: "Esc clears marks", bundle: bundle) }

    static var closeTitle: String { String(localized: "Close") }
    static var reviewCardLabel: String { String(localized: "Suggested changes") }
}

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
/// ready"), the keys, then Reject and Accept; ✕ ends the review (= reject, like Esc). One action
/// is one change, so there is no counter and no batch button. A refused accept ends the review, so
/// its explanation is the status card's message, never drawn here.
struct AIReviewCard: View {
    let title: String
    let usesDarkChrome: Bool
    var onAccept: () -> Void
    var onReject: () -> Void
    var onClose: () -> Void

    init(title: String, usesDarkChrome: Bool,
         onAccept: @escaping () -> Void, onReject: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.title = title
        self.usesDarkChrome = usesDarkChrome
        self.onAccept = onAccept
        self.onReject = onReject
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
                Text(AIReviewCardPresentation.reviewHint)
                    .font(.system(size: 11.5))
                    .lineSpacing(2)
                    .foregroundStyle(MuseModalChrome.secondaryTextColor(usesDarkChrome: usesDarkChrome))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button(titles.reject, action: onReject)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button(titles.accept, action: onAccept)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                .padding(.top, 5)
            }
            AICardCloseButton(usesDarkChrome: usesDarkChrome, action: onClose)
        }
        .modifier(AICardChrome(usesDarkChrome: usesDarkChrome))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AIReviewCardPresentation.reviewCardLabel)
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
