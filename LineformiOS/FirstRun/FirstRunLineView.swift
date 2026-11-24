import SwiftUI
import WebKit

/// First run's wordmark: the Mac's write-on animation and glass shader, loaded from the bundled
/// `FirstLaunchIntro/` folder (the Mac's own files, referenced by the iPhone target, never copied
/// or changed). Everything iPhone-only goes in through `pageAdjustmentScript` at document end, so
/// the Mac's intro renders exactly as before. It only shows: taps belong to the overlay, VoiceOver
/// skips it (the overlay carries its label), and it never reaches the network.
///
/// `onWritten` runs once, when the page has finished writing the wordmark. `isQuiet` (the points
/// screen) calms the shader's colour.
struct FirstRunLineView: UIViewRepresentable {
    var isQuiet = false
    var onWritten: () -> Void = {}

    /// The script message the page posts when the wordmark is written.
    static let messageName = "lineformFirstRun"
    static let writtenMessage = "written"
    static let contentRuleListIdentifier = "LineformFirstRunLocalOnly"
    /// The page's call that quietens the shader (defined by `pageAdjustmentScript`).
    static let quietScript = "window.lineformQuiet&&window.lineformQuiet();"
    /// How much stronger the shader's colour field draws on the welcome (the Mac's is 1).
    static let colorBoost = 1.8
    /// The colour field's strength once the points are up: back to about the Mac's.
    static let quietColorBoost = 1.2

    func makeCoordinator() -> Coordinator { Coordinator(onWritten: onWritten) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(source: Self.pageAdjustmentScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        // The content controller retains its handlers: a weak proxy keeps it from retaining the
        // coordinator, and `dismantleUIView` removes it.
        controller.add(WeakScriptMessageProxy(target: context.coordinator), name: Self.messageName)

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
        let coordinator = context.coordinator
        coordinator.onWritten = onWritten
        coordinator.webView = webView
        coordinator.setQuiet(isQuiet)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: messageName)
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

    /// Runs at document end, after the intro's own script has started (it is the last thing in
    /// `<body>`), and adapts the page for the phone without touching the Mac's files:
    /// - a transparent page over first run's paper; the page's own tagline, Get Started and
    ///   tuning panel hidden (the overlay draws the native ones);
    /// - the wordmark centred both ways (the Mac lifts it 5–7 % of the height) at 78 % width;
    /// - the write-on slowed to `FirstRunTiming.writeSeconds` through the intro's own `writeTime`
    ///   control (its range stops at 1.6 s, so the range is widened first), with the clean
    ///   wordmark's crossfade moved to the end of the slower write;
    /// - stronger colour: the shader's colour field drawn `colorBoost` times as strong through
    ///   `window.lineformIntroColorBoost` (the intro reads it every frame and treats a missing
    ///   value as 1, so the Mac is unchanged; it keeps the letters themselves at the Mac's
    ///   strength); `lineformQuiet()` eases it to `quietColorBoost` over
    ///   `FirstRunTiming.shrinkSeconds` for the points;
    /// - one "written" message when the intro marks itself complete.
    static let pageAdjustmentScript: String = {
        let write = FirstRunTiming.writeSeconds
        let quietMilliseconds = Int(FirstRunTiming.shrinkSeconds * 1000)
        let liftVH = Int((FirstRunLayout.welcomeLiftFraction * 100).rounded())
        return """
        (function () {
          var style = document.createElement('style');
          style.textContent = [
            'html, body { background: transparent !important; }',
            '.intro-shell { min-height: 0 !important; -webkit-backdrop-filter: none !important; backdrop-filter: none !important; }',
            '.wordmark-stage { padding: 0 !important; }',
            '.wordmark-wrap { width: 78vw !important; transform: translate3d(0, -\(liftVH)vh, 0) !important; }',
            '.intro-tagline, .start-button, .tuning-panel { display: none !important; }'
          ].join('\\n');
          document.head.appendChild(style);
          function setControl(id, max, value) {
            var control = document.getElementById(id);
            if (!control) { return; }
            control.max = String(max);
            control.value = String(value);
          }
          setControl('writeTime', 6, \(write));
          setControl('finalDelay', 6, \(write + 0.1));
          setControl('finalFade', 1, 0.6);
          window.lineformIntroColorBoost = \(colorBoost);
          window.lineformQuiet = function () {
            var from = window.lineformIntroColorBoost, to = \(quietColorBoost), start = null;
            function step(now) {
              if (start === null) { start = now; }
              var t = Math.min(1, (now - start) / \(quietMilliseconds));
              var eased = t < 0.5 ? 2 * t * t : 1 - Math.pow(-2 * t + 2, 2) / 2;
              window.lineformIntroColorBoost = from + (to - from) * eased;
              if (t < 1) { requestAnimationFrame(step); }
            }
            requestAnimationFrame(step);
          };
          var shell = document.querySelector('.intro-shell');
          var sent = false;
          function check() {
            if (sent || !shell || !shell.classList.contains('is-complete')) { return; }
            sent = true;
            try { window.webkit.messageHandlers.\(messageName).postMessage('\(writtenMessage)'); } catch (e) {}
          }
          if (shell) { new MutationObserver(check).observe(shell, { attributes: true, attributeFilter: ['class'] }); }
          check();
        })();
        """
    }()

    /// Allows the bundled file pages only; every other navigation is cancelled, never opened.
    /// Forwards the page's "written" signal, once, and quietens the page once.
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var onWritten: () -> Void
        weak var webView: WKWebView?
        private var hasSignalledWritten = false
        private var wantsQuiet = false
        private var hasLoaded = false
        private var hasQuietened = false

        init(onWritten: @escaping () -> Void) {
            self.onWritten = onWritten
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            decisionHandler(Self.allows(navigationAction.request.url) ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            hasLoaded = true
            applyQuietIfNeeded()
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == FirstRunLineView.messageName,
                  message.body as? String == FirstRunLineView.writtenMessage,
                  !hasSignalledWritten else { return }
            hasSignalledWritten = true
            onWritten()
        }

        func setQuiet(_ quiet: Bool) {
            guard quiet else { return }
            wantsQuiet = true
            applyQuietIfNeeded()
        }

        private func applyQuietIfNeeded() {
            guard wantsQuiet, hasLoaded, !hasQuietened, let webView else { return }
            hasQuietened = true
            webView.evaluateJavaScript(FirstRunLineView.quietScript, completionHandler: nil)
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
