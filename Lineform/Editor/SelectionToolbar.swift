import AppKit
import SwiftUI
import LineformCore

/// The floating toolbar over a text selection in the editor (2026-11-17), and the comment card it
/// turns into: one-click formatting, plus — only while an AI is connected — a comment to that AI.
///
/// It is a subview of the text view, so it scrolls with the text it belongs to. It appears when a
/// selection SETTLES (never mid-drag) and leaves when the selection collapses; selecting is not
/// typing, so it can never interrupt writing. Right-click and the Format menu are unchanged — the
/// toolbar adds a shortcut, it replaces nothing, and every command here also lives there (the
/// keyboard and VoiceOver route).
///
/// The comment card sends the writer's note with an optional action (`AIAction`); `.custom` means
/// "only the note". The result is the ordinary AI review: nothing changes until accepted.
///
/// The pure decisions and the model (`SelectionToolbarPresentation`, `SelectionToolbarModel`,
/// `SelectionToolbarMenu`) live in LineformCore, shared with the iPhone's selection row; the
/// views below stay here.

// MARK: - Views

struct SelectionToolbarRoot: View {
    @ObservedObject var model: SelectionToolbarModel

    var body: some View {
        Group {
            switch model.mode {
            case .toolbar: SelectionFormattingBar(model: model)
            case .comment: SelectionCommentCard(model: model)
            }
        }
        // Drag the card out of the way by any part that is not a control. The pointer is read in
        // screen space by the text view, so the moving view never feeds back into the drag.
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { model.onDrag($0.translation, false) }
                .onEnded { model.onDrag($0.translation, true) }
        )
        .environment(\.colorScheme, model.usesDarkChrome ? .dark : .light)
        .background(
            RoundedRectangle(cornerRadius: LineformDesign.Radius.floatingCard, style: .continuous)
                .fill(model.usesDarkChrome ? Color(white: 0.17) : Color(white: 0.99))
        )
        .overlay(
            RoundedRectangle(cornerRadius: LineformDesign.Radius.floatingCard, style: .continuous)
                .strokeBorder(model.usesDarkChrome ? Color.white.opacity(0.12) : Color.black.opacity(0.08))
        )
        .clipShape(RoundedRectangle(cornerRadius: LineformDesign.Radius.floatingCard, style: .continuous))
        // Room for the shadow inside the hosting view's bounds.
        .shadow(color: .black.opacity(model.usesDarkChrome ? 0.45 : 0.16), radius: 12, y: 4)
        .padding(SelectionToolbarHostingView.shadowInset)
        .fixedSize()
        // Pinned to the top: while the card grows (a note wrapping onto another line) the hosting
        // view's frame catches up one pass later, and centred content would spill both ways.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // The hosting view's own (flipped) coordinates: menus anchor to button frames read here.
        .coordinateSpace(name: SelectionToolbarHostingView.coordinateSpaceName)
    }
}

private struct SelectionFormattingBar: View {
    @ObservedObject var model: SelectionToolbarModel

