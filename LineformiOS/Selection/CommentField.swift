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
/// - Cancel with the button, or by swiping the field down.
struct CommentField: View {
    @ObservedObject var controller: SelectionController
    @ObservedObject private var model: SelectionToolbarModel
    var profile: ReadingProfile
    @GestureState private var dragOffset: CGFloat = 0

    /// How far down a swipe must travel to cancel.
    static let cancelDistance: CGFloat = 60

    init(controller: SelectionController, profile: ReadingProfile) {
        self.controller = controller
        _model = ObservedObject(wrappedValue: controller.model)
        self.profile = profile
    }

    var body: some View {
        let theme = Theme.theme(for: profile)
        let ink = Color(uiColor: theme.textColor)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(SelectionToolbarPresentation.commentTitle(aiName: model.aiName ?? SelectionToolbarPresentation.aiName(for: .other)))
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Button(String(localized: "Cancel")) { controller.cancelComment() }
                    .font(.subheadline)
            }
            ZStack(alignment: .topLeading) {
                CommentNoteView(controller: controller, profile: profile)
                if model.note.isEmpty {
                    Text(SelectionToolbarPresentation.notePlaceholder)
                        .font(.body)
                        .opacity(0.4)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(ink.opacity(0.06)))
            HStack(spacing: 8) {
                actionMenu
                Spacer(minLength: 8)
                Button { controller.send() } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color(uiColor: theme.backgroundColor))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(ink.opacity(controller.canSendNow ? 1 : 0.25)))
                }
                .buttonStyle(.plain)
                .disabled(!controller.canSendNow)
                .accessibilityLabel(SelectionToolbarPresentation.sendTitle)
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
        .accessibilityIdentifier("selection.comment")
    }

    private var actionMenu: some View {
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
                    .opacity(0.6)
                Text(SelectionToolbarPresentation.menuTitle(for: model.action))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .opacity(0.6)
            }
            .font(.subheadline)
        }
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

    static let maximumHeight: CGFloat = 120

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
        DispatchQueue.main.async { [weak view] in view?.becomeFirstResponder() }
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
            DispatchQueue.main.async { [weak view] in view?.becomeFirstResponder() }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 300
        let fitting = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        uiView.isScrollEnabled = fitting.height > Self.maximumHeight
        return CGSize(width: width, height: min(max(fitting.height, 40), Self.maximumHeight))
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
