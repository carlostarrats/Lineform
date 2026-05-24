import AppKit
import SwiftUI

struct MarkdownPreviewViewRepresentable: NSViewRepresentable {
    var text: String
    var profile: ReadingProfile

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: CGFloat(profile.marginWidth), height: 32)
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel("Markdown read view")
        textView.setAccessibilityRole(.textArea)

        scrollView.documentView = textView
        update(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else {
            return
        }

        update(textView)
    }

    private func update(_ textView: NSTextView) {
        let theme = Theme.theme(for: profile)
        textView.backgroundColor = theme.backgroundColor
        textView.textColor = theme.textColor
        let horizontalInset = max(CGFloat(profile.marginWidth), (textView.bounds.width - CGFloat(profile.columnWidth)) / 2)
        textView.textContainerInset = NSSize(width: horizontalInset, height: 32)
        textView.textStorage?.setAttributedString(MarkdownPreviewRenderer().render(text, profile: profile))
    }
}
