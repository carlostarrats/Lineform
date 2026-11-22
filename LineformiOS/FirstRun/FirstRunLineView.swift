import SwiftUI
import WebKit

/// First run's opening stage: the Mac's line animation, loaded from the bundled
/// `FirstLaunchIntro/` folder (the Mac's own files, referenced by the iPhone target, never
/// copied or changed). It only shows: taps belong to the overlay, VoiceOver skips it (the overlay
/// carries its label), and it never reaches the network.
///
/// `onReady` runs once, when the page paints its first frame, so the overlay's hold starts from
/// what the writer can actually see.
struct FirstRunLineView: UIViewRepresentable {
    var onReady: () -> Void = {}

    /// The script message the page posts from its first animation frame.
    static let readyMessageName = "lineformFirstRun"
    static let contentRuleListIdentifier = "LineformFirstRunLocalOnly"

    func makeCoordinator() -> Coordinator { Coordinator(onReady: onReady) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let controller = configuration.userContentController
        if let script = Self.pageAdjustmentScript() {
            controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        controller.addUserScript(WKUserScript(source: Self.readyScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        // The content controller retains its handlers: a weak proxy keeps it from retaining the
        // coordinator, and `dismantleUIView` removes it.
        controller.add(WeakScriptMessageProxy(target: context.coordinator), name: Self.readyMessageName)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isUserInteractionEnabled = false
        webView.accessibilityElementsHidden = true
        webView.navigationDelegate = context.coordinator

        guard let page = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "FirstLaunchIntro")
        else { return webView }
        // Block every non-local load before the page loads. If the rules cannot be compiled, the
        // page still loads: the navigation policy still refuses anything that is not a file.
        Task { @MainActor [weak webView] in
            if let rules = try? await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: Self.contentRuleListIdentifier,
                encodedContentRuleList: Self.localOnlyContentRules
            ) {
                webView?.configuration.userContentController.add(rules)
            }
            webView?.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onReady = onReady
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: readyMessageName)
    }

    /// Content rules: block every load, then let `file:` (the bundled page) and `data:` (the
    /// intro's inline logo texture, never a network load) through.
    static let localOnlyContentRules = """
    [
      {"trigger": {"url-filter": ".*"}, "action": {"type": "block"}},
      {"trigger": {"url-filter": "^file:"}, "action": {"type": "ignore-previous-rules"}},
      {"trigger": {"url-filter": "^data:"}, "action": {"type": "ignore-previous-rules"}}
    ]
    """

    /// Posts "ready" from the page's first animation frame.
    static let readyScript = """
    (function () {
      requestAnimationFrame(function () {
        try { window.webkit.messageHandlers.\(readyMessageName).postMessage("ready"); } catch (e) {}
      });
    })();
    """

    /// Runs at document end: puts the localized tagline in place of the page's English, and
    /// draws the page over paper rather than the Mac's dimmed desktop (a transparent page, the
    /// tagline in dark ink instead of white, and kept inside the phone's width: the Mac's
    /// one-line tagline starts at 54% and ran off the right edge). The tagline goes in as a JSON
    /// string literal, so quotes, backslashes, line breaks and `</script>` cannot break out. Nil
    /// when it cannot be encoded; then nothing is injected.
    static func pageAdjustmentScript(tagline: String = String(localized: "Simple markdown editing")) -> String? {
        guard let encoded = javaScriptStringLiteral(tagline) else { return nil }
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

    /// `text` as a JavaScript string literal: JSON, which also escapes `/`, so `</script>` never
    /// appears. Nil if it cannot be encoded.
    static func javaScriptStringLiteral(_ text: String) -> String? {
        guard let data = try? JSONEncoder().encode(text) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Allows the bundled file pages only; every other navigation is cancelled, never opened.
    /// Forwards the page's first-frame signal, once.
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var onReady: () -> Void
        private var hasSignalledReady = false

        init(onReady: @escaping () -> Void) {
            self.onReady = onReady
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            decisionHandler(Self.allows(navigationAction.request.url) ? .allow : .cancel)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == FirstRunLineView.readyMessageName, message.body as? String == "ready",
                  !hasSignalledReady else { return }
            hasSignalledReady = true
            onReady()
        }

        static func allows(_ url: URL?) -> Bool {
            url?.isFileURL ?? false
        }
    }
}

/// Forwards script messages to a handler it does not retain.
private final class WeakScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
