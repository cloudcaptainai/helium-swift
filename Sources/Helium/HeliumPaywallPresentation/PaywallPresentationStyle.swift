//
//  PaywallPresentationStyle.swift
//  helium-swift
//
//  Created by Kyle Gorlick on 3/10/26.
//

/// Transitioning delegate that manages the slide-in animation from right
class SlideInTransitioningDelegate: NSObject, UIViewControllerTransitioningDelegate {

    func animationController(forPresented presented: UIViewController,
                              presenting: UIViewController,
                              source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        return SlideInPresentationAnimator()
    }

    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        return SlideInDismissalAnimator()
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

        // Position the view off-screen to the right
        toView.frame = finalFrame
        toView.frame.origin.x = containerView.frame.width

        // Add shadow for depth effect
        toView.layer.shadowColor = UIColor.black.cgColor
        toView.layer.shadowOpacity = 0.2
        toView.layer.shadowOffset = CGSize(width: -5, height: 0)
        toView.layer.shadowRadius = 10

        containerView.addSubview(toView)

        // Animate sliding in from the right
        UIView.animate(
            withDuration: animationDuration,
            delay: 0,
            options: [.curveEaseOut],
            animations: {
                toView.frame = finalFrame
            },
            completion: { finished in
                transitionContext.completeTransition(finished)
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

        // Animate sliding out to the right
        UIView.animate(
            withDuration: animationDuration,
            delay: 0,
            options: [.curveEaseOut],
            animations: {
                fromView.frame.origin.x = containerView.frame.width
            },
            completion: { finished in
                fromView.removeFromSuperview()
                transitionContext.completeTransition(finished)
            }
        )
    }
}
