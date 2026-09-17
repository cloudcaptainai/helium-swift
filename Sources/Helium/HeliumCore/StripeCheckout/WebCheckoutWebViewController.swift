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

    init(url: URL, onDismiss: @escaping @MainActor () -> Void) {
        self.url = url
        super.init(onDismiss: onDismiss)
        modalPresentationStyle = .pageSheet
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let navigationBar = UINavigationBar()
        let navigationItem = UINavigationItem(title: url.host ?? "")
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: self,
            action: #selector(doneTapped)
        )
        navigationBar.setItems([navigationItem], animated: false)

        webView.navigationDelegate = self
        webView.uiDelegate = self
        // Painted before the first load so the wait for the first byte shows this rather
        // than the web view's white default.
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.scrollView.backgroundColor = .systemBackground

        activityIndicator.hidesWhenStopped = true
        activityIndicator.startAnimating()

        for subview in [navigationBar, webView, activityIndicator] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }

        NSLayoutConstraint.activate([
            navigationBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            navigationBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            navigationBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            webView.topAnchor.constraint(equalTo: navigationBar.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            activityIndicator.centerXAnchor.constraint(equalTo: webView.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: webView.centerYAnchor),
        ])

        webView.load(URLRequest(url: url))
    }

    @objc private func doneTapped() {
        dismiss(animated: true)
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
        activityIndicator.stopAnimating()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        activityIndicator.stopAnimating()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        activityIndicator.stopAnimating()
    }

    // MARK: - WKUIDelegate

    /// A `WKWebView` drops `target="_blank"` and `window.open` unless this is implemented,
    /// with no error of any kind — the tap simply does nothing. Payment pages use both for
    /// 3DS and wallet handoffs, so the request is loaded here instead.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
//        if navigationAction.targetFrame == nil, let request = navigationAction.request.url.map(URLRequest.init) {
//            webView.load(request)
//        }
        return nil
    }
}
