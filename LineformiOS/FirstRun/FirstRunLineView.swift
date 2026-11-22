import SwiftUI
import WebKit

/// First run's opening stage: the Mac's line animation, loaded from the bundled
/// `FirstLaunchIntro/` folder (the Mac's own files, referenced by the iPhone target, never
/// copied or changed). It only shows: taps belong to the overlay, VoiceOver skips it (the overlay
/// carries its label), and it never reaches the network.
struct FirstRunLineView: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        if let script = Self.pageAdjustmentScript() {
            configuration.userContentController.addUserScript(
                WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
            )
        }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isUserInteractionEnabled = false
        webView.accessibilityElementsHidden = true
        webView.navigationDelegate = context.coordinator
        if let page = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "FirstLaunchIntro") {
            webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.navigationDelegate = nil
    }

    /// Runs at document end: puts the localized tagline in place of the page's English, and
    /// draws the page over paper rather than the Mac's dimmed desktop (a transparent page, the
    /// tagline in dark ink instead of white, and kept inside the phone's width: the Mac's
    /// one-line tagline starts at 54% and ran off the right edge). Nil when the tagline cannot be
    /// encoded; then nothing is injected.
    static func pageAdjustmentScript(tagline: String = String(localized: "Simple markdown editing")) -> String? {
        guard let data = try? JSONEncoder().encode(tagline),
              let encoded = String(data: data, encoding: .utf8) else { return nil }
        return """
        (function () {
          var tagline = document.querySelector('[data-l10n-id="tagline"]');
          if (tagline) { tagline.textContent = \(encoded); }
          var style = document.createElement('style');
          style.textContent = 'html, body { background: transparent !important; } '
            + '.intro-tagline { color: rgba(5, 5, 5, 0.62) !important; left: auto !important; '
            + 'right: 6vw; max-width: 88vw; white-space: normal !important; text-align: right !important; }';
          document.head.appendChild(style);
        })();
        """
    }

    /// Allows the bundled file pages only; every other navigation is cancelled, never opened.
    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            decisionHandler(Self.allows(navigationAction.request.url) ? .allow : .cancel)
        }

        static func allows(_ url: URL?) -> Bool {
            url?.isFileURL ?? false
        }
    }
}
