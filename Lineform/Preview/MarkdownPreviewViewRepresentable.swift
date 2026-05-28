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

        let textView = MarkdownPreviewTextView()
        textView.setAccessibilityLabel("Markdown read view")
        textView.setAccessibilityRole(.textArea)

        scrollView.documentView = textView
        textView.apply(text: text, profile: profile)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? MarkdownPreviewTextView else {
            return
        }

        textView.apply(text: text, profile: profile)
    }
}

final class MarkdownPreviewTextView: NSTextView {
    private var activeProfile = ReadingProfile.original
    private var renderedText: String?
    private var renderedProfile: ReadingProfile?

    convenience init() {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        self.init(frame: .zero, textContainer: textContainer)
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateTextContainerLayout()
    }

    func apply(text: String, profile: ReadingProfile) {
        activeProfile = profile
        let theme = Theme.theme(for: profile)
        backgroundColor = theme.backgroundColor
        textColor = theme.textColor
        updateTextContainerLayout()

        guard text != renderedText || profile != renderedProfile else {
            return
        }

        textStorage?.setAttributedString(MarkdownPreviewRenderer().render(text, profile: profile))
        renderedText = text
        renderedProfile = profile
    }

    private func configure() {
        isEditable = false
        isSelectable = true
        isRichText = false
        drawsBackground = true
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        minSize = NSSize(width: 0, height: 0)
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textContainer?.widthTracksTextView = true
        textContainer?.containerSize = NSSize(width: bounds.width, height: CGFloat.greatestFiniteMagnitude)
        updateTextContainerLayout()
    }

    private func updateTextContainerLayout() {
        let inset = NSSize(
            width: EditorReadingLayout.horizontalInset(forContainerWidth: bounds.width, profile: activeProfile),
            height: 32
        )
        if textContainerInset != inset {
            textContainerInset = inset
        }
        textContainer?.widthTracksTextView = true
    }
}
