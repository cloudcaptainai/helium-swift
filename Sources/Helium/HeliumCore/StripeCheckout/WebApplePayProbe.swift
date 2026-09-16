import Foundation
import WebKit

/// Whether Apple Pay can be paid with in the browser, as opposed to whether the device
/// supports Apple Pay at all. `unknown` means no probe has answered yet.
enum WebApplePayReadiness: String {
    case ready
    case notReady
    case unknown
}

/// Runs Apple Pay's web API inside an app-owned, offscreen `WKWebView` on the same https
/// origin the external checkout page is served from.
///
/// `canMakePaymentsWithActiveCard` is the only signal that reflects whether the Wallet
/// holds a card usable at that origin's merchant; `canMakePayments` is true on any
/// Apple Pay capable device, including devices with an empty Wallet. Apple Pay rejects
/// insecure documents, so the probe needs an https origin: `loadHTMLString(_:baseURL:)`
/// gives the document that origin without anything being hosted or fetched.
@MainActor
final class WebApplePayProbe: NSObject, WKScriptMessageHandler, WKNavigationDelegate {

    struct Outcome {
        let readiness: WebApplePayReadiness
        let durationMs: Int
        let timedOut: Bool
        /// Set when Apple Pay's web API is unreachable or rejected the merchant.
        let failureReason: String?
    }

    private static let messageName = "heliumApplePayProbe"

    private let origin: URL
    private let timeout: TimeInterval
    private var startedAt = Date()

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var resolvedOutcome: Outcome?

    init(origin: URL, timeout: TimeInterval = 2) {
        self.origin = origin
        self.timeout = timeout
    }

    func run() async -> Outcome {
        if let resolvedOutcome { return resolvedOutcome }
        startedAt = Date()
        let controller = WKUserContentController()
        controller.add(self, name: Self.messageName)

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        webView.navigationDelegate = self
        webView.isHidden = true
        self.webView = webView

        return await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            self.continuation = continuation
            webView.loadHTMLString(Self.probeHTML, baseURL: origin)

            Task { [weak self, timeout] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.finish(readiness: .unknown, timedOut: true, failureReason: "timeout")
            }
        }
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == Self.messageName else { return }
        let result = Self.result(for: message.body as? [String: Any] ?? [:])
        finish(readiness: result.readiness, failureReason: result.failureReason)
    }

    /// Anything other than a boolean `activeCard` is an absent measurement, never a
    /// negative one, so a page that fails to answer cannot route a user away from
    /// web checkout.
    nonisolated static func result(
        for payload: [String: Any]
    ) -> (readiness: WebApplePayReadiness, failureReason: String?) {
        if let activeCard = payload["activeCard"] as? Bool {
            return (activeCard ? .ready : .notReady, nil)
        }
        return (.unknown, payload["error"] as? String ?? "malformedResult")
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(readiness: .unknown, failureReason: "didFail: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(readiness: .unknown, failureReason: "didFailProvisional: \(error.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(readiness: .unknown, failureReason: "webContentProcessTerminated")
    }

    // MARK: - Completion

    /// The JS result, a load error, and the timeout all race to get here, so the first
    /// one to arrive is kept and every later one is dropped.
    private func finish(readiness: WebApplePayReadiness, timedOut: Bool = false, failureReason: String?) {
        guard resolvedOutcome == nil else { return }

        webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.messageName)
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil

        let outcome = Outcome(
            readiness: readiness,
            durationMs: msSince(startedAt),
            timedOut: timedOut,
            failureReason: failureReason
        )
        resolvedOutcome = outcome
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(returning: outcome)
    }

    // MARK: - HTML

    /// The merchant identifier is derived from the document host because that is the
    /// identifier the checkout page itself is served under.
    private static let probeHTML = """
    <!DOCTYPE html>
    <html><head><meta charset="utf-8"></head><body><script>
    (function(){
      var post = function(o){ try { window.webkit.messageHandlers.\(messageName).postMessage(o); } catch(e){} };
      if (!window.ApplePaySession) { post({ error: 'noApplePaySession' }); return; }
      var merchantId = 'merchant.' + window.location.hostname + '.stripe';
      try {
        Promise.resolve(window.ApplePaySession.canMakePaymentsWithActiveCard(merchantId))
          .then(function(v){ post({ activeCard: v === true }); })
          .catch(function(e){ post({ error: 'activeCardRejected: ' + String(e) }); });
      } catch (e) {
        post({ error: 'activeCardThrew: ' + String(e) });
      }
    })();
    </script></body></html>
    """
}