    var body: some View {
        HStack(spacing: 2) {
            if let aiName = model.aiName {
                ToolbarIconButton(label: SelectionToolbarPresentation.commentTitle(aiName: aiName),
                                  tint: .accentColor) {
                    Image(systemName: "text.bubble")
                } action: { model.onOpenComment() }
                if model.showsFormatting { ToolbarDivider() }
            }
            if model.showsFormatting {
                ToolbarIconButton(label: SelectionToolbarPresentation.headingTitle, showsChevron: true) {
                    Text(verbatim: "H").font(.system(size: 13, weight: .semibold))
                } action: { model.onMenu(.heading) }
                .background(FrameReader { model.headingButtonFrame = $0 })
                ToolbarDivider()
                ToolbarIconButton(label: String(localized: "Bold")) {
                    Image(systemName: "bold")
                } action: { model.onCommand(#selector(LineformTextView.toggleBoldMarkdown(_:))) }
                ToolbarIconButton(label: String(localized: "Italic")) {
                    Image(systemName: "italic")
                } action: { model.onCommand(#selector(LineformTextView.toggleItalicMarkdown(_:))) }
                ToolbarIconButton(label: String(localized: "Strikethrough")) {
                    Image(systemName: "strikethrough")
                } action: { model.onCommand(#selector(LineformTextView.toggleStrikethroughMarkdown(_:))) }
                ToolbarIconButton(label: String(localized: "Code")) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                } action: { model.onCommand(#selector(LineformTextView.toggleInlineCodeMarkdown(_:))) }
                ToolbarDivider()
                ToolbarIconButton(label: SelectionToolbarPresentation.listTitle, showsChevron: true) {
                    Image(systemName: "list.bullet")
                } action: { model.onMenu(.list) }
                .background(FrameReader { model.listButtonFrame = $0 })
                ToolbarDivider()
                ToolbarIconButton(label: String(localized: "Link")) {
                    Image(systemName: "link")
                } action: { model.onCommand(#selector(LineformTextView.toggleLinkMarkdown(_:))) }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(CursorRectView(cursor: .arrow))
    }
}

private struct SelectionCommentCard: View {
    @ObservedObject var model: SelectionToolbarModel

    /// Small and quiet (2026-11-17): at the note's own size it out-weighed the note.
    private static let chipFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    private static let chipHorizontalPadding: CGFloat = 5
    private static let chipGap: CGFloat = 6

    /// The note's first line starts after the chip; wrapped lines run back to the card's left
    /// edge, under the chip (a first-line indent), so no column of empty space is left beside them.
    private var firstLineIndent: CGFloat {
        guard let aiName = model.aiName else { return 0 }
        let width = (aiName as NSString).size(withAttributes: [.font: Self.chipFont]).width
        return ceil(width) + Self.chipHorizontalPadding * 2 + Self.chipGap
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .topLeading) {
                SelectionNoteTextView(
                    text: $model.note,
                    placeholder: SelectionToolbarPresentation.notePlaceholder,
                    accessibilityLabel: model.aiName.map { SelectionToolbarPresentation.commentTitle(aiName: $0) }
                        ?? SelectionToolbarPresentation.notePlaceholder,
                    firstLineIndent: firstLineIndent,
                    usesDarkChrome: model.usesDarkChrome,
                    focusToken: model.focusToken,
                    onSubmit: { if model.canSend { model.onSend() } },
                    onCancel: { model.onClose() }
                )
                // Fully clear of the drag grip's 26 pt corner (card padding 12 + 14), so the note's
                // I-beam never overlaps the grip's open hand.
                .padding(.trailing, 14)
                if let aiName = model.aiName {
                    Text(aiName)
                        .font(Font(Self.chipFont))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, Self.chipHorizontalPadding)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.accentColor.opacity(model.usesDarkChrome ? 0.14 : 0.08)))
                        .background(CursorRectView(cursor: .arrow))
                        // Centred on the note's first line (16 pt tall at 13 pt).
                        .offset(y: 1)
                        .accessibilityHidden(true)
                }
            }
            HStack(spacing: 8) {
                ActionPickerButton(model: model)
                    // The chosen action is never truncated; the hint gives way instead.
                    .fixedSize()
                    .background(FrameReader { model.actionButtonFrame = $0 })
                Spacer(minLength: 12)
                Text(SelectionToolbarPresentation.sendHint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                SendButton(enabled: model.canSend) { model.onSend() }
            }
            .background(CursorRectView(cursor: .arrow))
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(width: 420)
        // Says the card can be moved; dragging works from any part that is not a control.
        .overlay(alignment: .topTrailing) {
            DragGrip()
        }
        .onExitCommand { model.onClose() }
    }
}

/// The comment card's note: a plain `NSTextView`, because SwiftUI's `TextField` cannot indent only
/// its first line. It wraps and grows (the card follows through `onSizeChange`) up to
/// `maxLines`, then scrolls. Return sends; ⌥Return or ⇧Return adds a line; Esc closes. Keys are
/// taken in `doCommand(by:)`, never `keyDown`, so input-method composition keeps its Return.
private struct SelectionNoteTextView: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let accessibilityLabel: String
    let firstLineIndent: CGFloat
    /// AppKit ink (label, placeholder, caret) resolves against the VIEW's appearance, not SwiftUI's
    /// colour scheme: pinned to the card's, like `FloatingCardChrome` pins its controls.
    let usesDarkChrome: Bool
    let focusToken: Int
    let onSubmit: () -> Void
    let onCancel: () -> Void

    static let font = NSFont.systemFont(ofSize: 13)
    static let maxLines = 10

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SelectionNoteTextView
        var lastFocusToken = -1
        init(_ parent: SelectionNoteTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NoteTextView else { return }
            // A new line inherits the indent of the one it split from; only the first may keep it.
            SelectionNoteTextView.applyIndent(textView.firstLineIndent, to: textView)
            parent.text = textView.string
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NoteTextView else { return }
            SelectionNoteTextView.updateTypingAttributes(of: textView)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                let flags = NSApp.currentEvent?.modifierFlags ?? []
                if flags.contains(.option) || flags.contains(.shift) {
                    textView.insertText("\n", replacementRange: textView.selectedRange())
                } else {
                    parent.onSubmit()
                }
                return true
            case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                textView.insertText("\n", replacementRange: textView.selectedRange())
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }

    final class NoteTextView: NSTextView {
        // Kept internal: the coordinator reads the indent.
        var placeholder = ""
        var firstLineIndent: CGFloat = 0

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard string.isEmpty else { return }
            let attributes: [NSAttributedString.Key: Any] = [.font: SelectionNoteTextView.font,
                                                             .foregroundColor: NSColor.placeholderTextColor]
            (placeholder as NSString).draw(at: NSPoint(x: textContainerOrigin.x + firstLineIndent,
                                                       y: textContainerOrigin.y), withAttributes: attributes)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NoteTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = Self.font
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.setAccessibilityLabel(accessibilityLabel)
        textView.setAccessibilityPlaceholderValue(placeholder)
        let scrollView = NSScrollView(frame: .zero)
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.verticalScrollElasticity = .none
        scrollView.documentView = textView
        scrollView.appearance = NSAppearance(named: usesDarkChrome ? .darkAqua : .aqua)
        apply(to: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NoteTextView else { return }
        if textView.string != text { textView.string = text }
        let appearance = NSAppearance(named: usesDarkChrome ? .darkAqua : .aqua)
        if scrollView.appearance?.name != appearance?.name { scrollView.appearance = appearance }
        apply(to: textView)
        scrollView.hasVerticalScroller = lineCount(textView) > Self.maxLines
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
    }

    private func apply(to textView: NoteTextView) {
        if textView.placeholder != placeholder || textView.firstLineIndent != firstLineIndent {
            textView.placeholder = placeholder
            textView.firstLineIndent = firstLineIndent
            textView.needsDisplay = true
        }
        Self.applyIndent(firstLineIndent, to: textView)
    }

    private static func paragraphStyle(indent: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = indent
        return style
    }

    /// Only the FIRST paragraph makes room for the chip; a line the writer adds with ⇧/⌥Return
    /// starts at the left edge like the wrapped lines.
    static func applyIndent(_ indent: CGFloat, to textView: NoteTextView) {
        textView.defaultParagraphStyle = paragraphStyle(indent: indent)
        if let storage = textView.textStorage, storage.length > 0 {
            let whole = NSRange(location: 0, length: storage.length)
            let first = (storage.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
            storage.beginEditing()
            storage.addAttribute(.paragraphStyle, value: paragraphStyle(indent: 0), range: whole)
            storage.addAttribute(.paragraphStyle, value: paragraphStyle(indent: indent), range: first)
            storage.endEditing()
        }
        updateTypingAttributes(of: textView)
    }

    static func updateTypingAttributes(of textView: NoteTextView) {
        let string = textView.string as NSString
        let caret = min(textView.selectedRange().location, string.length)
        let first = string.paragraphRange(for: NSRange(location: 0, length: 0))
        // At the first paragraph's end the caret is still on it — unless that paragraph ends in a
        // newline, which puts the caret at the start of the next line.
        let endsInNewline = first.length > 0 && string.character(at: NSMaxRange(first) - 1) == 0x0A
        let inFirst = caret < NSMaxRange(first) || (caret == NSMaxRange(first) && !endsInNewline)
        let style = paragraphStyle(indent: inFirst ? textView.firstLineIndent : 0)
        textView.typingAttributes = [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: style]
    }

    private static var lineHeight: CGFloat {
        NSLayoutManager().defaultLineHeight(for: font)
    }

    private func lineCount(_ textView: NSTextView) -> Int {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return 1 }
        layoutManager.ensureLayout(for: container)
        let height = layoutManager.usedRect(for: container).height
        return max(1, Int((height / Self.lineHeight).rounded()))
    }

    /// The note's height at the card's width: its laid-out text, at least one line, at most
    /// `maxLines` (then it scrolls).
    func sizeThatFits(_ proposal: ProposedViewSize, nsView scrollView: NSScrollView, context: Context) -> CGSize? {
        let width = proposal.width ?? 300
        guard let textView = scrollView.documentView as? NSTextView,
              let layoutManager = textView.layoutManager, let container = textView.textContainer else {
            return CGSize(width: width, height: Self.lineHeight)
        }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container).height
        let lines = max(1, min(CGFloat(Self.maxLines), (used / Self.lineHeight).rounded()))
        return CGSize(width: width, height: ceil(lines * Self.lineHeight))
    }
}

/// The SF Symbols drag handle (`line.3.horizontal`, Apple's "grab here" mark), small and light so
/// it hints without competing; the open hand appears over it.
private struct DragGrip: View {
    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Color.primary.opacity(0.3))
            // A generous grab target around a small mark: the corner, not just the glyph.
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
            .background(CursorRectView(cursor: .openHand))
            .help(SelectionToolbarPresentation.dragHint)
            .accessibilityHidden(true)
    }
}

private struct ToolbarIconButton<Icon: View>: View {
    let label: String
    var tint: Color = .primary
    var showsChevron = false
    @ViewBuilder let icon: () -> Icon
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                icon()
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(tint)
                if showsChevron {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 28, minHeight: 28)
            .padding(.horizontal, showsChevron ? 5 : 0)
            .background(RoundedRectangle(cornerRadius: LineformDesign.Radius.button, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct ToolbarDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1, height: 18)
            .padding(.horizontal, 4)
            .accessibilityHidden(true)
    }
}

private struct ActionPickerButton: View {
    @ObservedObject var model: SelectionToolbarModel
    @State private var hovering = false

    var body: some View {
        Button { model.onMenu(.action) } label: {
            HStack(spacing: 5) {
                Text(SelectionToolbarPresentation.actionLabel).foregroundStyle(.secondary)
                Text(SelectionToolbarPresentation.menuTitle(for: model.action)).foregroundStyle(.primary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 12))
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: LineformDesign.Radius.button, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.09 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: LineformDesign.Radius.button, style: .continuous)
                .strokeBorder(Color.primary.opacity(hovering ? 0.16 : 0.10)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(SelectionToolbarPresentation.actionLabel + " " + SelectionToolbarPresentation.menuTitle(for: model.action))
    }
}

private struct SendButton: View {
    let enabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(enabled ? Color.white : Color.secondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(fill))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .help(SelectionToolbarPresentation.sendTitle)
        .accessibilityLabel(SelectionToolbarPresentation.sendTitle)
    }

    private var fill: Color {
        guard enabled else { return Color.primary.opacity(0.08) }
        // Hover darkens the accent, like a pressed system button.
        guard hovering, let darker = NSColor.controlAccentColor.blended(withFraction: 0.18, of: .black) else {
            return Color.accentColor
        }
        return Color(nsColor: darker)
    }
}

/// Reports a view's frame in the hosting view's coordinates (SwiftUI's global space there).
private struct FrameReader: View {
    let onChange: (CGRect) -> Void
    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { onChange(proxy.frame(in: .named(SelectionToolbarHostingView.coordinateSpaceName))) }
                .onChange(of: proxy.frame(in: .named(SelectionToolbarHostingView.coordinateSpaceName))) { _, frame in onChange(frame) }
        }
    }
}

// MARK: - Hosting

final class SelectionToolbarHostingView: NSHostingView<SelectionToolbarRoot> {
    /// Transparent margin around the card so its shadow is not clipped by the view's bounds.
    static let shadowInset: CGFloat = 14
    static let coordinateSpaceName = "SelectionToolbar"

    /// Clicks on the transparent shadow margin fall through to the text underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.insetBy(dx: Self.shadowInset, dy: Self.shadowInset).contains(local) else { return nil }
        return super.hitTest(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The card's top edge, in the superview's (flipped) coordinates. When set, any frame change
    /// that is not an explicit move keeps it: NSHostingView re-sizes itself as the note wraps and
    /// shifted the origin with it, so the card grew upward AND downward. Explicit placement (show,
    /// open the comment card, drag) goes through `move(to:)`, which updates the pin first.
    var pinnedTop: CGFloat?

    func move(to frame: NSRect) {
        pinnedTop = frame.origin.y
        self.frame = frame
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        var origin = newOrigin
        if let pinnedTop { origin.y = pinnedTop }
        super.setFrameOrigin(origin)
    }

    /// The content's size changed (the note wrapped onto another line). The frame is set by hand,
    /// so the owner re-sizes it; deferred one pass so the new size can be read.
    var onSizeChange: (() -> Void)?
    private var sizeChangePending = false

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        guard onSizeChange != nil, !sizeChangePending else { return }
        sizeChangePending = true
        DispatchQueue.main.async { [weak self] in
            self?.sizeChangePending = false
            self?.onSizeChange?()
        }
    }
}
