import UIKit
import SafariServices

/// Surfaces an enriched web checkout URL using the paywall's presentation style.
@MainActor
enum WebCheckoutPresenter {

    private static weak var presentedBrowser: WebCheckoutSafariViewController?

    /// Returns whether the browser was shown. `onBrowserDismissed` fires only for the
    /// in-app styles, which close without the app ever backgrounding.
    static func present(
        _ url: URL,
        style: WebCheckoutBrowserStyle,
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
            presentedBrowser = browser
            return await presentModally(browser, from: presenter)
        }
    }

    /// No-op for the external browser flow, which has nothing of ours on screen.
    static func dismissInAppBrowser() {
        presentedBrowser?.dismissWithoutReporting()
        presentedBrowser = nil
    }

    private static func presentModally(_ viewController: UIViewController, from presenter: UIViewController) async -> Bool {
        await withCheckedContinuation { continuation in
            presenter.present(viewController, animated: true) {
                continuation.resume(returning: viewController.presentingViewController != nil)
            }
        }
    }
}

/// Hosts an `SFSafariViewController` as a child so its dismissal can be observed.
///
/// Presented on its own it installs a transitioning delegate that animates sideways like
/// a navigation push and overrides `modalTransitionStyle`; as a child, the container's
/// transition governs instead.
@MainActor
final class WebCheckoutSafariViewController: UIViewController, @preconcurrency SFSafariViewControllerDelegate {

    private let safariViewController: SFSafariViewController
    private let onDismiss: @MainActor () -> Void
    private var reportsDismissal = true
    private let cover = UIView()
    private var coverLifted = false
    private static let coverTimeout: TimeInterval = 8

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

        addCover()
    }

    /// `SFSafariViewController` paints white until the first byte arrives, with no API to
    /// colour it, so it is covered until the page can paint itself. In place before the
    /// presentation animation starts, so there is no frame where the white shows.
    private func addCover() {
        cover.backgroundColor = .systemBackground
        cover.frame = view.bounds
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(cover)

        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        cover.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: cover.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: cover.centerYAnchor),
        ])
    }

    /// Keyed to the load rather than a timer: the wait scales with the network, so a timer
    /// that expires early uncovers the white it exists to hide. The cap is only so a dead
    /// connection cannot strand the user on a blank panel.
    private func liftCover() {
        guard !coverLifted else { return }
        coverLifted = true
        UIView.animate(withDuration: 0.3) {
            self.cover.alpha = 0
        } completion: { _ in
            self.cover.removeFromSuperview()
        }
    }

    /// For a caller that already knows checkout is over, since each report costs an
    /// entitlement refresh.
    func dismissWithoutReporting() {
        reportsDismissal = false
        dismiss(animated: true)
    }

    /// A swiped-down sheet never reaches `safariViewControllerDidFinish`, so dismissal is
    /// observed here instead.
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed && reportsDismissal {
            onDismiss()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.coverTimeout * 1_000_000_000))
            self?.liftCover()
        }
    }

    func safariViewController(_ controller: SFSafariViewController, didCompleteInitialLoad didLoadSuccessfully: Bool) {
        liftCover()
    }

    /// The dismiss button only closes `SFSafariViewController` itself when it is the
    /// presented controller; as a child it reports here and the container has to go.
    func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        dismiss(animated: true)
    }
}
