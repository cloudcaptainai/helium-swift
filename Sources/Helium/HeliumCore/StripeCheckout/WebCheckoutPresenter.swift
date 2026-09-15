import UIKit
import SafariServices

/// Surfaces an enriched web checkout URL using the paywall's presentation style.
@MainActor
enum WebCheckoutPresenter {

    /// Returns whether the browser was actually shown.
    static func present(_ url: URL, style: WebCheckoutPresentationStyle) async -> Bool {
        switch style {
        case .externalBrowser:
            return await UIApplication.shared.open(url)

        case .safariSheet:
            guard let presenter = UIWindowHelper.findTopMostViewController() else { return false }
            let safariViewController = SFSafariViewController(url: url)
            safariViewController.modalPresentationStyle = .pageSheet
            return await presentModally(safariViewController, from: presenter)

        case .safariFullScreen:
            guard let presenter = UIWindowHelper.findTopMostViewController() else { return false }
            return await presentModally(FullScreenSafariViewController(url: url), from: presenter)
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

/// Hosts an `SFSafariViewController` as a child so it can cover the screen with a vertical
/// slide. Presented on its own, `SFSafariViewController` installs a transitioning delegate
/// that animates sideways like a navigation push and overrides `modalTransitionStyle`;
/// as a child, the container's transition governs instead.
@MainActor
final class FullScreenSafariViewController: UIViewController, SFSafariViewControllerDelegate {

    private let safariViewController: SFSafariViewController

    init(url: URL) {
        safariViewController = SFSafariViewController(url: url)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        modalTransitionStyle = .coverVertical
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

    /// Done only dismisses itself when `SFSafariViewController` is the presented controller;
    /// as a child it reports here and the container has to go.
    func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        dismiss(animated: true)
    }
}
