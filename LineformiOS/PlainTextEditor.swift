import LineformCore
import SwiftUI
import UIKit

/// A plain-text Markdown editor: a TextKit 1 `UITextView` styled from the reading profile.
///
/// Typing uses `MarkdownTextStyle.baseAttributes(for:)`, the page and caret use the profile's
/// theme, and the text sits in a centred column `profile.columnWidth` wide, with at least
/// `minimumSideMargin` on each side (on an iPhone the margin is what limits it).
struct PlainTextEditor: UIViewRepresentable {
    @Binding var text: String
    var profile: ReadingProfile

    /// The smallest horizontal page margin, in points.
    static let minimumSideMargin: CGFloat = 20

    func makeUIView(context: Context) -> EditorTextView {
        let textView = Self.makeTextView(profile: profile)
        Self.setText(text, in: textView)
        textView.delegate = context.coordinator
        return textView
    }

    func updateUIView(_ textView: EditorTextView, context: Context) {
        context.coordinator.parent = self
        Self.apply(profile, to: textView)
        if textView.text != text {
            Self.setText(text, in: textView)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    /// A configured editor text view. Separate from `makeUIView` so tests can build one directly.
    static func makeTextView(profile: ReadingProfile) -> EditorTextView {
        let textView = EditorTextView(usingTextLayoutManager: false)
        textView.autocapitalizationType = .sentences
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.textContainer.lineFragmentPadding = 0
        textView.accessibilityLabel = String(localized: "Markdown editor")
        apply(profile, to: textView)
        return textView
    }

    static func apply(_ profile: ReadingProfile, to textView: EditorTextView) {
        guard textView.appliedProfile != profile else { return }
        textView.appliedProfile = profile
        let theme = Theme.theme(for: profile)
        let attributes = MarkdownTextStyle.baseAttributes(for: profile)
        textView.backgroundColor = theme.backgroundColor
        textView.tintColor = theme.caretColor
        textView.columnWidth = CGFloat(profile.columnWidth)
        textView.typingAttributes = attributes
        // Restyle what is already there; the editor holds plain text, so one run covers it.
        let storage = textView.textStorage
        storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
    }

    /// Replaces the whole text, styled with the current typing attributes (a bare `text =`
    /// would drop the paragraph style and kerning). The selection is kept where it was, clamped
    /// to the new text, so a live reload does not throw the caret to the end.
    static func setText(_ text: String, in textView: EditorTextView) {
        let selection = textView.selectedRange
        let attributes = textView.typingAttributes
        textView.attributedText = NSAttributedString(string: text, attributes: attributes)
        textView.typingAttributes = attributes
        let length = (text as NSString).length
        let location = min(selection.location, length)
        textView.selectedRange = NSRange(location: location, length: min(selection.length, length - location))
    }

    /// The horizontal inset that centres a `columnWidth` column in `width`, never below the
    /// minimum margin.
    static func horizontalInset(forWidth width: CGFloat, columnWidth: CGFloat) -> CGFloat {
        max(minimumSideMargin, (width - columnWidth) / 2)
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: PlainTextEditor

        init(parent: PlainTextEditor) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }
    }
}

/// The editor's text view. It recomputes its horizontal insets whenever its width changes, so
/// the reading column stays centred through rotation and resizing.
final class EditorTextView: UITextView {
    /// The profile last applied by `PlainTextEditor.apply(_:to:)`, so an unchanged profile costs
    /// nothing on a SwiftUI update.
    var appliedProfile: ReadingProfile?

    var columnWidth: CGFloat = CGFloat(ReadingProfile.original.columnWidth) {
        didSet { if columnWidth != oldValue { setNeedsLayout() } }
    }

    override func layoutSubviews() {
        let side = PlainTextEditor.horizontalInset(forWidth: bounds.width, columnWidth: columnWidth)
        let vertical = PlainTextEditor.minimumSideMargin
        let inset = UIEdgeInsets(top: vertical, left: side, bottom: vertical, right: side)
        if textContainerInset != inset {
            textContainerInset = inset
        }
        super.layoutSubviews()
    }
}
