import LineformCore
import SwiftUI
import UIKit

/// The comment field (spec §5.5): when Ask AI is tapped the row slides down and this full-width
/// field comes up at the bottom, with no drag handle. "Ask Claude" and Cancel at the top, the note,
/// then the Action menu (the `AIAction` rewrite groups, Custom first and by default) and Send.
///
/// - Return in the note inserts a newline; Send is a button. While an input method is composing,
///   Send is off, so Return there only confirms the candidate.
/// - Send needs a note when the action is Custom (`SelectionToolbarModel.canSend`).
/// - Cancel with the button, by swiping the field down, or with VoiceOver's escape (two-finger Z).
/// - At the accessibility text sizes the header and the action row stack vertically. Cancel, the
///   Action menu and Send are 44 pt targets; the extra is taken back with negative padding, so the
///   field looks as it always did. Send is a fixed-size glyph and shows the Large Content Viewer.
struct CommentField: View {
    @ObservedObject var controller: SelectionController
    @ObservedObject private var model: SelectionToolbarModel
    var profile: ReadingProfile
    @GestureState private var dragOffset: CGFloat = 0
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .subheadline) private var chevronSize: CGFloat = 9

    /// How far down a swipe must travel to cancel.
    static let cancelDistance: CGFloat = 60
    /// Send's drawn circle, and the target it is.
    static let sendDrawnSide: CGFloat = 32
    static let minimumTarget: CGFloat = 44
    /// What a text button (Cancel, the Action menu) is padded by above and below: a subheadline
    /// line is at least 18 pt, so it is then at least 44 pt tall.
    static let textTargetOutset: CGFloat = 13

    init(controller: SelectionController, profile: ReadingProfile) {
        self.controller = controller
        _model = ObservedObject(wrappedValue: controller.model)
        self.profile = profile
    }

    var body: some View {
        let theme = Theme.theme(for: profile)
        let ink = Color(uiColor: theme.textColor)
        let inks = PhoneInk(theme: theme, userInterfaceStyle: theme.usesDarkChrome ? .dark : .light)
        let stacks = dynamicTypeSize.isAccessibilitySize
        VStack(alignment: .leading, spacing: 10) {
            rowLayout(stacks: stacks, alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(SelectionToolbarPresentation.commentTitle(aiName: model.aiName ?? SelectionToolbarPresentation.aiName(for: .other)))
                        .font(.subheadline.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    // What Send sends, quietly, when it is the whole document.
                    if model.isWholeDocument {
                        Text(SelectionToolbarPresentation.wholeDocumentSubtitle)
                            .font(.footnote)
                            .foregroundStyle(inks.secondary)
                    }
                }
                if !stacks { Spacer(minLength: 8) }
                Button { controller.cancelComment() } label: {
                    Text(String(localized: "Cancel"))
                        .font(.subheadline)
                        .padding(.vertical, Self.textTargetOutset)
                        .frame(minWidth: Self.minimumTarget)
                        .contentShape(Rectangle())
                }
                // Side by side the extra is taken back, so the header keeps its height; stacked,
                // it is kept, so the targets never overlap.
                .padding(.vertical, stacks ? 0 : -Self.textTargetOutset)
            }
            ZStack(alignment: .topLeading) {
                CommentNoteView(controller: controller, profile: profile)
                if model.note.isEmpty {
                    Text(SelectionToolbarPresentation.notePlaceholder)
                        .font(.body)
                        .foregroundStyle(inks.color(.tertiaryOnCommentField))
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(ink.opacity(PhoneInk.commentFieldWashAlpha)))
            rowLayout(stacks: stacks, alignment: .center) {
                actionMenu(inks: inks, stacks: stacks)
                if !stacks { Spacer(minLength: 8) }
                sendButton(theme: theme, ink: ink, stacks: stacks)
            }
        }
        .padding(14)
        .foregroundStyle(ink)
        .frame(maxWidth: .infinity, alignment: .leading)
        .floatingCardChrome(theme: theme, cornerRadius: LineformDesign.FloatingCard.radius)
        .offset(y: max(0, dragOffset))
        .gesture(
            DragGesture(minimumDistance: 12)
                .updating($dragOffset) { value, state, _ in state = value.translation.height }
                .onEnded { value in
                    if value.translation.height > Self.cancelDistance { controller.cancelComment() }
                }
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("selection.comment")
        .accessibilityAction(.escape) { controller.cancelComment() }
    }

    /// Side by side, or stacked (leading) at the accessibility text sizes.
    @ViewBuilder
    private func rowLayout<Content: View>(
        stacks: Bool, alignment: VerticalAlignment, @ViewBuilder content: () -> Content
    ) -> some View {
        if stacks {
            VStack(alignment: .leading, spacing: 8) { content() }
        } else {
            HStack(alignment: alignment, spacing: 8) { content() }
        }
    }

    /// The 32 pt circle, a 44 pt target (the extra taken back by negative padding).
    private func sendButton(theme: Theme, ink: Color, stacks: Bool) -> some View {
        let outset = (Self.minimumTarget - Self.sendDrawnSide) / 2
        return Button { controller.send() } label: {
            Image(systemName: "arrow.up")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color(uiColor: theme.backgroundColor))
                .frame(width: Self.sendDrawnSide, height: Self.sendDrawnSide)
                .background(Circle().fill(ink.opacity(controller.canSendNow ? 1 : 0.25)))
                .padding(outset)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!controller.canSendNow)
        .padding(stacks ? 0 : -outset)
        .accessibilityLabel(SelectionToolbarPresentation.sendTitle)
        .accessibilityShowsLargeContentViewer {
            Image(systemName: "arrow.up")
            Text(SelectionToolbarPresentation.sendTitle)
        }
    }

    private func actionMenu(inks: PhoneInk, stacks: Bool) -> some View {
        let groups = actionGroups
        return Menu {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                Section {
                    ForEach(group, id: \.self) { action in
                        Button {
                            model.action = action
                        } label: {
                            if action == model.action {
                                Label(SelectionToolbarPresentation.menuTitle(for: action), systemImage: "checkmark")
                            } else {
                                Text(SelectionToolbarPresentation.menuTitle(for: action))
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(SelectionToolbarPresentation.actionLabel)
                    .foregroundStyle(inks.secondary)
                Text(SelectionToolbarPresentation.menuTitle(for: model.action))
                    .fixedSize(horizontal: false, vertical: stacks)
                Image(systemName: "chevron.down")
                    .font(.system(size: chevronSize, weight: .semibold))
                    // A non-text mark: ink at 0.6 is 4.2:1 or more on every theme (3:1 needed).
                    .opacity(0.6)
            }
            .font(.subheadline)
            .padding(.vertical, Self.textTargetOutset)
            .contentShape(Rectangle())
        }
        .padding(.vertical, stacks ? 0 : -Self.textTargetOutset)
        // One stop, "Action, Custom", never the chevron's symbol name.
        .accessibilityLabel(SelectionToolbarPresentation.actionLabel)
        .accessibilityValue(SelectionToolbarPresentation.menuTitle(for: model.action))
    }

    /// Custom, then the same actions with the same rules as the Mac (one word: Another Word; Find
    /// only for two or more sentences).
    private var actionGroups: [[AIAction]] {
        guard let editor = controller.editor, let range = controller.anchorRange else { return [[.custom]] }
        let text = editor.textStorage.string
        let ns = text as NSString
        let selected = ns.substring(with: NSIntersectionRange(range, NSRange(location: 0, length: ns.length)))
        return SelectionToolbarPresentation.actionGroups(
            selectedText: selected,
            sentenceCount: { AISentenceSplitter.sentences(in: text, selection: range).count }
        )
    }
}

/// The note: a plain `UITextView`, so Return inserts a newline, marked text is visible to Send,
/// and it grows with what is typed (up to five lines, then scrolls). Not a subclass.
struct CommentNoteView: UIViewRepresentable {
    @ObservedObject var controller: SelectionController
    var profile: ReadingProfile

    /// About five body lines at the default text size. It scales with the text, up to twice
    /// this, so the field still clears the keyboard at the largest sizes.
    static let maximumHeight: CGFloat = 120
    static let minimumHeight: CGFloat = 40
    static let maximumHeightScale: CGFloat = 2

    /// `maximumHeight` for `traits`' text size.
    static func maximumHeight(for traits: UITraitCollection) -> CGFloat {
        let scaled = UIFontMetrics(forTextStyle: .body).scaledValue(for: maximumHeight, compatibleWith: traits)
        return min(scaled, maximumHeight * maximumHeightScale)
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        view.returnKeyType = .default
        view.delegate = context.coordinator
        view.text = controller.model.note
        view.accessibilityLabel = SelectionToolbarPresentation.notePlaceholder
        controller.noteMarkedText = { [weak view] in view?.markedTextRange != nil }
        context.coordinator.focusToken = controller.model.focusToken
        DispatchQueue.main.async { [weak view] in view.map { Self.focus($0) } }
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let theme = Theme.theme(for: profile)
        view.textColor = theme.textColor
        view.tintColor = theme.caretColor
        view.keyboardAppearance = theme.usesDarkChrome ? .dark : .default
        // Never rewrite the text while an input method is composing.
        if view.markedTextRange == nil, view.text != controller.model.note {
            view.text = controller.model.note
        }
        if context.coordinator.focusToken != controller.model.focusToken {
            context.coordinator.focusToken = controller.model.focusToken
            DispatchQueue.main.async { [weak view] in view.map { Self.focus($0) } }
        }
    }

    /// Puts the caret in the note, and VoiceOver's focus with it: the field just replaced the
    /// row the writer was on.
    static func focus(
        _ view: UITextView,
        isVoiceOverRunning: Bool = UIAccessibility.isVoiceOverRunning,
        post: @MainActor (UIAccessibility.Notification, Any?) -> Void = { UIAccessibility.post(notification: $0, argument: $1) }
    ) {
        view.becomeFirstResponder()
        if isVoiceOverRunning { post(.layoutChanged, view) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 300
        let fitting = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let maximum = Self.maximumHeight(for: uiView.traitCollection)
        uiView.isScrollEnabled = fitting.height > maximum
        return CGSize(width: width, height: min(max(fitting.height, Self.minimumHeight), maximum))
    }

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        let controller: SelectionController
        var focusToken = 0

        init(controller: SelectionController) { self.controller = controller }

        func textViewDidChange(_ textView: UITextView) {
            controller.noteDidChange(textView.text, composing: textView.markedTextRange != nil)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            // Marked text starting or ending shows up here too.
            controller.noteDidChange(textView.text, composing: textView.markedTextRange != nil)
        }
    }
}
