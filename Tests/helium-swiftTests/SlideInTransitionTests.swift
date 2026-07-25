import XCTest
import UIKit
@testable import Helium

/// Drives the slide-in animators directly against a stub transition context. A real presentation
/// cannot be used here: this bundle has no app host, so UIKit never drives an animated present or
/// dismiss to completion.
@MainActor
final class SlideInTransitionTests: XCTestCase {

    private var containerView: UIView!

    override func setUp() {
        super.setUp()
        // Lets `UIView.animate` settle without a render loop, which this bundle has no host app to
        // provide. The completion is still dispatched asynchronously.
        UIView.setAnimationsEnabled(false)
        containerView = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    }

    override func tearDown() {
        UIView.setAnimationsEnabled(true)
        containerView = nil
        super.tearDown()
    }

    private func makeViewController(color: UIColor) -> UIViewController {
        let viewController = UIViewController()
        viewController.view.backgroundColor = color
        return viewController
    }

    /// Animators finish their bookkeeping in the animation completion handler, which UIKit dispatches
    /// asynchronously even when animations are disabled.
    private func run(
        _ animator: UIViewControllerAnimatedTransitioning,
        _ context: StubTransitionContext
    ) {
        let completed = expectation(description: "transition completed")
        context.onComplete = { _ in completed.fulfill() }
        animator.animateTransition(using: context)
        wait(for: [completed], timeout: 5)
    }

    // MARK: - Presentation

    func test_GIVEN_presentation_WHEN_animated_THEN_addsPresentedViewAtContainerSize() {
        let presented = makeViewController(color: .blue)
        let context = StubTransitionContext(containerView: containerView, viewControllers: [.to: presented])

        run(SlideInPresentationAnimator(), context)

        XCTAssertTrue(presented.view.isDescendant(of: containerView))
        XCTAssertEqual(presented.view.frame, containerView.bounds)
        XCTAssertEqual(context.completedWith, true)
    }

    /// The animator positions by frame, so without this the view would not follow a later container
    /// bounds change.
    func test_GIVEN_presentation_WHEN_animated_THEN_presentedViewResizesWithContainer() {
        let presented = makeViewController(color: .blue)
        let context = StubTransitionContext(containerView: containerView, viewControllers: [.to: presented])

        run(SlideInPresentationAnimator(), context)

        XCTAssertEqual(presented.view.autoresizingMask, [.flexibleWidth, .flexibleHeight])
    }

    /// The shadow is invisible once the view is at rest, and an unbounded shadow on a full-screen
    /// layer forces an offscreen render pass for as long as the paywall is up.
    func test_GIVEN_presentation_WHEN_settled_THEN_shadowIsReleased() {
        let presented = makeViewController(color: .blue)
        let context = StubTransitionContext(containerView: containerView, viewControllers: [.to: presented])

        run(SlideInPresentationAnimator(), context)

        XCTAssertEqual(presented.view.layer.shadowOpacity, 0)
        XCTAssertNil(presented.view.layer.shadowPath)
    }

    // MARK: - Dismissal

    func test_GIVEN_dismissal_WHEN_animated_THEN_removesPaywallViewAndCompletes() {
        let paywall = makeViewController(color: .blue)
        containerView.addSubview(paywall.view)
        let context = StubTransitionContext(containerView: containerView, viewControllers: [.from: paywall])

        run(SlideInDismissalAnimator(), context)

        XCTAssertNil(paywall.view.superview)
        XCTAssertEqual(context.completedWith, true)
    }

    /// `UIView.animate` reports animation interruption, which is not transition cancellation. Tearing
    /// the view down on a genuinely cancelled transition would leave the paywall presented with
    /// nothing on screen, wedging the presenter for the rest of the session.
    func test_GIVEN_cancelledDismissal_WHEN_animated_THEN_keepsPaywallViewAndReportsCancellation() {
        let paywall = makeViewController(color: .blue)
        containerView.addSubview(paywall.view)
        let context = StubTransitionContext(
            containerView: containerView,
            viewControllers: [.from: paywall],
            transitionWasCancelled: true
        )

        run(SlideInDismissalAnimator(), context)

        XCTAssertTrue(paywall.view.isDescendant(of: containerView))
        XCTAssertEqual(context.completedWith, false)
    }

