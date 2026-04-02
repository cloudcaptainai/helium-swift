import UIKit
import WebKit

// MARK: - StripeCheckoutViewController

@MainActor
final class StripeCheckoutViewController: UIViewController, WKNavigationDelegate {

    private let checkoutURL: URL
    private var completion: ((StripeCheckoutResult) -> Void)?
    private var hasCompleted = false

    private var webView: WKWebView!
    private var activityIndicator: UIActivityIndicatorView!

    init(checkoutURL: URL, completion: @escaping (StripeCheckoutResult) -> Void) {
        self.checkoutURL = checkoutURL
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
        self.modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        // Navigation bar with cancel button
        let navBar = UINavigationBar()
        navBar.translatesAutoresizingMaskIntoConstraints = false
        let navItem = UINavigationItem(title: "Checkout")
        navItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel,
            target: self,
            action: #selector(cancelTapped)
        )
        navBar.setItems([navItem], animated: false)
        view.addSubview(navBar)

        // WebView
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: config)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        view.addSubview(webView)

        // Activity indicator
        activityIndicator = UIActivityIndicatorView(style: .large)
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.hidesWhenStopped = true
        view.addSubview(activityIndicator)

        NSLayoutConstraint.activate([
            navBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            navBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            navBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            webView.topAnchor.constraint(equalTo: navBar.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        activityIndicator.startAnimating()
        webView.load(URLRequest(url: checkoutURL))
    }

    // MARK: - Actions

    @objc private func cancelTapped() {
        complete(with: .cancelled)
    }

    // MARK: - Completion

    private func complete(with result: StripeCheckoutResult) {
        guard !hasCompleted else { return }
        hasCompleted = true
        completion?(result)
        completion = nil
        dismiss(animated: true)
    }

    // MARK: - WKNavigationDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url,
              StripeCheckoutRedirect.isSuccess(url) || StripeCheckoutRedirect.isCancelled(url) else {
            decisionHandler(.allow)
            return
        }

        decisionHandler(.cancel)

        if StripeCheckoutRedirect.isSuccess(url) {
            let sessionId = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "session_id" })?
                .value
            complete(with: .success(sessionId: sessionId))
        } else {
            complete(with: .cancelled)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        activityIndicator.stopAnimating()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        activityIndicator.stopAnimating()
        complete(with: .failed(error))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        activityIndicator.stopAnimating()
        complete(with: .failed(error))
    }
}
