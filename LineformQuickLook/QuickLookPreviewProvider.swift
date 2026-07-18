import AppKit
import QuickLookUI

@MainActor
@preconcurrency
class PreviewViewController: NSViewController, QLPreviewingController {
    private var textView: NSTextView!

    override func loadView() {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false

        textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .textColor
        textView.font = NSFont.systemFont(ofSize: 17)
        textView.textContainerInset = NSSize(width: 40, height: 40)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0

        scrollView.documentView = textView
        self.view = scrollView
    }

    nonisolated func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping @Sendable (Error?) -> Void) {
        Task { @MainActor in
            do {
                let markdown = try Self.readText(at: url)
                let attributedString = QuickLookMarkdownRenderer.render(markdown)
                textView.textStorage?.setAttributedString(attributedString)
                handler(nil)
            } catch {
                handler(error)
            }
        }
    }

    /// Reads a Markdown/text file, tolerating non-UTF-8 encodings. UTF-8 is the app's
    /// canonical format and by far the common case, so it is tried first; a file saved in
    /// another editor with a legacy encoding falls back to a sniffed encoding, then Latin-1
    /// (which never fails) so Quick Look shows a preview instead of an error.
    private nonisolated static func readText(at url: URL) throws -> String {
        if let utf8 = try? String(contentsOf: url, encoding: .utf8) {
            return utf8
        }
        var sniffed: String.Encoding = .utf8
        if let detected = try? String(contentsOf: url, usedEncoding: &sniffed) {
            return detected
        }
        return try String(contentsOf: url, encoding: .isoLatin1)
    }
}

// QuickLookMarkdownRenderer moved to QuickLookMarkdownRenderer.swift (AppKit-only, so it also
// compiles into LineformTests). This file keeps the QuickLookUI-dependent view controller.
