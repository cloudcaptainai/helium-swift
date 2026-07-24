//
//  SlideInTransition.swift
//  helium-swift
//
//  Created by Kyle Gorlick on 3/10/26.
//

import UIKit

/// Transitioning delegate that manages the slide-in animation from right
class SlideInTransitioningDelegate: NSObject, UIViewControllerTransitioningDelegate {

    func presentationController(forPresented presented: UIViewController,
                                presenting: UIViewController?,
                                source: UIViewController) -> UIPresentationController? {
        return SlideInPresentationController(presentedViewController: presented, presenting: presenting)
    }

    func animationController(forPresented presented: UIViewController,
                              presenting: UIViewController,
                              source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        return SlideInPresentationAnimator()
    }

    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        return SlideInDismissalAnimator()
    }
}

/// Gives this style the same view lifecycle as the `.fullScreen` presentation every other style uses.
/// A `.custom` presentation otherwise leaves the presenting view controller's view on screen, so that
/// view controller never receives `viewWillDisappear`/`viewDidDisappear` while the paywall is up.
private class SlideInPresentationController: UIPresentationController {
    override var shouldRemovePresentersView: Bool { true }
}

/// The drop shadow that gives the sliding view its sense of depth over the content behind it.
private enum SlideInShadow {
    static func apply(to view: UIView) {
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOpacity = 0.2
        view.layer.shadowOffset = CGSize(width: -5, height: 0)
        view.layer.shadowRadius = 10
        // Without an explicit path, Core Animation derives the shadow from the layer's alpha channel,
        // which forces an offscreen render pass for the entire full-screen view on every frame.
        view.layer.shadowPath = UIBezierPath(rect: view.bounds).cgPath
    }

    /// The shadow is invisible once the view is at rest, so drop it rather than pay for it for the
    /// whole life of the paywall.
    static func clear(from view: UIView) {
        view.layer.shadowOpacity = 0
        view.layer.shadowPath = nil
    }
}

/// Animator for presenting the view controller with a slide-in from right animation
class SlideInPresentationAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    private let animationDuration: TimeInterval = 0.24

    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        return animationDuration
    }

    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        guard let toViewController = transitionContext.viewController(forKey: .to),
              let toView = toViewController.view else {
            transitionContext.completeTransition(false)
            return
        }

        let containerView = transitionContext.containerView
        let finalFrame = transitionContext.finalFrame(for: toViewController)

        toView.frame = finalFrame
        // This animator positions by frame, so nothing else would keep the view sized to the
        // container if those bounds change later.
        toView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        SlideInShadow.apply(to: toView)

        // Position the view off-screen to the right
        toView.frame.origin.x = containerView.frame.width

        containerView.addSubview(toView)

        // Animate sliding in from the right
        UIView.animate(
            withDuration: animationDuration,
            delay: 0,
            options: [.curveEaseOut],
            animations: {
                toView.frame = finalFrame
            },
            completion: { _ in
                let cancelled = transitionContext.transitionWasCancelled
                if !cancelled {
                    SlideInShadow.clear(from: toView)
                }
                transitionContext.completeTransition(!cancelled)
            }
        )
    }
}

/// Animator for dismissing the view controller with a slide-out to right animation
class SlideInDismissalAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    private let animationDuration: TimeInterval = 0.20

    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        return animationDuration
    }

    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        guard let fromViewController = transitionContext.viewController(forKey: .from),
              let fromView = fromViewController.view else {
            transitionContext.completeTransition(false)
            return
        }

        let containerView = transitionContext.containerView

        // Non-nil only when UIKit expects this animator to restore the view being revealed, which is
        // the case whenever the presentation removed it.
        if let toView = transitionContext.view(forKey: .to), toView.superview == nil {
            if let toViewController = transitionContext.viewController(forKey: .to) {
                toView.frame = transitionContext.finalFrame(for: toViewController)
            }
            containerView.insertSubview(toView, belowSubview: fromView)
        }

        SlideInShadow.apply(to: fromView)

        // Animate sliding out to the right
        UIView.animate(
            withDuration: animationDuration,
            delay: 0,
            options: [.curveEaseOut],
            animations: {
                fromView.frame.origin.x = containerView.frame.width
            },
            completion: { _ in
                // This completion reports whether the animation ran to its end, which is not the same
                // as whether the transition was cancelled. A cancelled dismissal leaves the paywall
                // presented, so its view has to stay on screen; driving either the teardown or the
                // reported result off anything but the context's own cancellation state can leave the
                // paywall presented with nothing on screen, wedging the presenter for the session.
                let cancelled = transitionContext.transitionWasCancelled
                if !cancelled {
                    fromView.removeFromSuperview()
                }
                transitionContext.completeTransition(!cancelled)
            }
        )
    }
}
