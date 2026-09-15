import UIKit
import SafariServices

/// Surfaces an enriched web checkout URL using the paywall's presentation style.
@MainActor
enum WebCheckoutPresenter {

    /// Returns whether the browser was actually shown. `onBrowserDismissed` fires only for
    /// the in-app styles, when the browser goes away without the app ever backgrounding.
    static func present(
        _ url: URL,
        style: WebCheckoutPresentationStyle,
        onBrowserDismissed: @escaping @MainActor () -> Void
    ) async -> Bool {
        switch style {
        case .externalBrowser:
            return await UIApplication.shared.open(url)

        case .safariSheet, .safariFullScreen:
            guard let presenter = UIWindowHelper.findTopMostViewController() else { return false }
            let browser = WebCheckoutSafariViewController(
                url: url,
                fullScreen: style == .safariFullScreen,
                onDismiss: onBrowserDismissed
            )
            return await presentModally(browser, from: presenter)
        }
    }

    private static func presentModally(_ viewController: UIViewController, from presenter: UIViewController) async -> Bool {
        await withCheckedContinuation { continuation in
            presenter.present(viewController, animated: true) {
                continuation.resume(returning: viewController.presentingViewController != nil)
            }
        }
    }
}

/// Hosts an `SFSafariViewController` as a child so the SDK owns the transition and learns
/// when the browser goes away.
///
/// Presented on its own, `SFSafariViewController` installs a transitioning delegate that
/// animates sideways like a navigation push and overrides `modalTransitionStyle`; as a
/// child, the container's transition governs instead.
@MainActor
final class WebCheckoutSafariViewController: UIViewController, SFSafariViewControllerDelegate {

    private let safariViewController: SFSafariViewController
    private let onDismiss: @MainActor () -> Void

    init(url: URL, fullScreen: Bool, onDismiss: @escaping @MainActor () -> Void) {
        safariViewController = SFSafariViewController(url: url)
        self.onDismiss = onDismiss
        super.init(nibName: nil, bundle: nil)
        if fullScreen {
            modalPresentationStyle = .fullScreen
            modalTransitionStyle = .coverVertical
        } else {
            modalPresentationStyle = .pageSheet
        }
        safariViewController.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var childForStatusBarStyle: UIViewController? { safariViewController }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        addChild(safariViewController)
        safariViewController.view.frame = view.bounds
        safariViewController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(safariViewController.view)
        safariViewController.didMove(toParent: self)
    }

    /// Catches every way the browser can leave — the dismiss button, a sheet swiped down,
    /// and the cascading dismissal when the paywall beneath is hidden. A swipe never
    /// reaches `safariViewControllerDidFinish`, so keying off the button alone would miss
    /// the most likely manual exit.
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed {
            onDismiss()
        }
    }

    /// Done only dismisses itself when `SFSafariViewController` is the presented controller;
    /// as a child it reports here and the container has to go.
    func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        dismiss(animated: true)
    }
}
