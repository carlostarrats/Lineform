import SwiftUI

/// The copy on the AI's floating cards. Every string is localized HERE, at its definition (a
/// `String` passed to `Text`/`Button` takes the verbatim overload). `bundle` exists so tests can
/// resolve each language through its `.lproj`.
enum AIReviewCardPresentation {
    static func buttonTitles(hasDecided: Bool, bundle: Bundle = .main) -> (accept: String, reject: String) {
        hasDecided
            ? (String(localized: "Accept Remaining", bundle: bundle), String(localized: "Reject Remaining", bundle: bundle))
            : (String(localized: "Accept All", bundle: bundle), String(localized: "Reject All", bundle: bundle))
    }

    /// "3 of 7".
    static func positionText(current: Int, total: Int, bundle: Bundle = .main) -> String {
        String(localized: "\(current) of \(total)", bundle: bundle)
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

    /// A one-change review has no card of its own; this quiet hint makes its keys discoverable.
    static var singleChangeHint: String { singleChangeHint(bundle: .main) }
    static func singleChangeHint(bundle: Bundle) -> String {
        String(localized: "Return to accept · Esc to dismiss", bundle: bundle)
    }

    static var closeTitle: String { String(localized: "Close") }
    static var reviewCardLabel: String { String(localized: "Suggested changes") }
}

/// The AI cards' padding and width cap, then the shared `FloatingCardChrome`.
private struct AICardChrome: ViewModifier {
    let usesDarkChrome: Bool
    let maximumWidth: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(.leading, 14)
            .padding(.trailing, 12)
            .padding(.vertical, 10)
            // A cap, never a fixed width: the editor can be as narrow as 220pt.
            .frame(maxWidth: maximumWidth)
            .modifier(FloatingCardChrome(usesDarkChrome: usesDarkChrome))
    }
}

/// The review card, floating at the bottom of the editor while a review has more than one change:
/// "3 of 7" and Accept All / Reject All (Accept Remaining / Reject Remaining once anything is
/// decided). A refused decision's notice is drawn here too — seen, not only announced.
struct AIReviewCard: View {
    let position: Int
    let total: Int
    let hasDecided: Bool
    let notice: String?
    let usesDarkChrome: Bool
    var onAcceptRemaining: () -> Void
    var onRejectRemaining: () -> Void

    init(position: Int, total: Int, hasDecided: Bool, notice: String? = nil, usesDarkChrome: Bool,
         onAcceptRemaining: @escaping () -> Void, onRejectRemaining: @escaping () -> Void) {
        self.position = position
        self.total = total
        self.hasDecided = hasDecided
        self.notice = notice
        self.usesDarkChrome = usesDarkChrome
        self.onAcceptRemaining = onAcceptRemaining
        self.onRejectRemaining = onRejectRemaining
    }

    var body: some View {
        let titles = AIReviewCardPresentation.buttonTitles(hasDecided: hasDecided)
        VStack(alignment: .leading, spacing: 6) {
            if let notice {
                Text(notice)
                    .font(.system(size: 11.5))
                    .foregroundStyle(MuseModalChrome.primaryTextColor(usesDarkChrome: usesDarkChrome))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                if position > 0 {
                    Text(AIReviewCardPresentation.positionText(current: position, total: total))
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(MuseModalChrome.secondaryTextColor(usesDarkChrome: usesDarkChrome))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Button(titles.reject, action: onRejectRemaining)
                    .controlSize(.small)
                Button(titles.accept, action: onAcceptRemaining)
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            }
        }
        .modifier(AICardChrome(usesDarkChrome: usesDarkChrome, maximumWidth: 380))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AIReviewCardPresentation.reviewCardLabel)
    }
}

/// A one-line status card for a running request ("Trimming with Claude…", Esc to cancel), a
/// message, or Mark's result. Same chrome and place as the review card.
struct AIStatusCard: View {
    let text: String
    let hint: String?
    let showsProgress: Bool
    let usesDarkChrome: Bool
    var onClose: () -> Void

    @State private var isHoveringClose = false

    init(text: String, hint: String?, showsProgress: Bool, usesDarkChrome: Bool, onClose: @escaping () -> Void) {
        self.text = text
        self.hint = hint
        self.showsProgress = showsProgress
        self.usesDarkChrome = usesDarkChrome
        self.onClose = onClose
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MuseModalChrome.primaryTextColor(usesDarkChrome: usesDarkChrome))
                    .fixedSize(horizontal: false, vertical: true)
                if let hint {
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundStyle(MuseModalChrome.secondaryTextColor(usesDarkChrome: usesDarkChrome))
                }
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(isHoveringClose
                        ? MuseModalChrome.primaryTextColor(usesDarkChrome: usesDarkChrome)
                        : MuseModalChrome.secondaryTextColor(usesDarkChrome: usesDarkChrome))
                    .frame(width: 18, height: 18)
                    .background(
                        Circle().fill(isHoveringClose
                            ? (usesDarkChrome ? Color.white.opacity(0.12) : Color.black.opacity(0.07))
                            : Color.clear)
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { isHoveringClose = $0 }
            .accessibilityLabel(AIReviewCardPresentation.closeTitle)
        }
        .modifier(AICardChrome(usesDarkChrome: usesDarkChrome, maximumWidth: AnnouncementCard.maximumWidth))
        .accessibilityElement(children: .contain)
    }
}
