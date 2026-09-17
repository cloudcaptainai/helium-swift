import UIKit
import WebKit

/// Hosts the checkout URL in a `WKWebView` the app owns.
///
/// Unlike the Safari styles, the redirect never leaves the app: a custom scheme cannot load
/// here, so it is caught during navigation and handed to `Helium.handleURL` — the same entry
/// point the host app forwards to — keeping every browser style on one completion path.
@MainActor
final class WebCheckoutWebViewController: WebCheckoutBrowserViewController, WKNavigationDelegate, WKUIDelegate {

    private let url: URL
    private let webView = WKWebView(frame: .zero)
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private var hasRenderedSomething = false

    /// A load that beats this shows no spinner at all, rather than one that appears and
    /// vanishes too fast to mean anything.
    private static let spinnerDelay: TimeInterval = 0.25

    init(url: URL, onDismiss: @escaping @MainActor (WebCheckoutBrowserDismissal) -> Void) {
        self.url = url
        super.init(onDismiss: onDismiss)
        modalPresentationStyle = .fullScreen
    }

    /// No chrome of our own: the page fills the screen exactly as the paywall beneath it
    /// does, and owns its own way out — closing is a cancel redirect like any other.
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        webView.navigationDelegate = self
        webView.uiDelegate = self
        // Painted before the first load so the wait for the first byte shows this rather
        // than the web view's white default.
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.scrollView.backgroundColor = .systemBackground
        // Edge to edge, as the paywall renders: the page handles its own safe areas.
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.contentInset = .zero

        activityIndicator.hidesWhenStopped = true

        for subview in [webView, activityIndicator] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        webView.load(URLRequest(url: url))
        showSpinnerIfStillLoading()
    }

    private func showSpinnerIfStillLoading() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.spinnerDelay * 1_000_000_000))
            guard let self, !hasRenderedSomething else { return }
            activityIndicator.startAnimating()
        }
    }

    // MARK: - WKNavigationDelegate

    /// Only Helium's own redirect is intercepted. Checkout legitimately navigates off-site
    /// for 3DS and bank challenges, and blocking those would strand the purchase.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard let requested = navigationAction.request.url,
              WebCheckoutRedirect.classify(requested) != nil else {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        _ = Helium.shared.handleURL(requested)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        hasRenderedSomething = true
        activityIndicator.stopAnimating()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        activityIndicator.stopAnimating()
        closeIfNothingEverRendered()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        activityIndicator.stopAnimating()
        closeIfNothingEverRendered()
    }

    /// Without chrome the page is the only way out, so a first load that never renders would
    /// leave the user stuck behind a blank screen with nothing to tap. Closing returns them
    /// to the paywall, where they would have been had checkout never opened.
    ///
    /// Only the first load counts: a later navigation failing is the checkout's own problem
    /// to show, and tearing the whole flow down mid-purchase would be worse.
    private func closeIfNothingEverRendered() {
        guard !hasRenderedSomething else { return }
        HeliumLogger.log(.debug, category: .entitlements, "In-app web view checkout failed to load — closing")
        dismissAfterFailingToLoad()
    }

    // MARK: - WKUIDelegate

    /// A `WKWebView` drops `target="_blank"` and `window.open` unless this is implemented,
    /// with no error of any kind — the tap simply does nothing. Loading it in place keeps
    /// the original request rather than rebuilding one from its URL, which would lose the
    /// method and body a form post carries.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            HeliumLogger.log(.debug, category: .entitlements, "In-app web view checkout opened a popup in place", metadata: [
                "host": navigationAction.request.url?.host ?? "unknown"
            ])
            webView.load(navigationAction.request)
        }
        return nil
    }
}
