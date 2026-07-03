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

final class MarkdownPreviewTextView: NSTextView, NSTextViewDelegate {
    private var activeProfile = ReadingProfile.original
    private var renderedText: String?
    private var renderedProfile: ReadingProfile?
    private let mermaidProvider = MermaidImageProvider()
    private let mathProvider = MathImageProvider()
    private let diagramLog = DiagramLogStore()
    private let reportRegistry = DiagramReportRegistry()
    private let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"

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

        textStorage?.setAttributedString(
            MarkdownPreviewRenderer().render(
                text,
                profile: profile,
                columnWidth: EditorReadingLayout.textColumnMaxWidth(for: profile),
                mermaidProvider: mermaidProvider,
                mathProvider: mathProvider,
                diagramLog: diagramLog,
                reportRegistry: reportRegistry,
                appVersion: appVersion
            )
        )
        renderedText = text
        renderedProfile = profile
    }

    // MARK: - "Report this" link handling

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url: URL?
        if let asURL = link as? URL { url = asURL }
        else if let asString = link as? String { url = URL(string: asString) }
        else { url = nil }
        guard let url, let hash = DiagramReportLink.hash(from: url),
              let pending = reportRegistry.report(for: hash) else {
            return false
        }
        presentReportDialog(source: pending.source, error: pending.error)
        return true
    }

    private func presentReportDialog(source: String, error: String) {
        let alert = NSAlert()
        alert.messageText = "Report rendering issue?"
        alert.informativeText = "The diagram text and error will be sent to the developer to improve rendering."
        alert.addButton(withTitle: "Report")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let version = appVersion
        Task { @MainActor in
            let result = await DiagramReportService.send(source: source, error: error, appVersion: version)
            let done = NSAlert()
            switch result {
            case .sent:
                done.messageText = "Thanks — sent."
            case .failed:
                done.messageText = "Couldn’t send. Saved locally."
                done.informativeText = "The diagram is still recorded in your local diagram log."
            }
            done.addButton(withTitle: "OK")
            done.runModal()
        }
    }

    private func configure() {
        isEditable = false
        isSelectable = true
        delegate = self
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