    /// Removing the presenter's view during presentation means UIKit can hand it back detached on
    /// dismissal. If nothing re-inserts it, the dismissal reveals an empty container.
    func test_GIVEN_dismissalWithDetachedPresenterView_WHEN_animated_THEN_restoresItBehindThePaywall() {
        let paywall = makeViewController(color: .blue)
        let presenter = makeViewController(color: .green)
        containerView.addSubview(paywall.view)
        let context = StubTransitionContext(
            containerView: containerView,
            viewControllers: [.from: paywall, .to: presenter],
            views: [.to: presenter.view]
        )

        run(SlideInDismissalAnimator(), context)

        XCTAssertTrue(presenter.view.isDescendant(of: containerView))
        XCTAssertEqual(presenter.view.frame, containerView.bounds)
        XCTAssertNil(paywall.view.superview)
    }

    func test_GIVEN_dismissalWithAlreadyAttachedPresenterView_WHEN_animated_THEN_doesNotReorderIt() {
        let paywall = makeViewController(color: .blue)
        let presenter = makeViewController(color: .green)
        containerView.addSubview(presenter.view)
        containerView.addSubview(paywall.view)
        let context = StubTransitionContext(
            containerView: containerView,
            viewControllers: [.from: paywall, .to: presenter],
            views: [.to: presenter.view]
        )

        run(SlideInDismissalAnimator(), context)

        XCTAssertEqual(containerView.subviews, [presenter.view])
    }

    // MARK: - Presentation controller

    /// Without this the presenting view controller stays on screen for the whole presentation and
    /// never receives `viewWillDisappear`/`viewDidDisappear`, unlike every other paywall style.
    func test_GIVEN_slideInDelegate_WHEN_vendingPresentationController_THEN_removesPresentersView() {
        let presented = makeViewController(color: .blue)
        let presenting = makeViewController(color: .green)

        let controller = SlideInTransitioningDelegate().presentationController(
            forPresented: presented, presenting: presenting, source: presenting
        )

        XCTAssertEqual(controller?.shouldRemovePresentersView, true)
    }
}

/// Minimal stand-in for the context UIKit hands an animator during a transition.
@MainActor
private final class StubTransitionContext: NSObject, UIViewControllerContextTransitioning {

    let containerView: UIView
    let transitionWasCancelled: Bool
    private(set) var completedWith: Bool?
    var onComplete: ((Bool) -> Void)?

    private let viewControllers: [UITransitionContextViewControllerKey: UIViewController]
    private let views: [UITransitionContextViewKey: UIView]

    init(
        containerView: UIView,
        viewControllers: [UITransitionContextViewControllerKey: UIViewController] = [:],
        views: [UITransitionContextViewKey: UIView] = [:],
        transitionWasCancelled: Bool = false
    ) {
        self.containerView = containerView
        self.viewControllers = viewControllers
        self.views = views
        self.transitionWasCancelled = transitionWasCancelled
    }

    func viewController(forKey key: UITransitionContextViewControllerKey) -> UIViewController? {
        viewControllers[key]
    }

    func view(forKey key: UITransitionContextViewKey) -> UIView? {
        views[key]
    }

    func completeTransition(_ didComplete: Bool) {
        completedWith = didComplete
        onComplete?(didComplete)
    }

    func finalFrame(for vc: UIViewController) -> CGRect { containerView.bounds }
    func initialFrame(for vc: UIViewController) -> CGRect { containerView.bounds }

    var isAnimated: Bool { true }
    var isInteractive: Bool { false }
    var presentationStyle: UIModalPresentationStyle { .custom }
    var targetTransform: CGAffineTransform { .identity }

    func updateInteractiveTransition(_ percentComplete: CGFloat) {}
    func finishInteractiveTransition() {}
    func cancelInteractiveTransition() {}
    func pauseInteractiveTransition() {}
}
